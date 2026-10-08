import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'screen_capture_service.dart';

/// Lets the assistant teach visually: by marking up the shared screen, or on
/// a whiteboard window of its own when the screen offers nothing to point at.
///
/// The model writes `<draw>{json}</draw>` commands into its reply, right
/// before the words they illustrate. They never appear as text: the chat,
/// captions and voice strip them, and each one is drawn by the native
/// overlay (windows/runner/screen_annotator.cpp) when its words are spoken,
/// or at a reading pace when the reply is not read aloud.
///
/// Coordinates are 0–1000 on the screenshot, x first: points [x, y] and
/// boxes [x1, y1, x2, y2]. Marks on text also name the words ("target"),
/// which the native side finds on screen by OCR, so they land exactly even
/// when the model's box is off.
class AnnotationService {
  static const _channel = MethodChannel('ai.ramizom.magic_wand/annotate');

  /// Added to the system prompt while the screen is shared.
  static const prompt =
      'You can draw while you explain, like a teacher. Offer it when a visual '
      'walk-through would help; draw once they agree or ask. Put each '
      'command as <draw>{json}</draw> right before the words it illustrates, '
      'one per point, spread through the reply; it appears as those words '
      'are spoken and is never shown as text.\n'
      'On screen, point at listed Screen elements by id: '
      '{"type":"circle|box|highlight|underline","ref":12}, adding '
      '"target":"exact words" to mark only part of a text line; '
      '{"type":"arrow","ref":12}. Only for what is not listed, use 0–1000 '
      'screenshot coordinates (x right, y down; grid every 100): '
      '"box":[x1,y1,x2,y2], arrows "from":[x,y],"to":[x,y].\n'
      'Also: {"type":"text","at":[x,y],"text":"short note","size":"s|m|l"}, '
      '{"type":"line","from":[x,y],"to":[x,y]}, '
      '{"type":"path","points":[[x,y],...]}, {"type":"clear"}; optional '
      '"color": red|blue|green|yellow|orange|purple|black.\n'
      'Whiteboard, for explaining from scratch, diagrams, formulas, worked '
      'steps, or when the screen has no room: {"type":"whiteboard","title":'
      '"..."}; until {"type":"close_whiteboard"} everything goes on it, in '
      '0–1000 board coordinates. Closing just returns you to the screen; the '
      'board stays until the student closes it.\n'
      'Practice: write a question on the board, then {"type":"exercise"}; '
      'the student writes by hand and hands in an [Answer] with an image of '
      'the board. Mark it there (green tick for right steps; red circle and '
      'a short correction for mistakes), then hint and let them retry rather '
      'than giving the solution, unless asked.\n'
      'Walkthroughs (doing something on their computer): one step per reply '
      '- say it, point at the control, end with <await>what the screen shows '
      'when done</await>, stop. [Observation] messages come from the app '
      'watching the screen: on done, acknowledge briefly and give the next '
      'step; on a wrong turn, guide them back. No <await> once finished.\n'
      'Few, purposeful marks; never mention the commands.';

  static final tag = RegExp(r'<draw>([\s\S]*?)</draw>');

  /// Ends a walkthrough step: what the screen will show once it is done.
  static final awaitTag = RegExp(r'<await>([\s\S]*?)</await>');

  /// [text] without drawing commands, step goals or review marks,
  /// including one still streaming in.
  static String strip(String text) => text
      .replaceAll(tag, '')
      .replaceAll(awaitTag, '')
      .replaceAll(RegExp(r'<review\b[^>]*>'), '')
      .replaceAll(RegExp(r'<(draw|await)>[\s\S]*$'), '')
      .replaceAll(RegExp(r'<review\b[^>]*$'), '')
      .replaceAll(
        RegExp(r'<(d(r(a(w)?)?)?|a(w(a(i(t)?)?)?)?|r(e(v(i(e(w)?)?)?)?)?)?$'),
        '',
      );

  /// The goal of the walkthrough step a reply ends with, if it does.
  static String? awaitGoal(String text) {
    final goals = awaitTag.allMatches(text).toList();
    if (goals.isEmpty) return null;
    final goal = goals.last[1]!.trim();
    return goal.isEmpty ? null : goal;
  }

  /// Number of drawing commands in [text].
  static int count(String text) => tag.allMatches(text).length;

  static const _boxed = {'circle', 'box', 'highlight', 'underline'};
  static const _plain = {'clear', 'whiteboard', 'close_whiteboard', 'exercise'};

