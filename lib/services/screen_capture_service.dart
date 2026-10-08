import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_capturer/screen_capturer.dart';

/// Something on a screenshot the assistant can point at: a line of text
/// found by OCR, or a control (button, tab, menu item...) found by UI
/// Automation. Boxed as [x1, y1, x2, y2] in the screenshot's 0–1000
/// coordinates.
class ScreenTextLine {
  const ScreenTextLine(this.box, this.text, {this.kind = 'text'});
  final List<int> box;
  final String text;

  /// 'text', or the control's kind: button, menu, tab, link, check, radio,
  /// combo, edit, item, tree, split.
  final String kind;
}

class ScreenCaptureService {
  static const _channel = MethodChannel('ai.ramizom.magic_wand/screen');

  /// The text on the latest gridded capture, read by on-device OCR.
  List<ScreenTextLine> lastText = const [];

  /// The clickable controls on the latest gridded capture.
  List<ScreenTextLine> lastControls = const [];

  /// The elements listed for the model with the latest gridded capture,
  /// numbered from 1 in this order.
  List<ScreenTextLine> get lastElements => elements(lastText, lastControls);

  /// Most elements listed: controls first, then text, enough for any task
  /// while keeping each request small.
  static const maxElements = 150;

  /// Controls and text as one list, top to bottom. A text line that only
  /// repeats a control's name is left out.
  static List<ScreenTextLine> elements(
    List<ScreenTextLine> text,
    List<ScreenTextLine> controls,
  ) {
    final names = {for (final c in controls) c.text};
    final chosen = [
      ...controls.take(maxElements),
      ...text.where((t) => !names.contains(t.text)),
    ].take(maxElements).toList();
    chosen.sort(
      (a, b) => a.box[1] != b.box[1]
          ? a.box[1].compareTo(b.box[1])
          : a.box[0].compareTo(b.box[0]),
    );
    return chosen;
  }

  /// Shows or hides the flowing light around the screen edges that tells the
  /// user their screen is being shared.
  Future<void> setGlow(bool visible) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('setScreenGlow', {'visible': visible});
    } on MissingPluginException {
      // Widget tests have no native runner.
    } on PlatformException {
      // The glow is decorative; sharing works without it.
    }
  }

  /// A JPEG of the whole desktop. With [grid], a faint 0–1000 grid helps
  /// the model place annotations, and [lastText] lists where the text on
  /// screen is; the preview never shows either.
  Future<Uint8List?> capture({bool grid = false}) async {
    if (Platform.isWindows) {
      final result = await _channel.invokeMethod<Object?>('captureScreen', {
        'maxWidth': 1440,
        'grid': grid,
      });
      if (result is! Map) return null;
      if (grid) {
        lastText = parseText(result['text']);
        lastControls = parseText(result['controls']);
      }
      return result['bytes'] as Uint8List?;
    }

    final temp = await getTemporaryDirectory();
    final data = await screenCapturer.capture(
      mode: CaptureMode.screen,
      imagePath: '${temp.path}/ramizom-screen.png',
      copyToClipboard: false,
      silent: true,
    );
    return data?.imageBytes;
  }

  /// A tiny grayscale picture of the whole desktop (96 x 60), cheap enough
  /// to take every couple of seconds to notice the screen changing.
  Future<Uint8List?> fingerprint() async {
    if (!Platform.isWindows) return null;
    try {
      final result = await _channel.invokeMethod<Object?>('screenFingerprint');
      return result is Map ? result['bytes'] as Uint8List? : null;
    } on MissingPluginException {
      return null;
    }
  }

  /// How much of the screen differs between two fingerprints: the share of
  /// pixels whose brightness changed noticeably, 0 to 1.
  static double difference(Uint8List a, Uint8List b) {
    if (a.length != b.length || a.isEmpty) return 1;
    var changed = 0;
    for (var i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > 24) changed++;
    }
    return changed / a.length;
  }

  static List<ScreenTextLine> parseText(Object? value) {
    if (value is! List) return const [];
    final lines = <ScreenTextLine>[];
    for (final item in value) {
      if (item is! Map) continue;
      final box = item['box'], text = item['text'];
      if (box is! List || box.length != 4 || box.any((n) => n is! num)) {
        continue;
      }
      if (text is! String || !_meaningful(text)) continue;
      final kind = item['kind'];
      lines.add(
        ScreenTextLine(
          [for (final n in box) (n as num).round()],
          text.trim(),
          kind: kind is String ? kind : 'text',
        ),
      );
    }
    return lines;
  }

  /// Whether a recognized line is worth listing: line numbers, lone icons
  /// and stray glyphs only cost the model attention.
  static bool _meaningful(String text) {
    final letters = RegExp(r'[\p{L}]', unicode: true).allMatches(text).length;
    final digits = RegExp(r'\d').allMatches(text).length;
    return letters >= 2 || digits >= 3;
  }
}
