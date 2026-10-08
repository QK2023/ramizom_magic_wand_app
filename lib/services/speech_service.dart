import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show StringCharacters;

import '../models/app_settings.dart';
import 'annotation_service.dart';
import 'audio_engine.dart';
import 'edge_tts.dart';
import 'math_display.dart';
import 'speakable_text.dart';

/// A piece of reply text: [raw] as written, [spoken] as read aloud (and
/// shown in captions), and the drawing [cues] to perform as it is spoken.
typedef SpeechPiece = ({String raw, String spoken, List<SpeechCue> cues});

/// A drawing command and where in its piece it belongs: 0 at the first
/// spoken word, 1 after the last.
typedef SpeechCue = ({String command, double at});

/// 16-bit mono audio at [rate] samples per second.
typedef SpeechAudio = ({Int16List samples, int rate});

/// The voice replies are read with: a Microsoft Edge neural voice.
class SpeechConfig {
  const SpeechConfig({this.voice = EdgeTts.defaultVoice});

  factory SpeechConfig.of(AppSettings settings) =>
      SpeechConfig(voice: settings.speechVoice);

  final String voice;

  /// Whether replies can be read aloud.
  bool get ready => voice.trim().isNotEmpty;
}

/// Where audio goes. The app uses the native [AudioEngine]; tests
/// substitute their own.
abstract class SpeechOutput {
  /// Gets the device ready while the first sentence is requested.
  Future<void> prepare(int sampleRate);

  /// Queues audio; returns where it ends on the played-frames timeline.
  Future<int> play(Int16List samples, int sampleRate);
  Future<void> stop();
  Future<({int played, int queued})> position();

  /// Decodes a complete compressed file (MP3, AAC, FLAC...).
  Future<SpeechAudio> decode(Uint8List encoded);
}

class NativeSpeechOutput implements SpeechOutput {
  const NativeSpeechOutput();
  @override
  Future<void> prepare(int sampleRate) => AudioEngine.prepare(sampleRate);
  @override
  Future<int> play(Int16List samples, int sampleRate) =>
      AudioEngine.play(samples, sampleRate);
  @override
  Future<void> stop() => AudioEngine.stopPlayback();
  @override
  Future<({int played, int queued})> position() => AudioEngine.position();
  @override
  Future<SpeechAudio> decode(Uint8List encoded) async {
    final audio = await AudioEngine.decode(encoded);
    return (samples: audio.samples, rate: audio.sampleRate);
  }
}

/// Speaks [text] in [voice] at [speed]; returns the audio as MP3 or WAV.
typedef SpeechSynthesizer =
    Future<Uint8List> Function(String text, String voice, double speed);

/// Reads replies aloud with Microsoft Edge neural voices. Text is spoken as
/// it streams in: each sentence is requested as soon as it is complete, the
/// next ones are fetched while one plays, and captions and drawings follow
/// exactly what has been said.
class SpeechService {
  SpeechService({
    SpeechOutput? output,
    SpeechSynthesizer? synthesizer,
    void Function()? warmUp,
  }) : _output = output ?? const NativeSpeechOutput(),
       _synthesize = synthesizer ?? EdgeTts.synthesize,
       _warmUp = warmUp ?? (synthesizer == null ? EdgeTts.warmUp : () {});

  /// Sentences requested ahead of the one being heard.
  static const lookahead = 3;

  final SpeechOutput _output;
  final SpeechSynthesizer _synthesize;
  final void Function() _warmUp;
  final _states = StreamController<bool>.broadcast();
  int _generation = 0;
  _Utterance? _current;
  // Whether audio may still be queued in the output, so stopping only talks
  // to the native engine when there is something to silence.
  bool _outputBusy = false;
  // The last sample rate heard, to open the device ahead of the audio.
  int _lastRate = 24000;
  // How the voice's real durations compare with [estimateSeconds], learnt
  // as sentences are heard; it keeps captions in step while a sentence is
  // still downloading.
  double _pace = 1;

  /// Opens the connection to the voice service before it is needed, so the
  /// first words come sooner.
  void warmUp() => _warmUp();

  /// True while an utterance is being spoken (gaps between sentences included).
  Stream<bool> get playbackStates => _states.stream;

  /// Starts an utterance that is fed text as it streams in. [onCaption]
  /// receives the reply text up to the point the voice has reached.
  SpeechUtterance begin({
    required SpeechConfig config,
    double speed = 1,
    void Function(String spoken)? onCaption,
    void Function(String cue)? onCue,
  }) {
    if (!config.ready) throw const SpeechServiceException('ttsMissing');
    unawaited(stopPlayback());
    final utterance = _Utterance(
      this,
      ++_generation,
      config,
      speed,
      onCaption,
      onCue,
    );
    _current = utterance;
    unawaited(utterance._run());
    return utterance;
  }

