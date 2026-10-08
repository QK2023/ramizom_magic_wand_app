import 'package:flutter_test/flutter_test.dart';
import 'package:ramizom_magic_wand/controllers/app_controller.dart';
import 'package:ramizom_magic_wand/models/app_settings.dart';
import 'package:ramizom_magic_wand/models/chat_message.dart';
import 'package:ramizom_magic_wand/models/learning.dart';
import 'package:ramizom_magic_wand/services/annotation_service.dart';
import 'package:ramizom_magic_wand/services/learning_service.dart';

import 'controller_test.dart' show MemoryStore, silentSpeech;
import 'guide_test.dart' show ScriptedAi;

LearningItem item(String id, {DateTime? due}) => LearningItem(
  id: id,
  topic: '一元一次方程',
  point: '移项要变号',
  question: '把 2x + 3 = 7 的 3 移到右边会变成什么？',
  answer: '2x = 7 − 3',
  createdAt: DateTime(2026, 10, 1),
  due: due ?? DateTime(2026, 10, 2),
);

void main() {
  test('right answers space reviews out, a wrong one starts again', () {
    final a = item('a');
    a.review(right: true, now: DateTime(2026, 10, 2, 20));
    expect(a.level, 1);
    expect(a.due, DateTime(2026, 10, 4));
    a.review(right: true, now: DateTime(2026, 10, 4, 9));
    expect(a.due, DateTime(2026, 10, 8));
    a.review(right: false, now: DateTime(2026, 10, 8, 9));
    expect(a.level, 0);
    expect(a.due, DateTime(2026, 10, 9));
    expect(a.reviews, 3);
    for (var i = 0; i < 10; i++) {
      a.review(right: true, now: DateTime(2026, 11, 1));
    }
    expect(a.level, LearningItem.intervals.length - 1);

    final book = LearningBook(items: [a], distilled: {'c1': 6});
    final copy = LearningBook.fromJson(book.toJson());
    expect(copy.items.single.level, a.level);
    expect(copy.items.single.due, a.due);
    expect(copy.distilled, {'c1': 6});
  });

  test('lessons are noted down from the model\'s JSON', () {
    final now = DateTime(2026, 10, 7, 21);
    final noted = LearningService.items(
      '好的：{"items":[{"topic":"移项","point":"移项要变号",'
      '"question":"3 移到右边变成什么？","answer":"−3","mistake":"忘了变号"},'
      '{"topic":"","question":"没有主题的不要"},'
      '{"topic":"只有主题"}]}',
      conversationId: 'c1',
      now: now,
    );
    expect(noted, hasLength(1));
    expect(noted.single.mistake, '忘了变号');
    expect(noted.single.due, DateTime(2026, 10, 8));
    expect(noted.single.conversationId, 'c1');
    expect(
      LearningService.items('{"items":[]}', conversationId: null, now: now),
      isEmpty,
    );
    expect(
      LearningService.items('not json', conversationId: null, now: now),
      isEmpty,
    );

    final prompt = LearningService.distillPrompt([
      ChatMessage(role: 'user', text: '教我解方程', createdAt: now),
      ChatMessage(
        role: 'assistant',
        text: '先看<draw>{"type":"clear"}</draw>这里。<await>出现菜单</await>',
        createdAt: now,
      ),
    ]);
    expect(prompt, contains('Student: 教我解方程'));
    expect(prompt, contains('Teacher: 先看这里。'));
  });

  test('review marks are read but never shown', () {
    const reply =
        '对了！<review id="k1" result="right"/>下一题：'
        '<review id=\'k2\' result="wrong" />再想想。';
    expect(LearningService.results(reply), [
      (id: 'k1', right: true),
      (id: 'k2', right: false),
    ]);
    expect(AnnotationService.strip(reply), '对了！下一题：再想想。');
    expect(AnnotationService.strip('对了！<review id="k1" res'), '对了！');
    expect(AnnotationService.strip('对了！<rev'), '对了！');
    final prompt = LearningService.reviewPrompt([item('k1')]);
    expect(prompt, startsWith('[Review]'));
    expect(prompt, contains('"id":"k1"'));
  });

  testWidgets('a lesson is noted when left, then reviewed when due', (
    tester,
  ) async {
    final ai = ScriptedAi([
      '移项时要变号。你试试：2x + 3 = 7，3 移过去是多少？',
      '对，是 −3！所以 2x = 4。',
      '{"items":[{"topic":"移项","point":"移项要变号",'
          '"question":"3 移到右边变成什么？","answer":"−3"}]}',
    ]);
    final store = MemoryStore();
    final c =
        AppController(
            aiService: ai,
            workspaceStore: store,
            speechService: silentSpeech(),
          )
          ..loading = false
          ..settings = const AppSettings(apiKey: 'k', speakReplies: false);
    await c.sendText('教我解一元一次方程');
    await c.sendText('是 −3');
    expect(c.learning.items, isEmpty);

    // Leaving the conversation notes down what was learned in it.
    c.newConversation();
    await tester.pump();
    expect(c.learning.items, hasLength(1));
    expect(store.book.items.single.topic, '移项');
    expect(c.dueReviews, isEmpty); // first review tomorrow
    // Leaving again finds nothing new to note.
    c.selectConversation(c.conversations.first.id);
    c.newConversation();
    await tester.pump();
    expect(ai.requests, hasLength(3));

    // A day later it is due, and a review is a conversation of its own.
    final noted = c.learning.items.single..due = DateTime(2020);
    expect(c.dueReviews, [noted]);
    ai.replies.add('第一题：3 移到右边变成什么？');
    await c.startReview();
    expect(c.conversations, hasLength(2));
    expect(c.messages.first.note, '开始复习（1 题）');
    expect(c.messages.first.text, contains(noted.id));
    expect(c.current!.title, '开始复习（1 题）');

    ai.replies.add('完全正确！<review id="${noted.id}" result="right"/>今天就到这儿。');
    await c.sendText('−3');
    expect(noted.level, 1);
    expect(noted.reviews, 1);
    expect(c.dueReviews, isEmpty);
    expect(AnnotationService.strip(c.messages.last.text), '完全正确！今天就到这儿。');
    // Reviews are not noted down again.
    c.newConversation();
    await tester.pump();
    expect(ai.requests, hasLength(5));
    c.dispose();
  });

  testWidgets('with the notebook off, nothing is noted or due', (tester) async {
    final ai = ScriptedAi(['一', '二']);
    final c =
        AppController(
            aiService: ai,
            workspaceStore: MemoryStore(),
            speechService: silentSpeech(),
          )
          ..loading = false
          ..settings = const AppSettings(
            apiKey: 'k',
            speakReplies: false,
            learning: false,
          );
    c.learning.items.add(item('old', due: DateTime(2020)));
    await c.sendText('a');
    await c.sendText('b');
    c.newConversation();
    await tester.pump();
    expect(ai.requests, hasLength(2));
    expect(c.dueReviews, isEmpty);
    c.dispose();
  });
}
