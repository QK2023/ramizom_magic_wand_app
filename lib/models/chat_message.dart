class Attachment {
  const Attachment({
    required this.name,
    required this.path,
    required this.mime,
    required this.size,
  });
  final String name;
  final String path;
  final String mime;
  final int size;
  bool get isImage => mime.startsWith('image/');
  bool get isPdf => mime == 'application/pdf';
  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'mime': mime,
    'size': size,
  };
  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
    name: json['name'] as String,
    path: json['path'] as String,
    mime: json['mime'] as String,
    size: json['size'] as int,
  );
}

class ChatMessage {
  ChatMessage({
    required this.role,
    required this.text,
    required this.createdAt,
    this.hadScreen = false,
    this.attachments = const [],
    this.state = 'complete',
    this.model,
    this.note,
  });
  final String role;
  String text;
  final DateTime createdAt;
  final bool hadScreen;
  final List<Attachment> attachments;
  String state;
  final String? model;

  /// Set on turns the app adds itself, such as "step 2 done" during a
  /// walkthrough: shown as this short note, while the model reads [text].
  final String? note;
  Map<String, dynamic> toJson() => {
    'role': role,
    if (model != null) 'model': model,
    if (note != null) 'note': note,
    'text': text,
    'createdAt': createdAt.toIso8601String(),
    'hadScreen': hadScreen,
    'attachments': attachments.map((a) => a.toJson()).toList(),
    'state': state == 'streaming' ? 'interrupted' : state,
  };
  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    role: json['role'] as String,
    model: json['model'] as String?,
    note: json['note'] as String?,
    text: json['text'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    hadScreen: json['hadScreen'] == true,
    state: json['state'] as String? ?? 'complete',
    attachments: (json['attachments'] as List? ?? [])
        .map((a) => Attachment.fromJson(Map<String, dynamic>.from(a as Map)))
        .toList(),
  );
}

class Conversation {
  Conversation({
    required this.id,
    required this.title,
    required this.updatedAt,
    List<ChatMessage>? messages,
    this.pinned = false,
  }) : messages = messages ?? [];
  final String id;
  String title;
  DateTime updatedAt;
  bool pinned;
  final List<ChatMessage> messages;
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'updatedAt': updatedAt.toIso8601String(),
    'pinned': pinned,
    'messages': messages.map((m) => m.toJson()).toList(),
  };
  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String,
    title: json['title'] as String,
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    pinned: json['pinned'] == true,
    messages: (json['messages'] as List)
        .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
        .toList(),
  );
}

class TaskShortcut {
  const TaskShortcut({
    required this.id,
    required this.name,
    required this.prompt,
  });
  final String id;
  final String name;
  final String prompt;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'prompt': prompt};
  factory TaskShortcut.fromJson(Map<String, dynamic> json) => TaskShortcut(
    id: json['id'] as String,
    name: json['name'] as String,
    prompt: json['prompt'] as String,
  );
}