  /// Speaks [text] and completes when it has been read or interrupted.
  Future<void> speak(
    String text, {
    required SpeechConfig config,
    double speed = 1,
  }) {
    final utterance = begin(config: config, speed: speed)
      ..add(text)
      ..close();
    return utterance.done;
  }

  /// Interrupts whatever is being spoken, immediately.
  Future<void> stopPlayback() async {
    _generation++;
    _current?._cancel();
    _current = null;
    if (!_outputBusy) return;
    _outputBusy = false;
    try {
      await _output.stop();
    } catch (_) {
      // No native audio; nothing is playing.
    }
  }

  Future<void> dispose() async {
    _generation++;
    _current?._cancel();
    if (_outputBusy) {
      try {
        await _output.stop();
      } catch (_) {}
    }
    await _states.close();
  }

  /// Roughly how long [text] takes to say at normal speed: Chinese
  /// characters are syllables, Latin letters much shorter, and punctuation
  /// adds a pause.
  static double estimateSeconds(String text) {
    var seconds = 0.0;
    for (final rune in text.runes) {
      if ((rune >= 0x3400 && rune <= 0x9FFF) ||
          (rune >= 0xF900 && rune <= 0xFAFF)) {
        seconds += .22;
      } else if (_pause.hasMatch(String.fromCharCode(rune))) {
        seconds += .18;
      } else if (rune == 0x20) {
        seconds += .02;
      } else if (_speakable.hasMatch(String.fromCharCode(rune))) {
        seconds += .06;
      }
    }
    return seconds;
  }

  static final _pause = RegExp(r'[，。,.!?！？；;：:、…]');

  /// What a voice should say for a Markdown fragment: structure becomes
  /// pauses and words, formulas are read as mathematics, and no markup
  /// symbol is pronounced. [chinese] picks the wording; by default it
  /// follows the text itself.
  static String speechText(String value, {bool? chinese}) =>
      speakable(value, chinese: chinese ?? looksChinese(value));

  static final _speakable = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// Whether [text] leaves no code block or formula open, so it can be
  /// spoken on its own.
  static bool _closed(String text) {
    if ('```'.allMatches(text).length.isOdd) return false;
    final display = r'$$'.allMatches(text).length;
    if (display.isOdd) return false;
    final inline = RegExp(
      r'(?<!\\)\$',
    ).allMatches(text.replaceAll(r'$$', '')).length;
    if (inline.isOdd) return false;
    for (final tag in ['draw', 'await']) {
      if ('<$tag>'.allMatches(text).length !=
          '</$tag>'.allMatches(text).length) {
        return false;
      }
    }
    return r'\['.allMatches(text).length == r'\]'.allMatches(text).length &&
        r'\('.allMatches(text).length == r'\)'.allMatches(text).length;
  }

  /// Splits streamed text into pieces. The first piece may end at a comma so
  /// the voice starts sooner; later pieces end at sentence marks. A piece
  /// never ends inside a code block or formula, nor at the dot of a list
  /// number. Pieces without anything to say still keep their raw text.
  static List<SpeechPiece> takePieces(
    StringBuffer buffer, {
    required bool first,
    bool flush = false,
    bool? chinese,
  }) {
    final result = <SpeechPiece>[];
    var text = buffer.toString();
    final zh = chinese ?? looksChinese(text);
    final sentenceEnd = RegExp(
      r'[。！？!?；;…\n]+|(?<!^[ \t]*\d{1,2})\.(?=\s|$)',
      multiLine: true,
    );
    final clauseEnd = RegExp(r'[，,、：:]');
    while (true) {
      final opening = first && result.isEmpty;
      final current = text;
      int? cut;
      for (final end in sentenceEnd.allMatches(current)) {
        if (_closed(current.substring(0, end.end))) {
          cut = end.end;
          break;
        }
      }
      if (cut == null || cut > 120 || opening) {
        // Open quickly at the first comma; split long runs at their last.
        final limit = current.length > 120 ? 120 : current.length;
        final commas = clauseEnd
            .allMatches(current.substring(0, limit))
            .where((m) => _closed(current.substring(0, m.end)))
            .where(
              (m) => opening
                  ? speechText(
                          current.substring(0, m.end),
                          chinese: zh,
                        ).length >=
                        2
                  : m.end >= 40,
            );
        if (commas.isNotEmpty && (opening || cut == null || cut > 120)) {
          final comma = opening ? commas.first.end : commas.last.end;
          if (cut == null || comma < cut) cut = comma;
        }
      }
      if (cut == null) break;
      final raw = text.substring(0, cut);
      text = text.substring(cut);
      final spoken = speechText(raw, chinese: zh);
      result.add((
        raw: raw,
        spoken: _speakable.hasMatch(spoken) ? spoken : '',
        cues: _cues(raw, zh),
      ));
    }
    if (flush && text.isNotEmpty) {
      final spoken = speechText(text, chinese: zh);
      result.add((
        raw: text,
        spoken: _speakable.hasMatch(spoken) ? spoken : '',
        cues: _cues(text, zh),
      ));
      text = '';
    }
    buffer
      ..clear()
      ..write(text);
    return result;
  }

