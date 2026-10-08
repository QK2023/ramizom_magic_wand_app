import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramizom_magic_wand/services/edge_tts.dart';
import 'package:ramizom_magic_wand/services/speech_service.dart';

List<String> feed(List<String> deltas) {
  final buffer = StringBuffer();
  final result = <String>[];
  for (final delta in deltas) {
    buffer.write(delta);
    result.addAll(SpeechService.takeSentences(buffer, first: result.isEmpty));
  }
  result.addAll(
    SpeechService.takeSentences(buffer, first: result.isEmpty, flush: true),
  );
  return result;
}

void main() {
  test('streamed text is spoken sentence by sentence, first clause early', () {
    expect(feed(['好的，我看了一下这段代码，循环', '条件写反了！应该是 i < n']), [
      '好的，',
      '我看了一下这段代码，循环条件写反了！',
      '应该是 i 小于 n',
    ]);
    // Even a short opening clause is spoken at once, so the voice starts
    // quickly; a lone comma is not.
    expect(feed(['好的，', '我看了一下。']), ['好的，', '我看了一下。']);
    expect(feed(['，', '我看了一下。']), ['，我看了一下。']);
    expect(feed(['Sure. ', 'The loop is ', 'reversed.']), [
      'Sure.',
      'The loop is reversed.',
    ]);
  });

  test('very long runs are cut at a comma, never mid-word', () {
    final long = '${'这是一段很长的句子，' * 20}结束';
    final pieces = feed([long]);
    expect(pieces.length, greaterThan(1));
    expect(pieces.every((p) => p.length <= 120), isTrue);
    expect(pieces.join(), long);
  });

  test('speech text words markdown, code, links and emoji naturally', () {
    expect(
      SpeechService.speechText(
        '## 结论\n**注意** 看[文档](https://x.y)，`code` 😀\n```dart\nx\n```',
      ),
      '结论。注意 看文档，code。这里有一段代码，请在屏幕上查看。',
    );
    // Punctuation-only fragments are not spoken.
    expect(feed(['……', '！']), isEmpty);
  });

  test('pieces keep their raw text alongside the spoken form', () {
    final buffer = StringBuffer('**好的**，我看了一下这段代码。```x```');
    final pieces = SpeechService.takePieces(buffer, first: true, flush: true);
    expect(pieces.map((p) => p.raw).join(), '**好的**，我看了一下这段代码。```x```');
    expect(pieces.first.spoken, '好的，');
    expect(pieces[1].spoken, '我看了一下这段代码。');
    // Code is announced rather than read or silently skipped.
    expect(pieces.last.spoken, '这里有一段代码，请在屏幕上查看。');
  });

  group('Edge voices', () {
    test('the access token follows the five-minute clock', () {
      final a = EdgeTts.secMsGec(DateTime.utc(2026, 10, 7, 9, 20, 1));
      final b = EdgeTts.secMsGec(DateTime.utc(2026, 10, 7, 9, 24, 59));
      final c = EdgeTts.secMsGec(DateTime.utc(2026, 10, 7, 9, 25, 0));
      expect(a, b);
      expect(a, isNot(c));
      expect(a, matches(RegExp(r'^[0-9A-F]{64}$')));
    });

    test('requests are escaped SSML at the chosen speed', () {
      final ssml = EdgeTts.ssml('a < b & "c"', 'zh-CN-YunxiNeural', 1.2);
      expect(ssml, contains("<voice name='zh-CN-YunxiNeural'>"));
      expect(ssml, contains("rate='+20%'"));
      expect(ssml, contains('a &lt; b &amp; &quot;c&quot;'));
      expect(EdgeTts.rate(.8), '-20%');
      expect(
        EdgeTts.timestamp(DateTime.utc(2026, 10, 7, 9, 5, 3)),
        'Wed Oct 07 2026 09:05:03 GMT+0000 (Coordinated Universal Time)',
      );
    });

    test('audio frames are found by their headers', () {
      List<int> frame(String headers, List<int> data) {
        final h = latin1.encode(headers);
        return [h.length >> 8, h.length & 255, ...h, ...data];
      }

      expect(EdgeTts.audioOf(frame('Path:audio\r\n', [1, 2, 3])), [1, 2, 3]);
      expect(EdgeTts.audioOf(frame('Path:audio\r\n', [])), isNull);
      expect(EdgeTts.audioOf(frame('Path:other\r\n', [1])), isNull);
      expect(EdgeTts.audioOf([0]), isNull);
    });

    test('there are Chinese and multilingual voices of both genders', () {
      final ids = EdgeTts.voices.map((v) => v.id).toSet();
      expect(ids, hasLength(EdgeTts.voices.length));
      expect(ids, contains(EdgeTts.defaultVoice));
      expect(
        EdgeTts.voices.where((v) => v.id.startsWith('zh-') && v.female),
        isNotEmpty,
      );
      expect(
        EdgeTts.voices.where((v) => v.id.startsWith('zh-') && !v.female),
        isNotEmpty,
      );
      expect(
        EdgeTts.voices.where((v) => v.id.contains('Multilingual')),
        isNotEmpty,
      );
      expect(EdgeTts.voice('gone').id, EdgeTts.defaultVoice);
    });
  });

  test('replies are spoken sentence by sentence with captions and drawings '
      'following the voice', () async {
    final output = FakeOutput();
    final requested = <String>[];
    final service = SpeechService(
      output: output,
      synthesizer: (text, voice, speed) async {
        requested.add('$voice:$text');
        // The fake decoder makes 0.1 s of audio per byte.
        return Uint8List(text.length);
      },
    );
    final captions = <String>[];
    final cues = <String>[];
    final utterance = service.begin(
      config: const SpeechConfig(voice: 'zh-CN-YunxiNeural'),
      onCaption: captions.add,
      onCue: cues.add,
    );
    utterance
      ..add('好的，先看这里<draw>{"type":"circle"}</draw>。然后')
      ..add('看那里。')
      ..close();
    await utterance.done;
    expect(requested, [
      'zh-CN-YunxiNeural:好的，',
      'zh-CN-YunxiNeural:先看这里。',
      'zh-CN-YunxiNeural:然后看那里。',
    ]);
    // Audio was queued back to back in speaking order.
    expect(output.queued, (3 + 5 + 6) * 2400);
    expect(cues, ['{"type":"circle"}']);
    expect(captions.last, '好的，先看这里。然后看那里。');
    // Captions grew with the voice rather than all at once.
    expect(captions.length, greaterThan(3));
    await service.dispose();
  });

  test('a voice that fails is reported, not silently skipped', () async {
    final service = SpeechService(
      output: FakeOutput(),
      synthesizer: (text, voice, speed) async =>
          throw const EdgeTtsException('edgeTtsRefused'),
    );
    final utterance = service.begin(config: const SpeechConfig())
      ..add('你好。')
      ..close();
    await expectLater(
      utterance.done,
      throwsA(
        isA<SpeechServiceException>().having(
          (e) => e.message,
          'message',
          'edgeTtsRefused',
        ),
      ),
    );
    await service.dispose();
  });
}

class FakeOutput implements SpeechOutput {
  int queued = 0, played = 0, decoded = 0;
  @override
  Future<void> prepare(int sampleRate) async {}
  @override
  Future<int> play(Int16List samples, int sampleRate) async =>
      queued += samples.length;
  @override
  Future<void> stop() async => played = queued;
  @override
  Future<({int played, int queued})> position() async {
    played = math.min(queued, played + 2400);
    return (played: played, queued: queued);
  }

  @override
  Future<SpeechAudio> decode(Uint8List encoded) async {
    decoded = encoded.length;
    return (samples: Int16List(encoded.length * 2400), rate: 24000);
  }
}