  /// Validates a command's JSON into native arguments, or null. Boxes are
  /// put in order as [left, top, right, bottom].
  ///
  /// A command naming an element by "ref" (an id from the Screen elements
  /// listed with the screenshot, [elements] in order) is placed on that
  /// element's own box and drawn there exactly.
  static Map<String, Object?>? parse(
    String json, {
    List<ScreenTextLine> elements = const [],
  }) {
    final Object? value;
    try {
      value = jsonDecode(json.trim());
    } on FormatException {
      return null;
    }
    if (value is! Map) return null;
    final map = value;
    final type = map['type'];
    if (type is! String) return null;

    double unit(Object? n) => (n as num).toDouble().clamp(0, 1000).toDouble();
    List<double>? point(Object? pair) {
      if (pair is! List || pair.length < 2) return null;
      if (pair[0] is! num || pair[1] is! num) return null;
      return [unit(pair[0]), unit(pair[1])];
    }

    var numbers = <double>[];
    final points = <double>[];
    final ref = map['ref'];
    final element = ref is num && ref >= 1 && ref <= elements.length
        ? elements[ref.toInt() - 1]
        : null;
    if (element != null && (_boxed.contains(type) || type == 'arrow')) {
      final box = [for (final n in element.box) n.toDouble()];
      numbers = type == 'arrow' ? arrowTo(box) : box;
    } else if (_boxed.contains(type)) {
      final box = map['box'];
      if (box is! List || box.length < 4 || box.any((n) => n is! num)) {
        return null;
      }
      final x1 = unit(box[0]), y1 = unit(box[1]);
      final x2 = unit(box[2]), y2 = unit(box[3]);
      numbers = [
        x1 < x2 ? x1 : x2,
        y1 < y2 ? y1 : y2,
        x1 < x2 ? x2 : x1,
        y1 < y2 ? y2 : y1,
      ];
    } else if (type == 'arrow' || type == 'line') {
      final from = point(map['from']), to = point(map['to']);
      if (from == null || to == null) return null;
      numbers = [...from, ...to];
    } else if (type == 'text') {
      final at = point(map['at']);
      final text = map['text'];
      if (at == null || text is! String || text.trim().isEmpty) return null;
      numbers = at;
    } else if (type == 'path') {
      final list = map['points'];
      if (list is! List) return null;
      for (final pair in list) {
        final p = point(pair);
        if (p != null) points.addAll(p);
      }
      if (points.length < 4) return null;
    } else if (!_plain.contains(type)) {
      return null;
    }
    final text = type == 'whiteboard' ? map['title'] : map['text'];
    final target = map['target'];
    return {
      'type': type,
      'numbers': numbers,
      'points': points,
      'text': text is String ? text.trim() : '',
      'color': map['color'] is String ? map['color'] : '',
      'size': map['size'] is String ? map['size'] : '',
      'exact': element != null,
      // Words to find on screen; only marks on the screen use them.
      'target': (_boxed.contains(type) || type == 'arrow') && target is String
          ? target.trim()
          : '',
    };
  }

  /// An arrow at a box: from a little way off toward the middle of the
  /// screen, to just outside the box's edge. [x1, y1, x2, y2] in, from and
  /// to out.
  static List<double> arrowTo(List<double> box) {
    final cx = (box[0] + box[2]) / 2, cy = (box[1] + box[3]) / 2;
    final hw = (box[2] - box[0]) / 2 + 6, hh = (box[3] - box[1]) / 2 + 6;
    var dx = 500 - cx, dy = 500 - cy;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length < 40) {
      dx = -1;
      dy = 1;
    } else {
      dx /= length;
      dy /= length;
    }
    // Where the line from the center leaves the box, plus a small gap.
    final reach = math.min(
      dx.abs() < 1e-6 ? double.infinity : hw / dx.abs(),
      dy.abs() < 1e-6 ? double.infinity : hh / dy.abs(),
    );
    double clamp(double v) => v.clamp(0, 1000).toDouble();
    final tipX = clamp(cx + dx * reach), tipY = clamp(cy + dy * reach);
    return [clamp(tipX + dx * 110), clamp(tipY + dy * 110), tipX, tipY];
  }

  /// Draws a parsed command; returns whether something new is on screen.
  static Future<bool> draw(Map<String, Object?> command) async {
    try {
      await _channel.invokeMethod(
        command['type'] == 'clear' ? 'clear' : 'draw',
        command,
      );
      return command['type'] != 'clear' &&
          command['type'] != 'close_whiteboard';
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Receives the student's handwritten answer from the whiteboard, as a
  /// JPEG of the board, when they hand it in.
  static void onSubmitted(void Function(Uint8List board) handler) {
    _channel.setMethodCallHandler((call) async {
      final board = call.arguments;
      if (call.method == 'submitted' && board is Uint8List) handler(board);
    });
  }

  /// Removes the marks on screen. The whiteboard stays for the user to read
  /// and close, unless [board] (the user clearing everything, or the screen
  /// no longer being shared).
  static Future<void> clear({bool board = false}) async {
    try {
      await _channel.invokeMethod('clear', {'board': board});
    } on MissingPluginException {
      // No native overlay (tests).
    } on PlatformException {
      // Nothing to clear.
    }
  }
}
