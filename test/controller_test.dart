import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramizom_magic_wand/models/learning.dart';
import 'package:ramizom_magic_wand/services/speech_service.dart';
import 'package:ramizom_magic_wand/services/screen_capture_service.dart';
import 'package:ramizom_magic_wand/controllers/app_controller.dart';
import 'package:ramizom_magic_wand/models/app_settings.dart';
import 'package:ramizom_magic_wand/models/chat_message.dart';
import 'package:ramizom_magic_wand/services/ai_service.dart';
import 'package:ramizom_magic_wand/services/workspace_store.dart';
import 'package:ramizom_magic_wand/services/speech_recognition_service.dart';

class FakeRecognition extends SpeechRecognitionService {
  int starts = 0, stops = 0;
  @override
  Future<void> start({Stream<Uint8List>? source}) async {
    starts++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    onEvent = null;
  }
}

class MemoryStore extends WorkspaceStore {
  WorkspaceData value = const WorkspaceData([], []);
  @override
  Future<WorkspaceData> load() async => value;
  @override
  Future<void> save(
    List<Conversation> conversations,
    List<TaskShortcut> shortcuts,
  ) async {
    value = WorkspaceData(
      conversations.map((c) => Conversation.fromJson(c.toJson())).toList(),
      List.of(shortcuts),
    );
  }

  @override
  Future<void> removeAttachments(Iterable<Attachment> attachments) async {}

  LearningBook book = LearningBook();
  @override
  Future<LearningBook> loadLearning() async => book;
  @override
  Future<void> saveLearning(LearningBook value) async {
    book = LearningBook.fromJson(value.toJson());
  }
}

class ControlledAi extends AiService {
  final output = StreamController<String>();
  final started = Completer<void>();
  bool cancelled = false;
  bool? lastVoice;
  bool? lastAnnotate;
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
    lastVoice = voice;
    lastAnnotate = annotate;
    if (!started.isCompleted) started.complete();
    return output.stream;
  }

  @override
  void cancel() {
    cancelled = true;
    unawaited(output.close());
  }
}

