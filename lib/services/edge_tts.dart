import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A Microsoft Edge neural voice offered in Settings.
class EdgeVoice {
  const EdgeVoice(this.id, this.zh, this.en, {required this.female});
  final String id;

  /// Name and character, in Chinese and English.
  final String zh;
  final String en;
  final bool female;

  String label(String language) => language == 'zh' ? zh : en;
}

/// Speech from Microsoft Edge's read-aloud service: the same neural voices
/// as Edge's "Read aloud", free and without an account. Each request is one
/// WebSocket exchange that returns the sentence as MP3.
class EdgeTts {
  static const defaultVoice = 'zh-CN-XiaoxiaoNeural';

  /// Voices in Settings. The multilingual ones read Chinese and English in
  /// one natural voice; the others speak their own language best.
  static const voices = [
    EdgeVoice(
      'zh-CN-XiaoxiaoNeural',
      '晓晓 · 温暖亲切',
      'Xiaoxiao · warm',
      female: true,
    ),
    EdgeVoice('zh-CN-XiaoyiNeural', '晓伊 · 活泼', 'Xiaoyi · lively', female: true),
    EdgeVoice(
      'zh-CN-YunxiNeural',
      '云希 · 阳光少年',
      'Yunxi · bright',
      female: false,
    ),
    EdgeVoice(
      'zh-CN-YunjianNeural',
      '云健 · 沉稳有力',
      'Yunjian · strong',
      female: false,
    ),
    EdgeVoice(
      'zh-CN-YunyangNeural',
      '云扬 · 新闻播报',
      'Yunyang · newscaster',
      female: false,
    ),
    EdgeVoice(
      'zh-CN-YunxiaNeural',
      '云夏 · 可爱童声',
      'Yunxia · child',
      female: false,
    ),
    EdgeVoice(
      'zh-CN-liaoning-XiaobeiNeural',
      '晓北 · 东北话',
      'Xiaobei · Northeastern',
      female: true,
    ),
    EdgeVoice(
      'zh-CN-shaanxi-XiaoniNeural',
      '晓妮 · 陕西话',
      'Xiaoni · Shaanxi',
      female: true,
    ),
    EdgeVoice(
      'zh-HK-HiuMaanNeural',
      '曉曼 · 粤语',
      'HiuMaan · Cantonese',
      female: true,
    ),
    EdgeVoice(
      'zh-TW-HsiaoChenNeural',
      '曉臻 · 台湾腔',
      'HsiaoChen · Taiwanese',
      female: true,
    ),
    EdgeVoice(
      'en-US-EmmaMultilingualNeural',
      'Emma · 多语言',
      'Emma · multilingual',
      female: true,
    ),
    EdgeVoice(
      'en-US-AvaMultilingualNeural',
      'Ava · 多语言',
      'Ava · multilingual',
      female: true,
    ),
    EdgeVoice(
      'en-US-AndrewMultilingualNeural',
      'Andrew · 多语言',
      'Andrew · multilingual',
      female: false,
    ),
    EdgeVoice(
      'en-US-BrianMultilingualNeural',
      'Brian · 多语言',
      'Brian · multilingual',
      female: false,
    ),
    EdgeVoice(
      'en-US-JennyNeural',
      'Jenny · 美式英语',
      'Jenny · US English',
      female: true,
    ),
    EdgeVoice(
      'en-GB-SoniaNeural',
      'Sonia · 英式英语',
      'Sonia · British English',
      female: true,
    ),
  ];

  static EdgeVoice voice(String id) =>
      voices.firstWhere((v) => v.id == id, orElse: () => voices.first);

  static const _token = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const _chromium = '143.0.3650.75';
  static final _random = math.Random.secure();

  /// The service's rolling access token: a hash of the time, in Windows
  /// file-time units rounded down to five minutes, and the client token.
  static String secMsGec(DateTime now) {
    var seconds = now.toUtc().millisecondsSinceEpoch ~/ 1000 + 11644473600;
    seconds -= seconds % 300;
    final ticks = seconds * 10000000;
    return sha256
        .convert(ascii.encode('$ticks$_token'))
        .toString()
        .toUpperCase();
  }

