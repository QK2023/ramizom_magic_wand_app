import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/app_settings.dart';
import '../models/model_catalog.dart';
import '../models/chat_message.dart';
import 'annotation_service.dart';
import 'attachment_service.dart';
import 'screen_capture_service.dart';

class AiService {
  /// Most recent history messages sent as context.
  static const contextMessages = 24;

  /// Raw bytes of earlier images/PDFs resent with each request. Older files
  /// are replaced by a short note so long visual conversations stay bounded.
  static const historyFileBudget = 6 * 1024 * 1024;

  /// Sent with every turn the user sees. When they want to learn or
  /// understand something, the assistant teaches like a good tutor in a
  /// live online class: a little at a time, then back to the student, so
  /// nobody faces a wall of text. Everything else is answered normally.
  static const teachingPrompt =
      'When the user wants to understand or learn something (a concept, a '
      'problem, how or why something works, a skill), tutor them like a '
      'good live online-class teacher, not a textbook:\n'
      '- Each reply covers one idea or step with a concrete example, about '
      'what you would say in half a minute. Never unload the whole '
      'explanation at once; it overwhelms.\n'
      '- Then hand it back: a quick check, a small try-it, or a choice of '
      'where to go next, and wait. Vary it, skip it when it would feel '
      'forced, and never announce your method.\n'
      '- Unsure of their level? Ask first. Big topic? A one-line roadmap, '
      'then step by step.\n'
      '- React like a person: praise exactly what was right; for a mistake '
      'keep what was right and give a hint or smaller question, not the '
      'answer; if they are lost, try another angle. Let them do the steps.\n'
      '- A quick fact, or a request for everything at once: just give it.\n'
      'Warm plain words, "we" and "you"; no headings or tables, at most three '
      'short points, one formula at a time. Anything else (writing, code, '
      'translation, chat): answer normally.';

  /// Sent only with turns spoken in a voice conversation, where the reply is
  /// read aloud and shown as captions rather than read as a document.
  static const voicePrompt =
      'Live voice conversation: the reply is spoken and shown as subtitles. '
      'Talk like a person, in the user\'s language, usually one to three '
      'short sentences. Plain spoken sentences only: no Markdown, lists, '
      'code, emoji, links or line breaks; say numbers and symbols as spoken.';

