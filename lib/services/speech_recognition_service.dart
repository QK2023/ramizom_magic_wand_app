import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'audio_engine.dart';

/// On-device speech recognition: the microphone feeds Silero VAD, which cuts
/// speech into segments, and SenseVoice transcribes them (Chinese, English,
/// Cantonese, Japanese, Korean, mixed). Everything runs in a background
/// isolate from models bundled in the app.
///
/// Events: `sound` / `silence` when speech starts or stops, `partial` with a
/// running transcript of the current utterance, `final` with a finished
/// segment, and `error`.
class SpeechRecognitionService {
  SpeechRecognitionService({String? modelDirectory})
    : modelDirectory = modelDirectory ?? defaultModelDirectory();

  static const sampleRate = 16000;

  /// Unload the models after this long without listening: they hold a few
  /// hundred MB, and reloading takes only a moment.
  static const idleUnload = Duration(seconds: 90);

  /// Where sherpa-onnx's native library lives; null means next to the app.
  static String? libraryDirectory;

  static String defaultModelDirectory() =>
      '${File(Platform.resolvedExecutable).parent.path}/data/flutter_assets/assets/asr';

  final String modelDirectory;
  void Function(String type, String text)? onEvent;
  StreamSubscription<Uint8List>? _microphone;
  _AsrWorker? _worker;
  Future<_AsrWorker>? _starting;
  Timer? _idle;
  int _session = 0;

  bool get installed =>
      File('$modelDirectory/model.int8.onnx').existsSync() &&
      File('$modelDirectory/silero_vad.onnx').existsSync();

  /// Loads the models ahead of time.
  Future<void> warmUp() async {
    if (!installed) return;
    try {
      await _ensureWorker();
    } catch (_) {
      // Reported when listening actually starts.
    }
  }

  /// Starts listening to the microphone, or to [source] (16 kHz mono
  /// 16-bit PCM) when given. The microphone is opened by the native audio
  /// engine as a communications stream, so the system's echo cancellation
  /// keeps a spoken reply from being heard as the user.
  Future<void> start({Stream<Uint8List>? source}) async {
    final session = ++_session;
    if (!installed) throw const SpeechRecognitionException('speechUnavailable');
    final _AsrWorker worker;
    try {
      worker = await _ensureWorker();
    } catch (_) {
      throw const SpeechRecognitionException('speechUnavailable');
    }
    if (session != _session) return;
    _idle?.cancel();
    worker
      ..reset()
      ..onEvent = (type, text) {
        if (session == _session) onEvent?.call(type, text);
      };
    _microphone = (source ?? AudioEngine.microphone()).listen(
      worker.feed,
      onError: (Object error) {
        if (session != _session) return;
        final reason = error is PlatformException ? error.message : null;
        onEvent?.call('error', reason ?? 'micDenied');
      },
    );
  }

  /// Whether audio is currently being listened to.
  bool get active => _microphone != null;

  Future<void> stop() async {
    ++_session;
    _idle?.cancel();
    await _microphone?.cancel();
    _microphone = null;
    _worker
      ?..onEvent = null
      ..reset();
    _idle = Timer(idleUnload, () {
      if (_microphone != null) return;
      _worker?.dispose();
      _worker = null;
    });
  }

  Future<void> dispose() async {
    onEvent = null;
    await stop();
    _idle?.cancel();
    _worker?.dispose();
    _worker = null;
  }

  Future<_AsrWorker> _ensureWorker() {
    final worker = _worker;
    if (worker != null) return Future.value(worker);
    return _starting ??= _AsrWorker.spawn(modelDirectory, libraryDirectory)
        .then(
          (worker) {
            _starting = null;
            return _worker = worker;
          },
          onError: (Object error) {
            _starting = null;
            throw error;
          },
        );
  }
}

class SpeechRecognitionException implements Exception {
  const SpeechRecognitionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Runs VAD and SenseVoice in a background isolate.
class _AsrWorker {
  _AsrWorker._(this._isolate, this._requests, this._responses);
  final Isolate _isolate;
  final SendPort _requests;
  final ReceivePort _responses;
  void Function(String type, String text)? onEvent;

