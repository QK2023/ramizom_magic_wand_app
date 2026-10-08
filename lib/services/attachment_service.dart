import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import '../models/chat_message.dart';
import 'workspace_store.dart';

class AttachmentService {
  static const textExtensions = [
    'txt',
    'md',
    'csv',
    'json',
    'yaml',
    'yml',
    'log',
    'dart',
    'py',
    'js',
    'ts',
    'tsx',
    'jsx',
    'html',
    'css',
    'cpp',
    'c',
    'h',
    'rs',
    'go',
    'java',
    'xml',
    'sql',
  ];
  static const extensions = [
    'png',
    'jpg',
    'jpeg',
    'webp',
    'pdf',
    ...textExtensions,
  ];

  Future<List<Attachment>> pick(
    WorkspaceStore store,
    int existing, {
    String label = 'Files',
  }) async {
    final selected = await openFiles(
      acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)],
    );
    if (selected.length + existing > 4) {
      throw const FormatException('fileLimit');
    }
    final result = <Attachment>[];
    try {
      for (final file in selected) {
        final size = await file.length();
        final ext = file.name.split('.').last.toLowerCase();
        if (!extensions.contains(ext)) {
          throw const FormatException('fileUnsupported');
        }
        final text = textExtensions.contains(ext);
        if (size > (text ? 200 * 1024 : 10 * 1024 * 1024)) {
          throw const FormatException('fileLimit');
        }
        if (text) utf8.decode(await file.readAsBytes());
        final mime = switch (ext) {
          'png' => 'image/png',
          'jpg' || 'jpeg' => 'image/jpeg',
          'webp' => 'image/webp',
          'pdf' => 'application/pdf',
          _ => 'text/plain',
        };
        result.add(await store.importFile(file.path, file.name, mime, size));
      }
      return result;
    } catch (_) {
      await store.removeAttachments(result);
      rethrow;
    }
  }

  /// Builds the request content for [message]. Images or PDFs that are not
  /// allowed (or missing when [requireFiles] is false) become a short note.
  static Future<Object> content(
    ChatMessage message, {
    bool images = true,
    bool pdfs = true,
    bool requireFiles = true,
  }) async {
    if (message.attachments.isEmpty) return message.text;
    final parts = <Map<String, Object>>[
      {'type': 'text', 'text': message.text},
    ];
    for (final attachment in message.attachments) {
      final name = attachment.name.replaceAll('"', "'");
      final file = File(attachment.path);
      final omitted =
          (attachment.isImage && !images) || (attachment.isPdf && !pdfs);
      if (omitted || !await file.exists()) {
        if (!omitted && requireFiles) {
          throw const FormatException('fileMissing');
        }
        parts.add({
          'type': 'text',
          'text': '\n[Earlier attachment not included: $name]',
        });
      } else if (attachment.isImage) {
        parts.add({
          'type': 'image_url',
          'image_url': {
            'url':
                'data:${attachment.mime};base64,${base64Encode(await file.readAsBytes())}',
          },
        });
      } else if (attachment.isPdf) {
        parts.add({
          'type': 'file',
          'file': {
            'filename': name,
            'file_data':
                'data:application/pdf;base64,${base64Encode(await file.readAsBytes())}',
          },
        });
      } else {
        parts.add({
          'type': 'text',
          'text':
              '\n<attached_file name="$name">\n${await file.readAsString()}\n</attached_file>',
        });
      }
    }
    return parts;
  }
}