  static String _hex(int bytes) => [
    for (var i = 0; i < bytes; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  /// The time as JavaScript's Date.toString() writes it, in UTC.
  static String timestamp(DateTime now) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final t = now.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${days[t.weekday - 1]} ${months[t.month - 1]} ${two(t.day)} '
        '${t.year} ${two(t.hour)}:${two(t.minute)}:${two(t.second)} '
        'GMT+0000 (Coordinated Universal Time)';
  }

  /// [speed] 1.25 becomes "+25%".
  static String rate(double speed) {
    final percent = ((speed - 1) * 100).round();
    return '${percent >= 0 ? '+' : ''}$percent%';
  }

  static String ssml(String text, String voice, double speed) {
    final escaped = text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;')
        // Control characters break the service's XML parser.
        .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), ' ');
    return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
        "xml:lang='en-US'><voice name='$voice'><prosody pitch='+0Hz' "
        "rate='${rate(speed)}' volume='+0%'>$escaped</prosody></voice></speak>";
  }

  static final _session = EdgeSession();

  /// One sentence as MP3, over a connection kept open between sentences.
  static Future<Uint8List> synthesize(
    String text,
    String voice,
    double speed,
  ) => _session.synthesize(text, voice, speed);

  /// Opens the connection ahead of the first sentence; the handshake takes
  /// most of a second, synthesis only a fraction of one.
  static void warmUp() => _session.warmUp();

  static Uri _uri() => Uri.parse(
    'https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1'
    '?TrustedClientToken=$_token&ConnectionId=${_hex(16)}'
    '&Sec-MS-GEC=${secMsGec(DateTime.now())}&Sec-MS-GEC-Version=1-$_chromium',
  );

  static String _config() =>
      'X-Timestamp:${timestamp(DateTime.now())}\r\n'
      'Content-Type:application/json; charset=utf-8\r\n'
      'Path:speech.config\r\n\r\n'
      '{"context":{"synthesis":{"audio":{"metadataoptions":{'
      '"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
      '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n';

  static String _request(String id, String text, String voice, double speed) =>
      'X-RequestId:$id\r\n'
      'Content-Type:application/ssml+xml\r\n'
      'X-Timestamp:${timestamp(DateTime.now())}Z\r\n'
      'Path:ssml\r\n\r\n'
      '${ssml(text, voice, speed)}';

  /// Opens the WebSocket with the handshake Edge itself sends. Dart's
  /// WebSocket.connect is refused by this service, so the upgrade is done
  /// here and the connection handed over afterwards.
  static Future<WebSocket> _connect(Uri uri) async {
    final major = _chromium.split('.').first;
    final key = base64.encode(List.generate(16, (_) => _random.nextInt(256)));
    final client = HttpClient()..userAgent = null;
    try {
      final request = await client.getUrl(uri);
      request.headers
        ..set('Connection', 'Upgrade')
        ..set('Upgrade', 'websocket')
        ..set('Sec-WebSocket-Version', '13')
        ..set('Sec-WebSocket-Key', key)
        ..set('Pragma', 'no-cache')
        ..set('Cache-Control', 'no-cache')
        ..set('Origin', 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold')
        ..set(
          'User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/$major.0.0.0 Safari/537.36 '
              'Edg/$major.0.0.0',
        )
        ..set('Accept-Language', 'en-US,en;q=0.9')
        ..set('Cookie', 'muid=${_hex(16).toUpperCase()};');
      final response = await request.close();
      final accept = base64.encode(
        sha1
            .convert(ascii.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
            .bytes,
      );
      if (response.statusCode != HttpStatus.switchingProtocols ||
          response.headers.value('sec-websocket-accept') != accept) {
        await response.drain<void>().catchError((_) {});
        throw EdgeTtsException('edgeTtsRefused', 'HTTP ${response.statusCode}');
      }
      final socket = await response.detachSocket();
      return WebSocket.fromUpgradedSocket(socket, serverSide: false);
    } finally {
      client.close();
    }
  }

  /// The MP3 bytes of a binary frame: a two-byte header length, text
  /// headers, then the audio. Null for frames that carry no audio.
  static Uint8List? audioOf(List<int> frame) {
    if (frame.length < 2) return null;
    final length = (frame[0] << 8) | frame[1];
    if (frame.length < 2 + length) return null;
    final headers = latin1.decode(frame.sublist(2, 2 + length));
    if (!headers.contains('Path:audio')) return null;
    final data = frame.sublist(2 + length);
    return data.isEmpty ? null : Uint8List.fromList(data);
  }
}

class EdgeTtsException implements Exception {
  const EdgeTtsException(this.message, [this.detail = '']);
  final String message;
  final String detail;
  @override
  String toString() => message;
}

/// One connection to the read-aloud service, reused sentence after
/// sentence. Requests take turns on it; it closes after a minute unused and
/// reopens on demand, and a request that loses its connection is retried
/// once on a fresh one.
class EdgeSession {
  static const idleClose = Duration(seconds: 60);

  WebSocket? _socket;
  Future<WebSocket>? _opening;
  Future<void> _queue = Future.value();
  Timer? _idle;
  // The turn being received.
  String? _turn;
  BytesBuilder? _audio;
  Completer<Uint8List>? _done;

  void warmUp() {
    _keepAlive();
    unawaited(_open().then((_) {}, onError: (_) {}));
  }

  Future<Uint8List> synthesize(String text, String voice, double speed) {
    final result = _queue.then((_) async {
      try {
        return await _once(text, voice, speed);
      } on _ConnectionLost {
        return _once(text, voice, speed);
      }
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Uint8List> _once(String text, String voice, double speed) async {
    _keepAlive();
    final socket = await _open();
    final id = EdgeTts._hex(16);
    final done = _done = Completer<Uint8List>();
    _turn = id;
    _audio = BytesBuilder(copy: false);
    socket.add(EdgeTts._request(id, text, voice, speed));
    try {
      return await done.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      _drop();
      rethrow;
    } finally {
      _turn = null;
      _keepAlive();
    }
  }

  Future<WebSocket> _open() {
    final socket = _socket;
    if (socket != null) return Future.value(socket);
    return _opening ??= () async {
      try {
        final socket = await EdgeTts._connect(
          EdgeTts._uri(),
        ).timeout(const Duration(seconds: 10));
        socket.add(EdgeTts._config());
        socket.listen(
          (message) => _receive(socket, message),
          onDone: () => _lost(socket),
          onError: (_) => _lost(socket),
          cancelOnError: true,
        );
        return _socket = socket;
      } finally {
        _opening = null;
      }
    }();
  }

  void _receive(WebSocket socket, Object? message) {
    final turn = _turn;
    if (turn == null || !identical(socket, _socket)) return;
    if (message is String) {
      if (message.contains('Path:turn.end') && message.contains(turn)) {
        final audio = _audio?.takeBytes() ?? Uint8List(0);
        final done = _done;
        if (done != null && !done.isCompleted) {
          if (audio.isEmpty) {
            done.completeError(const EdgeTtsException('speechNoAudio'));
          } else {
            done.complete(audio);
          }
        }
      }
    } else if (message is List<int>) {
      final chunk = EdgeTts.audioOf(message);
      if (chunk != null) _audio?.add(chunk);
    }
  }

  void _lost(WebSocket socket) {
    if (!identical(socket, _socket)) return;
    _socket = null;
    final done = _done;
    if (_turn != null && done != null && !done.isCompleted) {
      done.completeError(const _ConnectionLost());
    }
  }

  void _drop() {
    final socket = _socket;
    _socket = null;
    unawaited(socket?.close());
  }

  void _keepAlive() {
    _idle?.cancel();
    _idle = Timer(idleClose, () {
      if (_turn == null) _drop();
    });
  }
}

class _ConnectionLost implements Exception {
  const _ConnectionLost();
}
