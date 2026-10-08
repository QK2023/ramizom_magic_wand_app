import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramizom_magic_wand/controllers/app_controller.dart';
import 'package:ramizom_magic_wand/models/app_settings.dart';
import 'package:ramizom_magic_wand/services/ai_service.dart';
import 'package:ramizom_magic_wand/services/annotation_service.dart';
import 'package:ramizom_magic_wand/services/screen_capture_service.dart';
import 'package:ramizom_magic_wand/services/speech_service.dart';
import 'controller_test.dart' show ControlledAi, MemoryStore;

class FakeCapture extends ScreenCaptureService {
  @override
  Future<Uint8List?> capture({bool grid = false}) async =>
      Uint8List.fromList([0xFF, 0xD8, 1]);
  @override
  Future<void> setGlow(bool visible) async {}
}

void main() {
  test('commands use x-first boxes and points, kept on screen', () {
    expect(
      AnnotationService.parse(
        '{"type":"highlight","box":[120,310,560,340],"target":"Save"}',
      ),
      allOf(
        containsPair('numbers', [120.0, 310.0, 560.0, 340.0]),
        containsPair('target', 'Save'),
      ),
    );
    // Reversed corners are put right; coordinates are kept on screen.
    expect(
      AnnotationService.parse('{"type":"circle","box":[900,400,-20,300]}'),
      allOf(
        containsPair('numbers', [0.0, 300.0, 900.0, 400.0]),
        containsPair('target', ''),
      ),
    );
    expect(
      AnnotationService.parse(
        '{"type":"arrow","from":[460,700],"to":[300,580],"color":"blue",'
        '"target":"File"}',
      ),
      allOf(
        containsPair('numbers', [460.0, 700.0, 300.0, 580.0]),
        containsPair('color', 'blue'),
        containsPair('target', 'File'),
      ),
    );
    expect(
      AnnotationService.parse('{"type":"path","points":[[1,2],[3,4],[5,6]]}'),
      containsPair('points', [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]),
    );
    // Notes never look for a target.
    expect(
      AnnotationService.parse(
        '{"type":"text","at":[200,100],"text":"x=1","target":"x"}',
      ),
      allOf(
        containsPair('numbers', [200.0, 100.0]),
        containsPair('text', 'x=1'),
        containsPair('target', ''),
      ),
    );
    // Whiteboard pages carry their title.
    expect(
      AnnotationService.parse('{"type":"whiteboard","title":"二次函数"}'),
      containsPair('text', '二次函数'),
    );
    expect(AnnotationService.parse('{"type":"close_whiteboard"}'), isNotNull);
    // Malformed or unknown commands are dropped, never guessed at.
    expect(AnnotationService.parse('{"type":"circle","box":[1,2]}'), isNull);
    expect(
      AnnotationService.parse('{"type":"circle","x":1,"y":2,"r":3}'),
      isNull,
    );
    expect(AnnotationService.parse('{"type":"explode"}'), isNull);
    expect(AnnotationService.parse('not json'), isNull);
    expect(AnnotationService.parse('{"type":"text","at":[1,2]}'), isNull);
  });

  test('recognized screen text is listed for the model, bounded', () {
    final lines = ScreenCaptureService.parseText([
      {
        'box': [10, 20, 300, 40],
        'text': ' File  Edit ',
      },
      {
        'box': [1, 2, 3],
        'text': 'bad box',
      },
      {
        'box': [1, 2, 3, 4],
        'text': '  ',
      },
      // Line numbers and stray glyphs are left out; prices are not.
      for (final noise in ['12 ,', '>', 'x', 'O'])
        {
          'box': [1, 2, 3, 4],
          'text': noise,
        },
      {
        'box': [5, 6, 7, 8],
        'text': '¥128',
      },
      'junk',
    ]);
    expect(lines.map((l) => l.text), ['File  Edit', '¥128']);
    expect(lines.first.box, [10, 20, 300, 40]);
    final described = AiService.describeElements(lines);
    expect(described, contains('1 text 10,20,300,40 File  Edit'));
    final many = [
      for (var i = 0; i < 400; i++) ScreenTextLine([0, i, 10, i + 1], 'l$i'),
    ];
    expect(
      ScreenCaptureService.elements(many, const []),
      hasLength(ScreenCaptureService.maxElements),
    );
  });

  test('controls and text are listed together, numbered top to bottom', () {
    final text = ScreenCaptureService.parseText([
      {
        'box': [100, 400, 600, 420],
        'text': '点击保存按钮保存文件',
      },
      {
        'box': [900, 10, 960, 30],
        'text': 'Close',
      },
    ]);
    final controls = ScreenCaptureService.parseText([
      {
        'box': [900, 10, 960, 30],
        'text': 'Close',
        'kind': 'button',
      },
      {
        'box': [20, 50, 60, 80],
        'text': 'Save (Ctrl+S)',
        'kind': 'button',
      },
    ]);
    final elements = ScreenCaptureService.elements(text, controls);
    // The text "Close" only repeats the button.
    expect(elements.map((e) => e.text), [
      'Close',
      'Save (Ctrl+S)',
      '点击保存按钮保存文件',
    ]);
    expect(
      AiService.describeElements(elements),
      'Screen elements (id kind box label):\n'
      '1 button 900,10,960,30 Close\n'
      '2 button 20,50,60,80 Save\n'
      '3 text 100,400,600,420 点击保存按钮保存文件',
    );

    // Pointing by id lands on the element's own box, exactly.
    final circle = AnnotationService.parse(
      '{"type":"circle","ref":2}',
      elements: elements,
    )!;
    expect(circle['numbers'], [20.0, 50.0, 60.0, 80.0]);
    expect(circle['exact'], isTrue);
    final highlight = AnnotationService.parse(
      '{"type":"highlight","ref":3,"target":"保存按钮"}',
      elements: elements,
    )!;
    expect(highlight['numbers'], [100.0, 400.0, 600.0, 420.0]);
    expect(highlight['target'], '保存按钮');
    // An arrow ends just outside the box, coming from the screen's middle.
    final arrow = AnnotationService.parse(
      '{"type":"arrow","ref":2}',
      elements: elements,
    )!;
    final n = arrow['numbers'] as List<double>;
    expect(n[2], inInclusiveRange(60, 75));
    expect(n[3], inInclusiveRange(80, 95));
    expect(n[0], greaterThan(n[2]));
    // An unknown id falls back to coordinates, or is dropped without any.
    expect(
      AnnotationService.parse('{"type":"circle","ref":9}', elements: elements),
      isNull,
    );
    expect(
      AnnotationService.parse(
        '{"type":"circle","ref":9,"box":[1,2,3,4]}',
        elements: elements,
      )!['exact'],
      isFalse,
    );
  });

  test('commands never show as text, even half streamed', () {
    const reply = '先看这里<draw>{"type":"circle","box":[1,2,3,4]}</draw>，这是标题。';
    expect(AnnotationService.strip(reply), '先看这里，这是标题。');
    expect(AnnotationService.strip('好的<draw>{"type":"ci'), '好的');
    expect(AnnotationService.strip('好的<dr'), '好的');
    expect(AnnotationService.count(reply), 1);
  });

  test('each spoken piece carries its drawing and is never cut inside one', () {
    final buffer = StringBuffer(
      '<draw>{"type":"box","box":[1,2,3,4]}</draw>这一块是输入区。'
      '<draw>{"type":"text","at":[5,6],"text":"a. b"}',
    );
    final pieces = SpeechService.takePieces(buffer, first: false);
    expect(pieces.single.spoken, '这一块是输入区。');
    expect(pieces.single.cues.single.command, contains('"box"'));
    expect(pieces.single.cues.single.at, 0);
    // The unfinished command waits for the rest of its text.
    expect(buffer.toString(), startsWith('<draw>'));
    buffer.write('</draw>然后看这里。');
    final next = SpeechService.takePieces(buffer, first: false);
    expect(next.single.cues.single.command, contains('"text"'));
    expect(next.single.spoken, '然后看这里。');
  });

  testWidgets('with a shared screen, drawings are performed as they arrive', (
    tester,
  ) async {
    final ai = ControlledAi();
    final c =
        AppController(
            aiService: ai,
            captureService: FakeCapture(),
            workspaceStore: MemoryStore(),
          )
          ..loading = false
          ..sharingScreen = true
          ..settings = const AppSettings(apiKey: 'k', speakReplies: false);
    final request = c.sendText('这个界面怎么用？');
    await tester.pump();
    expect(ai.lastAnnotate, isTrue);
    ai.output.add(
      '先看这里<draw>{"type":"circle","box":[380,460,420,540]}</draw>，'
      '这是标题。<dr',
    );
    await tester.pump();
    // Drawings wait for the text before them to be read, not all at once.
    expect(c.annotations, 0);
    await tester.pump(const Duration(milliseconds: 800));
    expect(c.annotations, 1);
    expect(c.liveCaption, '先看这里，这是标题。');
    ai.output.add('aw>{"type":"clear"}</draw>好了。');
    await tester.pump(const Duration(seconds: 3));
    expect(c.annotations, 0);
    await ai.output.close();
    await tester.pump();
    expect(await request, isTrue);
    c.dispose();
  });

  test('a drawing in the middle of a sentence keeps its place there', () {
    final buffer = StringBuffer(
      '这个函数<draw>{"type":"circle","box":[1,2,3,4]}</draw>返回一个列表。',
    );
    final cue = SpeechService.takePieces(
      buffer,
      first: false,
    ).single.cues.single;
    expect(cue.at, closeTo(4 / 11, .01));
  });
}
