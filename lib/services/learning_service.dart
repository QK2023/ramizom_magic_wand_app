import 'dart:convert';

import '../models/chat_message.dart';
import '../models/learning.dart';
import 'annotation_service.dart';

/// Turns lessons into a notebook and the notebook into reviews.
///
/// After a conversation in which the user learned something, the model is
/// asked, in the background, for the points worth remembering and the
/// mistakes made. Later, a review quizzes the user on what is due, and the
/// model marks each answer with a hidden `<review id result>` tag that
/// reschedules the item.
class LearningService {
  /// Most review questions asked in one sitting.
  static const reviewSize = 5;

  /// Hidden marks a review reply leaves after judging an answer.
  static final reviewTag = RegExp(
    r'''<review\s+id=["']([^"']+)["']\s+result=["'](right|wrong)["']\s*/?>''',
  );

  /// Whether [conversation] is itself a review, which has nothing new to
  /// note down.
  static bool isReview(Conversation conversation) =>
      conversation.messages.any((m) => m.text.startsWith('[Review]'));

  /// Asks for what is worth remembering from [messages], as JSON.
  static String distillPrompt(List<ChatMessage> messages) {
    final recent = messages.length > 40
        ? messages.sublist(messages.length - 40)
        : messages;
    final transcript = recent
        .map((m) {
          var text = m.note ?? AnnotationService.strip(m.text).trim();
          if (text.length > 1500) text = '${text.substring(0, 1500)}…';
          return '${m.role == 'user' ? 'Student' : 'Teacher'}: $text';
        })
        .join('\n\n');
    return 'Below is a conversation between a student and a teacher. If the '
        'student was learning something (a concept, a method, how to solve '
        'a kind of problem, how to do something), note down what is worth '
        'reviewing later. Answer with JSON only:\n'
        '{"items":[{"topic":"short subject, a few words","point":"the one '
        'thing to remember, one sentence","question":"a question to recall '
        'it by, answerable in a sentence or two","answer":"its answer",'
        '"mistake":"the mistake the student made about it, or empty"}]}\n'
        'At most 5 items, the most useful first, written in the language of '
        'the conversation. Mistakes the student actually made matter most. '
        'If nothing was being learned (small talk, a one-off task), answer '
        '{"items":[]}.\n\n$transcript';
  }

  /// The items in a distilling reply; nothing for anything unreadable.
  static List<LearningItem> items(
    String reply, {
    required String? conversationId,
    required DateTime now,
  }) {
    final json = RegExp(r'\{[\s\S]*\}').firstMatch(reply)?[0];
    if (json == null) return const [];
    Object? value;
    try {
      value = jsonDecode(json);
    } on FormatException {
      return const [];
    }
    final list = value is Map ? value['items'] : null;
    if (list is! List) return const [];
    final day = DateTime(now.year, now.month, now.day);
    final result = <LearningItem>[];
    for (final (index, entry) in list.indexed) {
      if (entry is! Map || result.length >= 5) continue;
      String field(String key) =>
          entry[key] is String ? (entry[key] as String).trim() : '';
      final topic = field('topic'), question = field('question');
      if (topic.isEmpty || question.isEmpty) continue;
      result.add(
        LearningItem(
          id: '${now.microsecondsSinceEpoch.toRadixString(36)}$index',
          topic: topic,
          point: field('point'),
          question: question,
          answer: field('answer'),
          mistake: field('mistake'),
          conversationId: conversationId,
          createdAt: now,
          // First review the next day.
          due: day.add(const Duration(days: 1)),
        ),
      );
    }
    return result;
  }

  /// Starts a review of [due]: the model quizzes the student one item at a
  /// time and marks each answer.
  static String reviewPrompt(List<LearningItem> due) {
    final items = jsonEncode([
      for (final item in due)
        {
          'id': item.id,
          'topic': item.topic,
          'question': item.question,
          'answer': item.answer,
          if (item.mistake.isNotEmpty) 'earlier mistake': item.mistake,
        },
    ]);
    return '[Review] Start a short spaced-repetition review. Quiz the student '
        'on the items below one at a time, like a friendly teacher: ask one '
        'question (in your own words, in the language of the items), wait '
        'for the answer, then say whether it is right with a brief '
        'explanation — and if they made this mistake before, check it '
        'directly. Right after judging an answer, write '
        '<review id="ID" result="right"/> or <review id="ID" '
        'result="wrong"/> (it is never shown), then go on to the next item. '
        'When all are done, sum up in a sentence or two.\nItems: $items';
  }

  /// Each answer judged in a review reply: item id and whether it was right.
  static List<({String id, bool right})> results(String reply) => [
    for (final match in reviewTag.allMatches(reply))
      (id: match[1]!, right: match[2] == 'right'),
  ];
}
