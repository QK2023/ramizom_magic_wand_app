import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramizom_magic_wand/models/chat_message.dart';
import 'package:ramizom_magic_wand/services/workspace_store.dart';
import 'package:ramizom_magic_wand/services/attachment_service.dart';

void main() {
  late Directory temp;
  late WorkspaceStore store;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('magic-wand-test-');
    store = WorkspaceStore(directory: temp);
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  test(
    'history, attachment content and shortcuts survive restart and backup recovery',
    () async {
      final source = File('${temp.path}/source.txt');
      await source.writeAsString('Saved document context');
      final attachment = await store.importFile(
        source.path,
        'notes.txt',
        'text/plain',
        22,
      );
      final c = Conversation(
        id: '1',
        title: 'Research',
        updatedAt: DateTime(2026),
        pinned: true,
        messages: [
          ChatMessage(
            role: 'user',
            text: 'Summarize',
            createdAt: DateTime(2026),
            attachments: [attachment],
          ),
        ],
      );
      await store.save(
        [c],
        [const TaskShortcut(id: 'a', name: 'Review', prompt: 'Review this')],
      );
      final restarted = WorkspaceStore(directory: temp);
      final data = await restarted.load();
      expect(data.conversations.single.pinned, isTrue);
      expect(data.shortcuts.single.prompt, 'Review this');
      final content =
          await AttachmentService.content(
                data.conversations.single.messages.single,
              )
              as List;
      expect(content[1]['text'], contains('Saved document context'));
      await File('${temp.path}/conversations.json').writeAsString('{broken');
      expect((await restarted.load()).conversations.single.title, 'Research');
    },
  );
  test(
    'serialized writes retain newest snapshot and deletion updates backup',
    () async {
      final c = Conversation(
        id: '1',
        title: 'First',
        updatedAt: DateTime(2026),
      );
      final first = store.save([c], []);
      c.title = 'Second';
      final second = store.save([c], []);
      await Future.wait([first, second]);
      expect((await store.load()).conversations.single.title, 'Second');
      await store.save([], []);
      final backup = jsonDecode(
        await File('${temp.path}/conversations.json.bak').readAsString(),
      );
      expect(backup['conversations'], isEmpty);
    },
  );
  test(
    'attachment cleanup cannot delete a source file outside managed attachments',
    () async {
      final source = File('${temp.path}/keep.txt');
      await source.writeAsString('keep');
      await store.removeAttachments([
        Attachment(
          name: 'keep',
          path: source.path,
          mime: 'text/plain',
          size: 4,
        ),
      ]);
      expect(await source.exists(), isTrue);
    },
  );

  test('orphaned attachment copies are pruned on launch', () async {
    final source = File('${temp.path}/source.txt');
    await source.writeAsString('context');
    final kept = await store.importFile(source.path, 'a.txt', 'text/plain', 7);
    final orphan = await store.importFile(
      source.path,
      'b.txt',
      'text/plain',
      7,
    );
    await store.pruneAttachments([kept]);
    expect(await File(kept.path).exists(), isTrue);
    expect(await File(orphan.path).exists(), isFalse);
    expect(await source.exists(), isTrue);
  });
}