  AiService({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;
  final http.Client Function() _clientFactory;
  http.Client? _active;

  Future<List<AiModel>> models(AppSettings settings) async {
    if (!validBaseUrl(settings.baseUrl)) {
      throw const AiServiceException('invalidUrl');
    }
    final client = _clientFactory();
    try {
      final response = await client
          .get(
            Uri.parse(
              '${settings.baseUrl.replaceAll(RegExp(r"/+$"), "")}/models',
            ),
            headers: {
              'Authorization': 'Bearer ${settings.apiKey.trim()}',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AiServiceException('HTTP ${response.statusCode}');
      }
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map || body['data'] is! List) {
        throw const AiServiceException('modelListFailed');
      }
      return (body['data'] as List)
          .whereType<Map>()
          .where((item) => item['id'] is String)
          .map((item) {
            final architecture = item['architecture'];
            final modalities = architecture is Map
                ? architecture['input_modalities']
                : null;
            return AiModel(
              id: item['id'] as String,
              name: item['name'] is String
                  ? item['name'] as String
                  : item['id'] as String,
              acceptsImages: modalities is List
                  ? modalities.contains('image')
                  : ModelCatalog.find(
                      settings.provider,
                      item['id'] as String,
                    )?.vision,
            );
          })
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } finally {
      client.close();
    }
  }

  /// DeepSeek's thinking switch and effort. Other endpoints get nothing, so
  /// they keep their own defaults.
  static Map<String, Object> thinkingOptions(AppSettings settings) {
    if (settings.provider != AiProvider.deepSeek) return const {};
    return switch (settings.thinking) {
      ThinkingMode.none => {
        'thinking': {'type': 'disabled'},
      },
      final mode => {
        'thinking': {'type': 'enabled'},
        'reasoning_effort': mode.name,
      },
    };
  }

  static bool validBaseUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        (uri.scheme == 'https' ||
            (uri.scheme == 'http' &&
                ['localhost', '127.0.0.1', '::1'].contains(uri.host)));
  }

  Stream<String> stream({
    required AppSettings settings,
    required List<ChatMessage> history,
    required ChatMessage message,
    Uint8List? screenFrame,
    List<ScreenTextLine> screenText = const [],
    bool voice = false,
    bool annotate = false,
    // Requests the user doesn't see (checking a walkthrough step, noting
    // down a lesson) are not what "stop" stops.
    bool background = false,
  }) async* {
    if (settings.apiKey.trim().isEmpty) {
      throw const AiServiceException('keyRequired');
    }
    if (!validBaseUrl(settings.baseUrl)) {
      throw const AiServiceException('invalidUrl');
    }
    final client = _clientFactory();
    if (!background) _active = client;
    try {
      final recent = history
          .where((m) => m.state != 'error' && m.text.isNotEmpty)
          .toList();
      final window = recent.sublist(
        recent.length > contextMessages ? recent.length - contextMessages : 0,
      );
      final resendFiles = filesWithinBudget(window);
      final previous = <Map<String, Object>>[];
      for (var i = 0; i < window.length; i++) {
        // Earlier drawings, step goals and review marks are spent; the
        // words are what matter for context.
        final m = window[i].role == 'assistant'
            ? ChatMessage(
                role: 'assistant',
                text: AnnotationService.strip(window[i].text),
                createdAt: window[i].createdAt,
              )
            : window[i];
        previous.add({
          'role': m.role,
          'content': await AttachmentService.content(
            m,
            images: resendFiles[i] && settings.sendScreen,
            pdfs: resendFiles[i] && settings.acceptsPdf,
            requireFiles: false,
          ),
        });
      }
      final content = await AttachmentService.content(message);
      final parts = content is List
          ? List<Object>.from(content)
          : <Object>[
              {'type': 'text', 'text': content},
            ];
      if (screenFrame != null) {
        parts.add({
          'type': 'image_url',
          'image_url': {
            'url':
                'data:${imageMime(screenFrame)};base64,${base64Encode(screenFrame)}',
          },
        });
        if (annotate && screenText.isNotEmpty) {
          parts.add({'type': 'text', 'text': describeElements(screenText)});
        }
      }
      final request =
          http.Request(
              'POST',
              Uri.parse(
                '${settings.baseUrl.replaceAll(RegExp(r"/+$"), "")}/chat/completions',
              ),
            )
            ..headers.addAll({
              'Authorization': 'Bearer ${settings.apiKey.trim()}',
              'Content-Type': 'application/json',
              'Accept': 'text/event-stream',
              if (settings.isOpenRouter) 'X-Title': 'Ramizom Magic Wand',
            })
            ..body = jsonEncode({
              'model': settings.model.trim(),
              'messages': [
                if (!background)
                  {
                    'role': 'system',
                    'content': [
                      teachingPrompt,
                      if (voice) voicePrompt,
                      if (annotate) AnnotationService.prompt,
                    ].join('\n\n'),
                  },
                ...previous,
                {'role': 'user', 'content': parts},
              ],
              'stream': true,
              ...thinkingOptions(settings),
            });
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 45));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString().timeout(
          const Duration(seconds: 15),
        );
        String detail = '';
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map && decoded['error'] is Map) {
            detail = decoded['error']['message']?.toString() ?? '';
          }
        } catch (_) {}
        throw AiServiceException(
          'HTTP ${response.statusCode}${detail.isEmpty ? "" : ": $detail"}',
        );
      }
      if (response.headers['content-type']?.contains('application/json') ==
          true) {
        final decoded = jsonDecode(await response.stream.bytesToString());
        final text = decoded['choices']?[0]?['message']?['content'];
        if (text is! String || text.isEmpty) {
          throw const AiServiceException('emptyReply');
        }
        yield text;
        return;
      }
      await for (final text in decodeEvents(
        response.stream.timeout(const Duration(seconds: 60)),
      )) {
        yield text;
      }
    } finally {
      client.close();
      if (identical(_active, client)) _active = null;
    }
  }

  /// The screen's elements, numbered for the model to point at by id:
  /// `id kind x1,y1,x2,y2 label`, one per line, kept short.
  static String describeElements(List<ScreenTextLine> elements) {
    final shortcut = RegExp(r'\s*\((Ctrl|Alt|Shift|Win)\+[^)]*\)');
    final listed = [
      for (final (i, e) in elements.indexed)
        () {
          var label = e.text.replaceAll(shortcut, '');
          if (label.length > 60) label = '${label.substring(0, 60)}…';
          return '${i + 1} ${e.kind} ${e.box.join(',')} $label';
        }(),
    ];
    return 'Screen elements (id kind box label):\n${listed.join('\n')}';
  }

  /// Marks which history messages may resend their images/PDFs, newest first,
  /// until [historyFileBudget] is used up.
  static List<bool> filesWithinBudget(List<ChatMessage> messages) {
    final result = List.filled(messages.length, false);
    var remaining = historyFileBudget;
    for (var i = messages.length - 1; i >= 0; i--) {
      final size = messages[i].attachments
          .where((a) => a.isImage || a.isPdf)
          .fold<int>(0, (sum, a) => sum + a.size);
      if (size > remaining) break;
      remaining -= size;
      result[i] = true;
    }
    return result;
  }

  static String imageMime(Uint8List bytes) =>
      bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8
      ? 'image/jpeg'
      : 'image/png';

  static Stream<String> decodeEvents(Stream<List<int>> bytes) async* {
    final data = <String>[];
    await for (final line
        in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (data.isNotEmpty) {
          final payload = data.join('\n');
          data.clear();
          if (payload == '[DONE]') return;
          final delta = _delta(payload);
          if (delta.isNotEmpty) yield delta;
        }
      } else if (line.startsWith('data:')) {
        data.add(line.substring(5).trimLeft());
      }
    }
    if (data.isNotEmpty && data.join('\n') != '[DONE]') {
      final delta = _delta(data.join('\n'));
      if (delta.isNotEmpty) yield delta;
    }
  }

  static String _delta(String payload) {
    final value = jsonDecode(payload);
    if (value is! Map) return '';
    final error = value['error'];
    if (error != null) throw AiServiceException(_errorText(error));
    final choices = value['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) return '';
    final delta = (choices.first as Map)['delta'];
    final content = delta is Map ? delta['content'] : null;
    return content is String ? content : '';
  }

  /// Providers stream errors as `{"message": ..., "code": 429}` objects.
  static String _errorText(Object error) {
    if (error is! Map) return error.toString();
    final message = error['message']?.toString() ?? '';
    final code = error['code'];
    final status = code is int ? code : int.tryParse('$code');
    if (status != null && status >= 400 && status < 600) {
      return 'HTTP $status${message.isEmpty ? '' : ': $message'}';
    }
    return message.isEmpty ? error.toString() : message;
  }

  void cancel() {
    _active?.close();
    _active = null;
  }

  void dispose() => cancel();
}

class AiServiceException implements Exception {
  const AiServiceException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AiModel {
  const AiModel({required this.id, required this.name, this.acceptsImages});
  final String id;
  final String name;
  final bool? acceptsImages;
}
