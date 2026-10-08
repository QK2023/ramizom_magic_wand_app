import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ramizom_magic_wand/controllers/app_controller.dart';
import 'package:ramizom_magic_wand/models/app_settings.dart';
import 'package:ramizom_magic_wand/models/chat_message.dart';
import 'package:ramizom_magic_wand/services/ai_service.dart';
import 'package:ramizom_magic_wand/services/annotation_service.dart';
import 'package:ramizom_magic_wand/services/guide_service.dart';
import 'package:ramizom_magic_wand/services/screen_capture_service.dart';
import 'package:ramizom_magic_wand/services/speech_service.dart';

import 'controller_test.dart' show MemoryStore, silentSpeech;

/// Answers each request with the next scripted reply.
class ScriptedAi extends AiService {
  ScriptedAi(this.replies);
  final List<String> replies;
  final requests = <ChatMessage>[];
  final frames = <Uint8List?>[];
  @override
  Stream<String> stream({
    required AppSettings settings,
    required List<ChatMessage> history,
    required ChatMessage message,
    Uint8List? screenFrame,
    List<ScreenTextLine> screenText = const [],
    bool voice = false,
    bool annotate = false,
    bool background = false,
  }) {
    requests.add(message);
    frames.add(screenFrame);
    return Stream.value(replies.isEmpty ? '' : replies.removeAt(0));
  }
}

/// A screen whose text the test changes.
class ChangingScreen extends ScreenCaptureService {
  List<String> lines = ['文件 开始 插入 设计', '这是文档正文'];
  @override
  Future<Uint8List?> capture({bool grid = false}) async {
    if (grid) {
      lastText = [
        for (final line in lines) ScreenTextLine(const [0, 0, 10, 10], line),
      ];
    }
    return Uint8List.fromList([0xFF, 0xD8, 1]);
  }

  /// The fingerprint follows the lines: each one lights a band of pixels.
  @override
  Future<Uint8List?> fingerprint() async {
    final print = Uint8List(1000);
    for (final (i, text) in lines.indexed) {
      print.fillRange(i * 100, i * 100 + 100, text.hashCode % 200 + 50);
    }
    return print;
  }

  @override
  Future<void> setGlow(bool visible) async {}
}