  static List<SpeechCue> _cues(String raw, bool chinese) {
    final matches = AnnotationService.tag.allMatches(raw).toList();
    if (matches.isEmpty) return const [];
    final total = speechText(raw, chinese: chinese).length;
    return [
      for (final match in matches)
        (
          command: match[1]!,
          at: total == 0
              ? 0.0
              : (speechText(
                          raw.substring(0, match.start),
                          chinese: chinese,
                        ).length /
                        total)
                    .clamp(0.0, 1.0),
        ),
    ];
  }

  /// The spoken text of [takePieces], skipping silent pieces.
  static List<String> takeSentences(
    StringBuffer buffer, {
    required bool first,
    bool flush = false,
  }) => [
    for (final piece in takePieces(buffer, first: first, flush: flush))
      if (piece.spoken.isNotEmpty) piece.spoken,
  ];
}

/// Text fed to the voice as a reply streams in.
abstract class SpeechUtterance {
  void add(String text);
  void close();

  /// Completes when everything has been spoken, or speech was interrupted.
  Future<void> get done;
}

/// Where a piece sits on the playback timeline. Its end is known once its
/// audio has fully arrived; until then its length is estimated.
class _Span {
  _Span(this.raw, this.estimate, this.cues);
  final String raw;

  /// Expected length in seconds.
  final double estimate;
  final List<SpeechCue> cues;
  int? start;
  int end = 0;
  int rate = 0;
  bool complete = false;
  int nextCue = 0;

  int frames(double pace) {
    final from = start;
    if (from == null) return 0;
    final heard = end - from;
    if (complete || rate == 0) return heard;
    return math.max(heard, (estimate * pace * rate).round());
  }
}

class _Utterance implements SpeechUtterance {
  _Utterance(
    this.service,
    this.generation,
    this.config,
    this.speed,
    this.onCaption,
    this.onCue,
  );
  final SpeechService service;
  final int generation;
  final SpeechConfig config;
  final double speed;
  final void Function(String spoken)? onCaption;
  final void Function(String cue)? onCue;
  final _buffer = StringBuffer();
  final _pending = Queue<SpeechPiece>();
  // Pieces whose audio has been requested, in speaking order.
  final _renders = Queue<({SpeechPiece piece, Future<SpeechAudio>? audio})>();
  final _finished = Completer<void>();
  final _spans = <_Span>[];
  bool _running = false;
  Completer<void>? _wake;
  bool _closed = false, _started = false;
  // Formulas and symbols are worded in the reply's language.
  // A Chinese voice always gets Chinese wording, even before the first
  // Chinese character arrives ("3.20" as 三点二零 at the very start).
  late bool _chinese = config.voice.startsWith('zh-');
  String _caption = '';

  bool get _live => generation == service._generation;

  @override
  Future<void> get done => _finished.future;

  @override
  void add(String text) {
    if (_closed || !_live) return;
    _buffer.write(text);
    _chinese = _chinese || looksChinese(text);
    _push(
      SpeechService.takePieces(_buffer, first: !_started, chinese: _chinese),
    );
  }

  @override
  void close() {
    if (_closed) return;
    _push(
      SpeechService.takePieces(
        _buffer,
        first: !_started,
        flush: true,
        chinese: _chinese,
      ),
    );
    _closed = true;
    _signal();
  }

  void _push(List<SpeechPiece> pieces) {
    if (pieces.isEmpty) return;
    _started = true;
    _pending.addAll(pieces);
    _fill();
    _signal();
  }

  void _signal() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  void _cancel() {
    _pending.clear();
    _renders.clear();
    _closed = true;
    _signal();
  }

