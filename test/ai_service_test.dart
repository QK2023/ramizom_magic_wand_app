import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ramizom_magic_wand/services/ai_service.dart';
import 'package:ramizom_magic_wand/models/app_settings.dart';
import 'package:ramizom_magic_wand/models/chat_message.dart';

void main() {
  test('model catalog preserves provider IDs and image capability', () async {
    final service = AiService(
      clientFactory: () => MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/models');
        return http.Response(
          jsonEncode({
            'data': [
              {
                'id': 'vendor/text-model',
                'name': 'Text Model',
                'architecture': {
                  'input_modalities': ['text'],
                },
              },
              {
                'id': 'vendor/vision-model',
                'name': 'Vision Model',
                'architecture': {
                  'input_modalities': ['text', 'image'],
                },
              },
            ],
          }),
          200,
        );
      }),
    );
    final result = await service.models(
      const AppSettings(
        provider: AiProvider.custom,
        apiKey: 'test',
        baseUrl: 'https://openrouter.ai/api/v1',
      ),
    );
    expect(result.map((model) => model.id), [
      'vendor/text-model',
      'vendor/vision-model',
    ]);
    expect(result[0].acceptsImages, isFalse);
    expect(result[1].acceptsImages, isTrue);
  });
  test(
    'SSE parser handles fragmented UTF-8, comments, CRLF and DONE',
    () async {
      final source =
          ': heartbeat\r\n\r\ndata: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': '你好'},
              },
            ],
          })}\r\n\r\n'
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': ' world'},
              },
            ],
          })}\n\ndata: [DONE]\n\n';
      final bytes = utf8.encode(source);
      final result = await AiService.decodeEvents(
        Stream.fromIterable(bytes.map((b) => [b])),
      ).join();
      expect(result, '你好 world');
    },
  );
  test('stream request preserves model context and final image', () async {
    late Map body;
    final client = MockClient((request) async {
      body = jsonDecode(request.body) as Map;
      return http.Response(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': 'Answer'},
            },
          ],
        })}\n\ndata: [DONE]\n\n',
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final service = AiService(clientFactory: () => client);
    final result = await service
        .stream(
          settings: const AppSettings(apiKey: 'test-key', language: 'en'),
          history: [
            ChatMessage(
              role: 'assistant',
              text: 'Previous',
              createdAt: DateTime(2026),
            ),
          ],
          screenFrame: Uint8List.fromList([137, 80, 78, 71]),
          message: ChatMessage(
            role: 'user',
            text: 'Explain',
            createdAt: DateTime(2026),
          ),
        )
        .join();
    expect(result, 'Answer');
    expect(body['stream'], isTrue);
    expect(body['messages'], hasLength(3));
    expect(body.containsKey('tools'), isFalse);
    expect(body['messages'][1]['role'], 'assistant');
    expect(body['messages'][1]['content'], 'Previous');
    expect(body['messages'][2]['role'], 'user');
    expect(body['messages'][2]['content'][0]['text'], 'Explain');
    expect(
      body['messages'][2]['content'][1]['image_url']['url'],
      startsWith('data:image/png;base64,'),
    );
    // Typed turns carry only the teaching instruction.
    final system = body['messages'].where((m) => m['role'] == 'system');
    expect(system, hasLength(1));
    expect(system.single['content'], AiService.teachingPrompt);
    expect(system.single['content'], isNot(contains('no Markdown')));
  });
  test(
    'provider HTTP error is visible and never reported as empty success',
    () async {
      final service = AiService(
        clientFactory: () => MockClient(
          (_) async =>
              http.Response('{"error":{"message":"Quota exhausted"}}', 429),
        ),
      );
      expect(
        service
            .stream(
              settings: const AppSettings(apiKey: 'test'),
              history: [],
              message: ChatMessage(
                role: 'user',
                text: 'Hello',
                createdAt: DateTime(2026),
              ),
            )
            .join(),
        throwsA(
          isA<AiServiceException>().having(
            (e) => e.message,
            'message',
            contains('429'),
          ),
        ),
      );
    },
  );
  test('reject credentials in URLs and permit explicit local endpoints', () {
    expect(AiService.validBaseUrl('https://user:key@example.com/v1'), isFalse);
    expect(AiService.validBaseUrl('http://example.com/v1'), isFalse);
    expect(AiService.validBaseUrl('http://localhost:1234/v1'), isTrue);
  });

  test('stream errors carry provider status and message', () async {
    final events = utf8.encode(
      'data: ${jsonEncode({
        'error': {'message': 'Rate limited', 'code': 429},
      })}\n\n',
    );
    expect(
      AiService.decodeEvents(Stream.value(events)).join(),
      throwsA(
        isA<AiServiceException>().having(
          (e) => e.message,
          'message',
          'HTTP 429: Rate limited',
        ),
      ),
    );
  });

  test('screen frames are labelled with their real image type', () {
    expect(
      AiService.imageMime(Uint8List.fromList([0xFF, 0xD8, 0xFF])),
      'image/jpeg',
    );
    expect(
      AiService.imageMime(Uint8List.fromList([137, 80, 78, 71])),
      'image/png',
    );
  });

  test('history resends only the newest files within the budget', () {
    Attachment image(int size) => Attachment(
      name: 'photo.png',
      path: 'unused',
      mime: 'image/png',
      size: size,
    );
    ChatMessage turn(List<Attachment> files) => ChatMessage(
      role: 'user',
      text: 'Look',
      createdAt: DateTime(2026),
      attachments: files,
    );
    const budget = AiService.historyFileBudget;
    final result = AiService.filesWithinBudget([
      turn([image(1024)]),
      turn([image(budget - 1024)]),
      turn([]),
      turn([image(1024)]),
    ]);
    // The oldest file no longer fits, so it and anything earlier are omitted.
    expect(result, [false, true, true, true]);
  });

  test('history files a model cannot read become notes', () async {
    final folder = await Directory.systemTemp.createTemp('magic-wand-ai-');
    addTearDown(() => folder.delete(recursive: true));
    final picture = File('${folder.path}/old.png')
      ..writeAsBytesSync([137, 80, 78, 71]);
    late Map body;
    final service = AiService(
      clientFactory: () => MockClient((request) async {
        body = jsonDecode(request.body) as Map;
        return http.Response(
          '{"choices":[{"message":{"content":"Done"}}]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final result = await service
        .stream(
          settings: const AppSettings(apiKey: 'key', sendScreen: false),
          history: [
            ChatMessage(
              role: 'user',
              text: 'Earlier',
              createdAt: DateTime(2026),
              attachments: [
                Attachment(
                  name: 'old.png',
                  path: picture.path,
                  mime: 'image/png',
                  size: 4,
                ),
                const Attachment(
                  name: 'gone.pdf',
                  path: 'missing.pdf',
                  mime: 'application/pdf',
                  size: 4,
                ),
              ],
            ),
          ],
          message: ChatMessage(
            role: 'user',
            text: 'Now',
            createdAt: DateTime(2026),
          ),
        )
        .join();
    expect(result, 'Done');
    final earlier = body['messages'][1]['content'] as List;
    expect(earlier.every((part) => part['type'] == 'text'), isTrue);
    expect(earlier[1]['text'], contains('old.png'));
    expect(earlier[2]['text'], contains('gone.pdf'));
  });

  test(
    'voice turns ask for short spoken replies; typed turns do not',
    () async {
      final bodies = <Map>[];
      final service = AiService(
        clientFactory: () => MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map);
          return http.Response(
            '{"choices":[{"message":{"content":"OK"}}]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      for (final voice in [true, false]) {
        await service
            .stream(
              settings: const AppSettings(apiKey: 'key'),
              history: [],
              message: ChatMessage(
                role: 'user',
                text: 'Hi',
                createdAt: DateTime(2026),
              ),
              voice: voice,
            )
            .join();
      }
      expect(bodies[0]['messages'][0]['role'], 'system');
      expect(bodies[0]['messages'][0]['content'], contains('no Markdown'));
      expect(bodies[0]['messages'][0]['content'], contains('one idea or step'));
      expect(
        bodies[1]['messages']
            .where((m) => m['role'] == 'system')
            .single['content'],
        AiService.teachingPrompt,
      );
    },
  );
}
