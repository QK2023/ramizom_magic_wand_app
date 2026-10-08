import 'dart:typed_data';

import 'package:flutter/services.dart';

/// The native speech audio layer (windows/runner/audio_engine.cpp): gapless,
/// low-latency playback with a position counter, and a "communications"
/// microphone stream that benefits from the system's echo cancellation.
class AudioEngine {
  static const _methods = MethodChannel('ai.ramizom.magic_wand/audio');
  static const _microphone = EventChannel('ai.ramizom.magic_wand/microphone');

  /// Queues 16-bit mono PCM. Returns the frame count queued so far, which is
  /// where this audio ends on the [position] timeline.
  static Future<int> play(Int16List samples, int sampleRate) async =>
      await _methods.invokeMethod<int>('play', {
        'samples': samples.buffer.asUint8List(
          samples.offsetInBytes,
          samples.lengthInBytes,
        ),
        'sampleRate': sampleRate,
      }) ??
      0;

  /// Decodes a complete compressed audio file (MP3, AAC, FLAC...) into
  /// 16-bit mono PCM, off the UI thread.
  static Future<({Int16List samples, int sampleRate})> decode(
    Uint8List bytes,
  ) async {
    final value = await _methods.invokeMapMethod<String, Object?>('decode', {
      'bytes': bytes,
    });
    var pcm = value?['samples'] as Uint8List? ?? Uint8List(0);
    // 16-bit views need an even offset into their buffer.
    if (pcm.offsetInBytes.isOdd) pcm = Uint8List.fromList(pcm);
    return (
      samples: pcm.buffer.asInt16List(
        pcm.offsetInBytes,
        pcm.lengthInBytes ~/ 2,
      ),
      sampleRate: (value?['sampleRate'] as int?) ?? 24000,
    );
  }

  /// Opens the output device now, so the first sentence plays without the
  /// device start-up delay.
  static Future<void> prepare(int sampleRate) =>
      _methods.invokeMethod('prepare', {'sampleRate': sampleRate});

  /// Drops everything queued and silences playback at once.
  static Future<void> stopPlayback() => _methods.invokeMethod('stopPlayback');

  /// Frames handed to the speaker so far and frames queued so far.
  static Future<({int played, int queued})> position() async {
    final value = await _methods.invokeMapMethod<String, Object?>('position');
    return (
      played: (value?['played'] as int?) ?? 0,
      queued: (value?['queued'] as int?) ?? 0,
    );
  }

  /// 16 kHz mono 16-bit PCM in ~100 ms chunks while listened to.
  static Stream<Uint8List> microphone() =>
      _microphone.receiveBroadcastStream().map((chunk) => chunk as Uint8List);
}
