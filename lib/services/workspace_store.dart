import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/chat_message.dart';
import '../models/learning.dart';

class WorkspaceData {
  const WorkspaceData(this.conversations, this.shortcuts);
  final List<Conversation> conversations;
  final List<TaskShortcut> shortcuts;
}

class WorkspaceStore {
  WorkspaceStore({this.directory});
  final Directory? directory;
  Future<void> _pending = Future.value();
  Future<Directory> root() async =>
      directory ??
      Directory('${(await getApplicationSupportDirectory()).path}/workspace');
  Future<WorkspaceData> load() async {
    final folder = await root();
    final file = File('${folder.path}/conversations.json');
    final backup = File('${file.path}.bak');
    if (!await file.exists() && !await backup.exists()) {
      return const WorkspaceData([], []);
    }
    Object? failure;
    for (final candidate in [file, backup]) {
      if (!await candidate.exists()) continue;
      try {
        final value = jsonDecode(await candidate.readAsString()) as Map;
        return WorkspaceData(
          (value['conversations'] as List)
              .map(
                (v) =>
                    Conversation.fromJson(Map<String, dynamic>.from(v as Map)),
              )
              .toList(),
          (value['shortcuts'] as List? ?? [])
              .map(
                (v) =>
                    TaskShortcut.fromJson(Map<String, dynamic>.from(v as Map)),
              )
              .toList(),
        );
      } catch (error) {
        failure = error;
      }
    }
    throw FormatException('Unable to read workspace: $failure');
  }

  Future<void> save(
    List<Conversation> conversations,
    List<TaskShortcut> shortcuts,
  ) {
    final snapshot = jsonEncode({
      'version': 1,
      'conversations': conversations.map((c) => c.toJson()).toList(),
      'shortcuts': shortcuts.map((s) => s.toJson()).toList(),
    });
    final operation = _pending.then((_) async {
      final folder = await root();
      await folder.create(recursive: true);
      final file = File('${folder.path}/conversations.json');
      final temp = File('${file.path}.tmp');
      final backup = File('${file.path}.bak');
      await temp.writeAsString(snapshot, flush: true);
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
      await file.copy(backup.path);
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }

  /// The learning notebook; empty until something is learned.
  Future<LearningBook> loadLearning() async {
    final folder = await root();
    final file = File('${folder.path}/learning.json');
    for (final candidate in [file, File('${file.path}.bak')]) {
      if (!await candidate.exists()) continue;
      try {
        return LearningBook.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(await candidate.readAsString()) as Map,
          ),
        );
      } catch (_) {
        // Try the backup.
      }
    }
    return LearningBook();
  }

  Future<void> saveLearning(LearningBook book) {
    final snapshot = jsonEncode(book.toJson());
    final operation = _pending.then((_) async {
      final folder = await root();
      await folder.create(recursive: true);
      final file = File('${folder.path}/learning.json');
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(snapshot, flush: true);
      if (await file.exists()) await file.copy('${file.path}.bak');
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }

  Future<Attachment> importFile(
    String source,
    String name,
    String mime,
    int size,
  ) async {
    final folder = Directory('${(await root()).path}/attachments');
    await folder.create(recursive: true);
    final safeName = name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final path =
        '${folder.path}/${DateTime.now().microsecondsSinceEpoch}_$safeName';
    await File(source).copy(path);
    return Attachment(name: name, path: path, mime: mime, size: size);
  }

  /// Deletes managed attachment files no saved message references, such as
  /// files picked for a draft that was never sent before the app closed.
  Future<void> pruneAttachments(Iterable<Attachment> referenced) async {
    final folder = Directory('${(await root()).path}/attachments');
    if (!await folder.exists()) return;
    // Listings and stored paths may use different separators on Windows, so
    // match on the (timestamp-unique) file name within this flat folder.
    String name(String path) => path.split(RegExp(r'[/\\]')).last;
    final keep = referenced.map((a) => name(a.path)).toSet();
    await for (final entity in folder.list()) {
      if (entity is File && !keep.contains(name(entity.path))) {
        try {
          await entity.delete();
        } on FileSystemException {
          // A locked file is retried on the next launch.
        }
      }
    }
  }

  Future<void> removeAttachments(Iterable<Attachment> attachments) async {
    final allowed = Directory(
      '${(await root()).path}/attachments',
    ).absolute.path;
    for (final attachment in attachments) {
      final file = File(attachment.path).absolute;
      if (file.parent.path != allowed) continue;
      if (await file.exists()) await file.delete();
    }
  }
}