void main() {
  test('a screen change counts once it is more than a clock ticking', () {
    final before = Uint8List(5760);
    final clock = Uint8List.fromList(before)..fillRange(0, 6, 200);
    final menu = Uint8List.fromList(before)..fillRange(1000, 1400, 200);
    expect(
      ScreenCaptureService.difference(before, clock),
      lessThan(GuideService.changed),
    );
    expect(
      ScreenCaptureService.difference(before, menu),
      greaterThan(GuideService.changed),
    );
    expect(ScreenCaptureService.difference(before, Uint8List(3)), 1);
  });

  test('verdicts are read from JSON, anything else is "still waiting"', () {
    expect(GuideService.verdict('{"status":"done"}').status, GuideStatus.done);
    final wrong = GuideService.verdict(
      '好的：{"status":"wrong","reason":"打开的是设计菜单"}',
    );
    expect(wrong.status, GuideStatus.wrong);
    expect(wrong.reason, '打开的是设计菜单');
    expect(GuideService.verdict('done!').status, GuideStatus.waiting);
    expect(
      GuideService.verdict('{"status":"maybe"}').status,
      GuideStatus.waiting,
    );
    final prompt = GuideService.checkPrompt(
      step: const GuideStep(2, '出现插入表格对话框'),
      instruction: '点"表格"。',
    );
    expect(prompt, contains('出现插入表格对话框'));
    expect(prompt, contains('JSON only'));
  });

  test('step goals are never shown or spoken', () {
    const reply =
        '点这里<draw>{"type":"arrow","from":[1,2],"to":[3,4]}</draw>的"插入"。'
        '<await>出现插入菜单</await>';
    expect(AnnotationService.strip(reply), '点这里的"插入"。');
    expect(AnnotationService.awaitGoal(reply), '出现插入菜单');
    expect(AnnotationService.awaitGoal('没有下一步了。'), isNull);
    // Half streamed.
    expect(AnnotationService.strip('点"插入"。<await>出现插'), '点"插入"。');
    expect(AnnotationService.strip('点"插入"。<awa'), '点"插入"。');
    final buffer = StringBuffer('点"插入"。<await>出现。插入菜单</await>');
    final spoken = SpeechService.takeSentences(
      buffer,
      first: false,
      flush: true,
    );
    expect(spoken.join(), isNot(contains('出现')));
  });

  test('app notes survive saving', () {
    final note = ChatMessage(
      role: 'user',
      text: '[Observation] step 1 done',
      note: '第 1 步完成',
      createdAt: DateTime(2026),
    );
    expect(ChatMessage.fromJson(note.toJson()).note, '第 1 步完成');
    expect(
      ChatMessage.fromJson(
        ChatMessage(
          role: 'user',
          text: 'hi',
          createdAt: DateTime(2026),
        ).toJson(),
      ).note,
      isNull,
    );
  });

  testWidgets('a walkthrough watches the screen and moves on by itself', (
    tester,
  ) async {
    final ai = ScriptedAi([
      '先点上面的"插入"。<draw>{"type":"arrow","from":[500,500],"to":[200,30],'
          '"target":"插入"}</draw><await>出现插入菜单，里面有"表格"</await>',
      '{"status":"done"}',
      '很好！再点"表格"。<await>出现表格网格</await>',
      '好，这就完成了。',
    ]);
    final screen = ChangingScreen();
    final c =
        AppController(
            aiService: ai,
            captureService: screen,
            workspaceStore: MemoryStore(),
            speechService: silentSpeech(),
          )
          ..loading = false
          ..sharingScreen = true
          ..settings = const AppSettings(apiKey: 'k', speakReplies: false);

    await c.sendText('教我在文档里插入表格');
    await tester.pump();
    expect(c.guide?.number, 1);
    expect(c.guide?.goal, '出现插入菜单，里面有"表格"');

    // Nothing happens on screen: nobody is asked anything.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(ai.requests, hasLength(1));

    // The user opens the menu; once the screen settles, it is checked.
    screen.lines = [...screen.lines, '表格 图片 形状', '插入表格'];
    await tester.pump(const Duration(seconds: 2));
    expect(ai.requests, hasLength(1));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(ai.requests[1].text, contains('出现插入菜单'));
    // "Done": a note in the chat, and the next step.
    await tester.pump();
    expect(ai.requests, hasLength(3));
    expect(ai.requests[2].text, startsWith('[Observation]'));
    expect(c.messages.where((m) => m.note == '第 1 步完成'), hasLength(1));
    expect(c.guide?.number, 2);
    expect(c.guide?.goal, '出现表格网格');

    // The user says they are done; the task ends and so does guiding.
    await c.guideFinished();
    await tester.pump();
    expect(c.messages.last.text, '好，这就完成了。');
    expect(c.guide, isNull);
    c.dispose();
  });

  testWidgets('guiding ends with screen sharing', (tester) async {
    final ai = ScriptedAi(['点"开始"。<await>出现开始菜单</await>']);
    final c =
        AppController(
            aiService: ai,
            captureService: ChangingScreen(),
            workspaceStore: MemoryStore(),
            speechService: silentSpeech(),
          )
          ..loading = false
          ..sharingScreen = true
          ..settings = const AppSettings(apiKey: 'k', speakReplies: false);
    await c.sendText('怎么关机');
    await tester.pump();
    expect(c.guide, isNotNull);
    await c.toggleScreenSharing();
    expect(c.guide, isNull);
    c.dispose();
  });

  test('no screen, no walkthrough', () async {
    final ai = ScriptedAi(['点"开始"。<await>出现开始菜单</await>']);
    final c =
        AppController(
            aiService: ai,
            captureService: ChangingScreen(),
            workspaceStore: MemoryStore(),
            speechService: silentSpeech(),
          )
          ..loading = false
          ..settings = const AppSettings(apiKey: 'k', speakReplies: false);
    await c.sendText('怎么关机');
    expect(c.guide, isNull);
    // The goal is not shown either.
    expect(AnnotationService.strip(c.messages.last.text), '点"开始"。');
    c.dispose();
  });

  test('exercises open the board for handwriting', () {
    expect(
      AnnotationService.parse('{"type":"exercise"}'),
      containsPair('type', 'exercise'),
    );
  });

  testWidgets('a handed-in answer is marked from the whiteboard', (
    tester,
  ) async {
    final ai = ScriptedAi([
      '来试一题：<draw>{"type":"whiteboard","title":"练习"}</draw>'
          '<draw>{"type":"text","at":[60,80],"text":"2x + 3 = 7"}</draw>'
          '解出 x。<draw>{"type":"exercise"}</draw>',
      '<draw>{"type":"circle","box":[100,300,400,380]}</draw>第二步移项时符号错了。',
    ]);
    final c =
        AppController(
            aiService: ai,
            captureService: ChangingScreen(),
            workspaceStore: MemoryStore(),
            speechService: silentSpeech(),
          )
          ..loading = false
          ..sharingScreen = true
          ..settings = const AppSettings(apiKey: 'k', speakReplies: false);
    await c.sendText('出道题给我练练');
    // Drawings keep a reading pace when not spoken.
    await tester.pump(const Duration(seconds: 10));
    expect(c.exercising, isTrue);

    final board = Uint8List.fromList([0xFF, 0xD8, 0xFF, 7]);
    await c.submitAnswer(board);
    await tester.pump();
    expect(c.exercising, isFalse);
    // The board, not the screen, is what gets looked at.
    expect(ai.frames.last, board);
    expect(ai.requests.last.text, startsWith('[Answer]'));
    expect(c.messages.where((m) => m.note == '已交卷'), hasLength(1));
    expect(c.messages.last.text, contains('符号错了'));
    // A second hand-in without a new exercise is ignored.
    await c.submitAnswer(board);
    expect(ai.requests, hasLength(2));
    await tester.pump(const Duration(seconds: 10));
    c.dispose();
  });
}