  static Future<_AsrWorker> spawn(String directory, String? library) async {
    final responses = ReceivePort();
    final isolate = await Isolate.spawn(_main, (
      responses.sendPort,
      directory,
      library,
    ));
    final ready = Completer<SendPort>();
    _AsrWorker? worker;
    responses.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is String && !ready.isCompleted) {
        ready.completeError(SpeechRecognitionException(message));
      } else if (message is (String, String)) {
        worker?.onEvent?.call(message.$1, message.$2);
      }
    });
    try {
      final port = await ready.future;
      return worker = _AsrWorker._(isolate, port, responses);
    } catch (_) {
      isolate.kill();
      responses.close();
      rethrow;
    }
  }

  /// Raw 16-bit little-endian mono PCM from the microphone.
  void feed(Uint8List pcm) =>
      _requests.send(TransferableTypedData.fromList([pcm]));

  void reset() => _requests.send('reset');

  void dispose() {
    _isolate.kill(priority: Isolate.immediate);
    _responses.close();
  }

  static void _main((SendPort, String, String?) arguments) {
    final (reply, directory, library) = arguments;
    const rate = SpeechRecognitionService.sampleRate;
    const window = 512;
    final sherpa.VoiceActivityDetector vad;
    final sherpa.OfflineRecognizer recognizer;
    try {
      sherpa.initBindings(library);
      vad = sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: '$directory/silero_vad.onnx',
            // A short pause ends a phrase; the controller decides when a
            // whole turn is over.
            minSilenceDuration: .45,
            minSpeechDuration: .2,
            maxSpeechDuration: 20,
            windowSize: window,
          ),
          sampleRate: rate,
          debug: false,
        ),
        bufferSizeInSeconds: 60,
      );
      recognizer = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            senseVoice: sherpa.OfflineSenseVoiceModelConfig(
              model: '$directory/model.int8.onnx',
              useInverseTextNormalization: true,
            ),
            tokens: '$directory/tokens.txt',
            numThreads: 2,
            debug: false,
          ),
        ),
      );
    } catch (_) {
      reply.send('speechUnavailable');
      return;
    }

    String transcribe(Float32List samples) {
      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(samples: samples, sampleRate: rate);
        recognizer.decode(stream);
        return recognizer.getResult(stream).text.trim();
      } finally {
        stream.free();
      }
    }

    // Warm the graphs so the first words are not slow.
    try {
      transcribe(Float32List(rate ~/ 2));
    } catch (_) {}

    var pending = Float32List(0);
    final speech = <double>[];
    // VAD fires a moment after speech begins; keep the last 0.4 s so the
    // live caption does not lose the first syllable.
    const preRoll = rate * 4 ~/ 10;
    final recent = <double>[];
    var speaking = false;
    var sinceRefresh = 0;
    // Re-transcribe the utterance so far about every 0.8 s while speaking.
    const refresh = rate * 8 ~/ 10;

    final requests = ReceivePort();
    reply.send(requests.sendPort);
    requests.listen((message) {
      if (message == 'reset') {
        vad.reset();
        pending = Float32List(0);
        speech.clear();
        recent.clear();
        speaking = false;
        sinceRefresh = 0;
        return;
      }
      final bytes = (message as TransferableTypedData).materialize();
      final pcm = bytes.asInt16List(0, bytes.lengthInBytes ~/ 2);
      final samples = Float32List(pending.length + pcm.length)
        ..setAll(0, pending);
      for (var i = 0; i < pcm.length; i++) {
        samples[pending.length + i] = pcm[i] / 32768;
      }
      var offset = 0;
      try {
        while (samples.length - offset >= window) {
          final chunk = Float32List.sublistView(
            samples,
            offset,
            offset + window,
          );
          offset += window;
          vad.acceptWaveform(chunk);
          final detected = vad.isDetected();
          if (detected != speaking) {
            speaking = detected;
            reply.send((detected ? 'sound' : 'silence', ''));
            if (detected && speech.isEmpty) speech.addAll(recent);
          }
          recent.addAll(chunk);
          if (recent.length > preRoll) {
            recent.removeRange(0, recent.length - preRoll);
          }
          if (detected) {
            speech.addAll(chunk);
            sinceRefresh += window;
            if (sinceRefresh >= refresh) {
              sinceRefresh = 0;
              final text = transcribe(Float32List.fromList(speech));
              if (text.isNotEmpty) reply.send(('partial', text));
            }
          }
          while (!vad.isEmpty()) {
            final segment = vad.front();
            vad.pop();
            // Our buffer includes the pre-roll the VAD segment cuts off.
            final audio = speech.length > segment.samples.length
                ? Float32List.fromList(speech)
                : segment.samples;
            speech.clear();
            sinceRefresh = 0;
            final text = transcribe(audio);
            if (text.isNotEmpty) reply.send(('final', text));
          }
        }
      } catch (_) {
        reply.send(('error', ''));
      }
      pending = Float32List.fromList(samples.sublist(offset));
    });
  }
}