void main() {
  testWidgets(
    'a voice turn keeps listening, ignores its own echo and resumes after',
    (tester) async {
      final recognition = FakeRecognition();
      final ai = ControlledAi();
      final c =
          AppController(
              aiService: ai,
              recognitionService: recognition,
              speechService: silentSpeech(),
              workspaceStore: MemoryStore(),
            )
            ..loading = false
            ..settings = const AppSettings(apiKey: 'test', speakReplies: false);
      await c.toggleMicrophone();
      expect(c.listening, isTrue);
      recognition.onEvent!('partial', 'Hello');
      expect(c.liveCaption, 'Hello');
      recognition.onEvent!('final', 'Hello there');
      await tester.pump(const Duration(milliseconds: 1000));
      expect(c.messages.first.text, 'Hello there');
      // Spoken turns ask the model for a short, caption-style reply.
      expect(ai.lastVoice, isTrue);
      expect(c.busy, isTrue);
      // The microphone stays open so the user can talk over the reply.
      expect(c.listening, isTrue);
      ai.output.add('The weather is sunny today.');
      await tester.pump();
      // The reply leaking back into the microphone is not the user.
      recognition.onEvent!('final', 'weather is sunny');
      await tester.pump(const Duration(milliseconds: 1000));
      expect(c.messages.length, 2);
      expect(c.busy, isTrue);
      await ai.output.close();
      await tester.pump();
      expect(c.busy, isFalse);
      expect(c.listening, isTrue);
      expect(recognition.starts, 1);
      await c.toggleMicrophone();
      await tester.pump(const Duration(seconds: 3));
      expect(c.voiceConversation, isFalse);
      expect(c.listening, isFalse);
      c.dispose();
    },
  );

  testWidgets('speaking over a reply interrupts it like a person would', (
    tester,
  ) async {
    final recognition = FakeRecognition();
    final ai = ControlledAi();
    final c =
        AppController(
            aiService: ai,
            recognitionService: recognition,
            speechService: silentSpeech(),
            workspaceStore: MemoryStore(),
          )
          ..loading = false
          ..settings = const AppSettings(apiKey: 'test', speakReplies: false);
    await c.toggleMicrophone();
    recognition.onEvent!('final', 'Tell me a long story');
    await tester.pump(const Duration(milliseconds: 1000));
    ai.output.add('Once upon a time there was a dragon');
    await tester.pump();
    expect(c.busy, isTrue);
    recognition.onEvent!('partial', 'wait, stop please');
    await tester.pump();
    // The reply is cut off and kept as interrupted.
    expect(ai.cancelled, isTrue);
    expect(c.busy, isFalse);
    expect(c.messages.last.state, 'interrupted');
    // What the user is saying becomes the next turn.
    expect(c.liveCaption, 'wait, stop please');
    expect(c.listening, isTrue);
    await c.toggleMicrophone();
    await tester.pump(const Duration(seconds: 3));
    c.dispose();
  });

  test('echo detection tells the reply apart from the user', () {
    final c = AppController(workspaceStore: MemoryStore());
    c.conversations.add(
      Conversation(
        id: 'e',
        title: 'e',
        updatedAt: DateTime(2026),
        messages: [
          ChatMessage(role: 'user', text: 'Q', createdAt: DateTime(2026)),
          ChatMessage(
            role: 'assistant',
            text: '明天北京多云，最高气温二十三度。',
            createdAt: DateTime(2026),
          ),
        ],
      ),
    );
    c.selectedId = 'e';
    expect(c.isUserSpeech('北京多云最高气温'), isFalse);
    expect(c.isUserSpeech('等一下，我想问别的'), isTrue);
    expect(c.isUserSpeech('嗯'), isFalse);
    // Stray words left by echo cancellation do not interrupt.
    expect(c.isUserSpeech('Yeah.'), isFalse);
    expect(c.isUserSpeech('wait, stop please'), isTrue);
    c.dispose();
  });

  testWidgets(
    'speech failure ends session without sending an error as a prompt',
    (tester) async {
      final recognition = FakeRecognition();
      final c = AppController(
        recognitionService: recognition,
        speechService: silentSpeech(),
        workspaceStore: MemoryStore(),
      )..settings = const AppSettings(apiKey: 'test');
      await c.toggleMicrophone();
      recognition.onEvent!('error', 'engine failed');
      await tester.pump(const Duration(seconds: 3));
      expect(c.voiceConversation, isFalse);
      expect(c.conversations, isEmpty);
      expect(c.error, isNotNull);
      c.dispose();
    },
  );
  test(
    'stopping preserves partial response and does not leak into the next conversation',
    () async {
      final ai = ControlledAi();
      final store = MemoryStore();
      final c = AppController(aiService: ai, workspaceStore: store)
        ..loading = false
        ..settings = const AppSettings(apiKey: 'test', speakReplies: false);
      final request = c.sendText('First question');
      await ai.started.future;
      ai.output.add('Partial answer');
      await Future<void>.delayed(Duration.zero);
      expect(c.messages.last.text, 'Partial answer');
      c.stopGeneration();
      expect(ai.cancelled, isTrue);
      expect(c.messages.last.state, 'interrupted');
      c.newConversation();
      await request;
      expect(c.messages, isEmpty);
      expect(c.conversations.single.messages.last.text, 'Partial answer');
      c.dispose();
    },
  );
  test(
    'validation retains attachments and does not create an empty conversation',
    () async {
      final c = AppController(workspaceStore: MemoryStore())..loading = false;
      c.pendingAttachments.add(
        const Attachment(
          name: 'note.txt',
          path: 'unused',
          mime: 'text/plain',
          size: 4,
        ),
      );
      expect(await c.sendText('Hello'), isFalse);
      expect(c.conversations, isEmpty);
      expect(c.pendingAttachments, hasLength(1));
      c.dispose();
    },
  );

  test('long or multi-line prompts become a tidy title', () {
    expect(AppController.titleFrom('  Plan\n\nthe   trip  '), 'Plan the trip');
    final long = '${'a' * 63}😀😀';
    expect(AppController.titleFrom(long), '${'a' * 63}😀…');
  });

  test('provider and network failures read as plain language', () {
    final c = AppController(workspaceStore: MemoryStore())
      ..settings = const AppSettings(language: 'en');
    expect(
      c.describe(const AiServiceException('HTTP 401: Invalid key')),
      'The API key was rejected. Check it in Settings. (HTTP 401 · Invalid key)',
    );
    expect(c.describe(const AiServiceException('HTTP 503')), contains('503'));
    expect(c.describe(TimeoutException('slow')), contains('too long'));
    expect(
      c.describe(const SocketException('offline')),
      contains('Couldn’t reach'),
    );
    expect(c.describe('keyRequired'), 'Add an AI key in Settings first.');
    c.dispose();
  });

  test(
    'an image earlier in the chat does not block a text-only model',
    () async {
      final ai = ControlledAi();
      final c = AppController(aiService: ai, workspaceStore: MemoryStore())
        ..loading = false
        ..settings = const AppSettings(
          apiKey: 'test',
          sendScreen: false,
          speakReplies: false,
        );
      c.conversations.add(
        Conversation(
          id: 'old',
          title: 'Photo',
          updatedAt: DateTime(2026),
          messages: [
            ChatMessage(
              role: 'user',
              text: 'What is this?',
              createdAt: DateTime(2026),
              attachments: const [
                Attachment(
                  name: 'photo.png',
                  path: 'unused',
                  mime: 'image/png',
                  size: 4,
                ),
              ],
            ),
            ChatMessage(
              role: 'assistant',
              text: 'A cat.',
              createdAt: DateTime(2026),
            ),
          ],
        ),
      );
      c.selectedId = 'old';
      final request = c.sendText('Tell me more');
      await ai.started.future;
      expect(c.error, isNull);
      ai.output.add('More.');
      await ai.output.close();
      expect(await request, isTrue);
      expect(c.messages.last.text, 'More.');
      c.dispose();
    },
  );
}

/// A voice that says nothing, instantly: no network, no audio device.
SpeechService silentSpeech() => SpeechService(
  output: _SilentOutput(),
  synthesizer: (text, voice, speed) async => Uint8List(0),
);

class _SilentOutput implements SpeechOutput {
  @override
  Future<void> prepare(int sampleRate) async {}
  @override
  Future<int> play(Int16List samples, int sampleRate) async => 0;
  @override
  Future<void> stop() async {}
  @override
  Future<({int played, int queued})> position() async => (played: 0, queued: 0);
  @override
  Future<SpeechAudio> decode(Uint8List encoded) async =>
      (samples: Int16List(0), rate: 24000);
}