  /// Requests audio for the next pieces, a few ahead of the one heard.
  void _fill() {
    if (!_running) return;
    while (_live &&
        _renders.length < SpeechService.lookahead &&
        _pending.isNotEmpty) {
      final piece = _pending.removeFirst();
      Future<SpeechAudio>? audio;
      if (piece.spoken.isNotEmpty) {
        audio = service
            ._synthesize(piece.spoken, config.voice, speed)
            .then(service._output.decode);
        // Audio of an interrupted reply is never awaited; its errors are
        // of no interest.
        audio.ignore();
      }
      _renders.add((piece: piece, audio: audio));
    }
  }

  /// Reply text up to [played] frames: whole pieces already heard plus the
  /// matching share of the piece being spoken.
  String _captionAt(int played) {
    final caption = StringBuffer();
    for (final span in _spans) {
      final start = span.start;
      if (start == null) break;
      final frames = span.frames(service._pace);
      if (played >= start + frames) {
        caption.write(span.raw);
      } else if (played > start) {
        final share = (played - start) / frames;
        final characters = span.raw.characters;
        caption.write(characters.take((characters.length * share).ceil()));
        break;
      } else {
        break;
      }
    }
    return caption.toString();
  }

  /// Drawings due by [played] frames, in order.
  void _cuesAt(int played) {
    for (final span in _spans) {
      final start = span.start;
      if (start == null) return;
      final frames = span.frames(service._pace);
      while (span.nextCue < span.cues.length) {
        final cue = span.cues[span.nextCue];
        if (played < start + (frames * cue.at).round()) return;
        span.nextCue++;
        onCue?.call(cue.command);
      }
    }
  }

  Future<void> _run() async {
    var speaking = false;
    var end = 0;
    Timer? follow;
    Future<int> played() async {
      try {
        return (await service._output.position()).played;
      } catch (_) {
        return end;
      }
    }

    void report(int frame) {
      // Drawings appear as the voice reaches the words they belong to.
      _cuesAt(frame);
      final caption = _captionAt(frame);
      if (caption != _caption) {
        _caption = caption;
        onCaption?.call(caption);
      }
    }

    _running = true;
    try {
      // Open the speaker while the first sentence is being requested.
      unawaited(service._output.prepare(service._lastRate).catchError((_) {}));
      _fill();
      // Captions follow the voice ~20 times a second.
      if (onCaption != null || onCue != null) {
        follow = Timer.periodic(const Duration(milliseconds: 50), (_) async {
          if (_live) report(await played());
        });
      }
      while (_live) {
        _fill();
        if (_renders.isEmpty) {
          if (_closed) break;
          await (_wake = Completer<void>()).future;
          continue;
        }
        final render = _renders.removeFirst();
        _fill();
        final piece = render.piece;
        // Shown as written — formulas as symbols — while the voice says
        // them in words.
        final caption = displayText(piece.raw).trim();
        final span = _Span(
          // Captions show what is said, e.g. a formula in words.
          piece.spoken.isEmpty ? '' : (_chinese ? caption : '$caption '),
          SpeechService.estimateSeconds(piece.spoken) / speed,
          piece.cues,
        );
        _spans.add(span);
        final audio = render.audio;
        if (audio != null) {
          final chunk = await audio;
          if (!_live) break;
          if (chunk.samples.isNotEmpty) {
            service._outputBusy = true;
            end = await service._output.play(chunk.samples, chunk.rate);
            if (!_live) break;
            service._lastRate = span.rate = chunk.rate;
            span.start ??= end - chunk.samples.length;
            span.end = end;
            if (!speaking) {
              speaking = true;
              service._states.add(true);
            }
          }
        }
        if (!_live) break;
        // A silent piece (or one without audio) sits where the voice is.
        span.start ??= end;
        span.end = math.max(span.end, span.start!);
        span.complete = true;
        final heard = span.rate == 0
            ? 0.0
            : (span.end - span.start!) / span.rate;
        if (span.estimate > .5 && heard > 0) {
          service._pace = (service._pace * .7 + (heard / span.estimate) * .3)
              .clamp(.4, 2.5);
        }
      }
      // Let the queued audio finish.
      while (_live && await played() < end) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      if (_live) report(end);
    } catch (error) {
      if (_live && !_finished.isCompleted) {
        _finished.completeError(
          error is SpeechServiceException
              ? error
              : error is EdgeTtsException
              ? SpeechServiceException(error.message)
              : error is TimeoutException
              ? const SpeechServiceException('speechTimeout')
              : SpeechServiceException(error.toString()),
        );
      }
    } finally {
      follow?.cancel();
      if (speaking && !service._states.isClosed) service._states.add(false);
      if (identical(service._current, this)) service._current = null;
      if (!_finished.isCompleted) _finished.complete();
    }
  }
}

class SpeechServiceException implements Exception {
  const SpeechServiceException(this.message);
  final String message;
  @override
  String toString() => message;
}
