import 'dart:math' as math;

/// One thing the user learned, kept for review: a point to remember, a
/// question to recall it by, and the mistake they made, if any.
class LearningItem {
  LearningItem({
    required this.id,
    required this.topic,
    required this.point,
    required this.question,
    required this.answer,
    this.mistake = '',
    this.conversationId,
    required this.createdAt,
    required this.due,
    this.level = 0,
    this.reviews = 0,
  });

  /// Days until the next review at each level: a right answer moves up a
  /// level, a wrong one starts again from the first.
  static const intervals = [1, 2, 4, 7, 15, 30];

  final String id;
  final String topic;
  final String point;
  final String question;
  final String answer;
  final String mistake;
  final String? conversationId;
  final DateTime createdAt;
  DateTime due;
  int level;
  int reviews;

  bool dueBy(DateTime now) => !due.isAfter(now);

  /// Schedules the next review after an answer at [now].
  void review({required bool right, required DateTime now}) {
    level = right ? math.min(level + 1, intervals.length - 1) : 0;
    reviews++;
    // Due at the start of that day, so a review is never a few hours short.
    final day = DateTime(now.year, now.month, now.day);
    due = day.add(Duration(days: right ? intervals[level] : 1));
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'topic': topic,
    'point': point,
    'question': question,
    'answer': answer,
    if (mistake.isNotEmpty) 'mistake': mistake,
    if (conversationId != null) 'conversationId': conversationId,
    'createdAt': createdAt.toIso8601String(),
    'due': due.toIso8601String(),
    'level': level,
    'reviews': reviews,
  };

  factory LearningItem.fromJson(Map<String, dynamic> json) => LearningItem(
    id: json['id'] as String,
    topic: json['topic'] as String? ?? '',
    point: json['point'] as String? ?? '',
    question: json['question'] as String? ?? '',
    answer: json['answer'] as String? ?? '',
    mistake: json['mistake'] as String? ?? '',
    conversationId: json['conversationId'] as String?,
    createdAt: DateTime.parse(json['createdAt'] as String),
    due: DateTime.parse(json['due'] as String),
    level: json['level'] as int? ?? 0,
    reviews: json['reviews'] as int? ?? 0,
  );
}

/// Everything learned, and how far each conversation has been looked
/// through for it.
class LearningBook {
  LearningBook({List<LearningItem>? items, Map<String, int>? distilled})
    : items = items ?? [],
      distilled = distilled ?? {};

  final List<LearningItem> items;

  /// Conversation id → number of its messages already distilled.
  final Map<String, int> distilled;

  List<LearningItem> dueBy(DateTime now) =>
      items.where((item) => item.dueBy(now)).toList()
        ..sort((a, b) => a.due.compareTo(b.due));

  Map<String, dynamic> toJson() => {
    'version': 1,
    'items': items.map((i) => i.toJson()).toList(),
    'distilled': distilled,
  };

  factory LearningBook.fromJson(Map<String, dynamic> json) => LearningBook(
    items: (json['items'] as List? ?? [])
        .map((v) => LearningItem.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList(),
    distilled: Map<String, int>.from(json['distilled'] as Map? ?? {}),
  );
}
