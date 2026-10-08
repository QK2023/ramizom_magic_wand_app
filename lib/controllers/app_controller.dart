import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:window_manager/window_manager.dart';
import '../l10n/app_strings.dart';
import '../models/app_settings.dart';
import '../models/chat_message.dart';
import '../models/voice_stage.dart';
import '../services/ai_service.dart';
import '../services/annotation_service.dart';
import '../services/math_display.dart';
import '../services/speakable_text.dart' show looksChinese;
import '../services/screen_capture_service.dart';
import '../services/settings_store.dart';
import '../services/speech_service.dart';
import '../services/speech_recognition_service.dart';
import '../services/workspace_store.dart';
import '../services/attachment_service.dart';
import '../services/guide_service.dart';
import '../services/learning_service.dart';
import '../models/learning.dart';

class AppController extends ChangeNotifier {
  AppController({
    SettingsStore? settingsStore,
    AiService? aiService,
    this._speechService,
    SpeechRecognitionService? recognitionService,
    ScreenCaptureService? captureService,
    WorkspaceStore? workspaceStore,
  }) : _settingsStore = settingsStore ?? SettingsStore(),
       _aiService = aiService ?? AiService(),
       _recognition = recognitionService ?? SpeechRecognitionService(),
       _captureService = captureService ?? ScreenCaptureService(),
       workspaceStore = workspaceStore ?? WorkspaceStore();
  final SettingsStore _settingsStore;
  final AiService _aiService;
  SpeechService? _speechService;
  SpeechService get speech {
    final service = _speechService ??= SpeechService();
    _audioStateSubscription ??= service.playbackStates.listen((playing) {
      speaking = playing;
      emit();
    });
    return service;
  }

  StreamSubscription<bool>? _audioStateSubscription;
  String? spokenText;
  bool _voiceMissingReported = false;

  /// Marks the assistant has drawn on screen and not yet cleared.
  int annotations = 0;

  /// The step of a walkthrough on the user's own screen that they are doing
  /// now, or null when not guiding.
  GuideStep? guide;

  /// The model is being asked whether the current step is done.
  bool guideChecking = false;

  /// The whiteboard is waiting for the student's handwritten answer.
  bool exercising = false;

  /// What the user has learned, for review.
  LearningBook learning = LearningBook();
  Timer? _learnTimer;
  final Set<String> _distilling = {};

  /// Notes due for review now, when the notebook is on.
  List<LearningItem> get dueReviews =>
      settings.learning ? learning.dueBy(DateTime.now()) : const [];
  Timer? _guideTimer;
  bool _guideLooking = false, _guideAdvance = false;
  // The screen (as a tiny fingerprint) when the step was given, and a
  // changed screen waiting to stay the same for one more look before it is
  // judged.
  Uint8List? _guideBaseline, _guideSettling;
  // The screen's fingerprint when the last request was sent.
  Uint8List? _requestPrint;
  // A spoken turn is being answered; the microphone stays open so the user
  // can talk over the reply, as in a real conversation.
  bool _awaitingReply = false;
  int _voiceTurn = 0;
  final SpeechRecognitionService _recognition;
  final ScreenCaptureService _captureService;
  final WorkspaceStore workspaceStore;
  AppSettings settings = const AppSettings();
  AppStrings get strings => AppStrings(settings.language);
  String t(String key) => strings.t(key);
  final List<Conversation> conversations = [];
  final List<TaskShortcut> shortcuts = [];
  final List<Attachment> pendingAttachments = [];
  String? selectedId;
  List<ChatMessage> get messages => current?.messages ?? [];
  Conversation? get current {
    for (final conversation in conversations) {
      if (conversation.id == selectedId) return conversation;
    }
    return null;
  }

  List<Conversation> get sortedConversations =>
      [...conversations]..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });
  Uint8List? latestFrame;
  bool loading = true,
      sharingScreen = false,
      busy = false,
      voiceConversation = false,
      listening = false,
      speaking = false,
      compact = false,
      subtitles = true,
      captureInProgress = false,
      attaching = false,
      hearing = false;
  bool _disposed = false, _micBusy = false, _storageHealthy = true;
  String liveCaption = '';
  String? error;
  int errorSerial = 0, _request = 0, _captureGeneration = 0;
  Timer? _captureTimer;
  Timer? _silenceTimer;
  int _voiceGeneration = 0;
  String _voiceFinal = '', _voicePartial = '';
  Future<void>? _captureJob;
  Rect? _normalBounds, _miniBounds;
  bool _switchingWindow = false, _wasMaximized = false;
  void emit() {
    if (!_disposed) notifyListeners();
  }

  void report(Object exception) {
    error = describe(exception);
    errorSerial++;
    emit();
  }

  /// A speech API failure, told apart from the chat model's own errors.
  String describeSpeech(Object exception) =>
      '${t('speechError')}: ${describe(exception)}';

  /// Turns service failures into a readable, localized notice.
  String describe(Object exception) {
    if (exception is TimeoutException) return t('timeoutError');
    if (exception is SocketException ||
        exception is HandshakeException ||
        exception is http.ClientException) {
      return t('networkError');
    }
    final key = exception is FormatException
        ? exception.message
        : exception.toString();
    final status = RegExp(
      r'^HTTP (\d{3})(?:: (.*))?$',
      dotAll: true,
    ).firstMatch(key);
    if (status == null) return t(key);
    final code = int.parse(status[1]!);
    final summary = t(switch (code) {
      401 || 403 => 'authError',
      402 => 'quotaError',
      404 => 'notFoundError',
      429 => 'rateLimited',
      >= 500 => 'serverError',
      _ => 'requestFailed',
    });
    final detail = status[2]?.trim() ?? '';
    return detail.isEmpty
        ? '$summary (HTTP $code)'
        : '$summary (HTTP $code · $detail)';
  }

  Future<void> initialize() async {
    try {
      AnnotationService.onSubmitted((board) => unawaited(submitAnswer(board)));
    } catch (_) {
      // No platform channels (tests).
    }
    try {
      settings = await _settingsStore.load();
    } catch (e) {
      report(e);
    }
    try {
      final data = await workspaceStore.load();
      conversations.addAll(data.conversations);
      try {
        learning = await workspaceStore.loadLearning();
      } catch (_) {
        // An unreadable notebook starts afresh; conversations are intact.
      }
      shortcuts.addAll(data.shortcuts);
      unawaited(
        workspaceStore
            .pruneAttachments(
              conversations
                  .expand((c) => c.messages)
                  .expand((m) => m.attachments),
            )
            .catchError((Object _) {}),
      );
    } catch (_) {
      _storageHealthy = false;
      report('storageError');
    }
    loading = false;
    emit();
  }

  Future<bool> persist() async {
    if (!_storageHealthy) return false;
    try {
      await workspaceStore.save(conversations, shortcuts);
      return true;
    } catch (_) {
      report('storageError');
      return false;
    }
  }

  Future<void> updateSettings(AppSettings value) async {
    await _settingsStore.save(value);
    settings = value;
    // A text-only model cannot use the shared screen, so stop capturing it.
    if (sharingScreen && !value.sendScreen) {
      await toggleScreenSharing();
    }
    emit();
  }

  Future<List<AiModel>> availableModels() => _aiService.models(settings);

  Future<void> selectModel(AiModel model) => updateSettings(
    settings.copyWith(
      model: model.id,
      sendScreen: model.acceptsImages ?? settings.sendScreen,
    ),
  );

  void newConversation() {
    if (busy || _micBusy) return;
    if (voiceConversation) {
      voiceConversation = false;
      _voiceGeneration++;
      unawaited(_pauseListening());
      unawaited(stopAudio());
    }
    if (guide != null) endGuide();
    _learnTimer?.cancel();
    final leaving = current;
    if (leaving != null) unawaited(_distill(leaving));
    selectedId = null;
    liveCaption = '';
    error = null;
    final discard = List<Attachment>.of(pendingAttachments);
    pendingAttachments.clear();
    unawaited(workspaceStore.removeAttachments(discard));
    emit();
  }

  void selectConversation(String id) {
    if (busy || _micBusy) return;
    newConversation();
    selectedId = id;
    emit();
  }

  Future<void> renameConversation(Conversation c, String title) async {
    if (title.trim().isEmpty) return;
    c.title = title.trim();
    emit();
    await persist();
  }

  Future<void> pinConversation(Conversation c) async {
    c.pinned = !c.pinned;
    emit();
    await persist();
  }

  Future<void> deleteConversation(Conversation c) async {
    if (busy || _micBusy) return;
    conversations.remove(c);
    if (selectedId == c.id) selectedId = null;
    emit();
    final saved = await persist();
    if (saved) {
      await workspaceStore.removeAttachments(
        c.messages.expand((m) => m.attachments),
      );
    }
  }

  Future<void> saveShortcut(TaskShortcut shortcut) async {
    shortcuts.removeWhere((s) => s.id == shortcut.id);
    shortcuts.add(shortcut);
    emit();
    await persist();
  }

  Future<void> removeShortcut(TaskShortcut shortcut) async {
    shortcuts.remove(shortcut);
    emit();
    await persist();
  }

  Future<void> attachFiles() async {
    if (attaching || busy) return;
    attaching = true;
    emit();
    try {
      pendingAttachments.addAll(
        await AttachmentService().pick(
          workspaceStore,
          pendingAttachments.length,
          label: t('fileTypes'),
        ),
      );
    } catch (e) {
      report(e);
    }
    attaching = false;
    emit();
  }

  Future<void> removeAttachment(Attachment attachment) async {
    pendingAttachments.remove(attachment);
    emit();
    await workspaceStore.removeAttachments([attachment]);
  }

  Future<void> toggleScreenSharing() async {
    sharingScreen = !sharingScreen;
    _captureGeneration++;
    unawaited(_captureService.setGlow(sharingScreen));
    // Marks point at what was on the shared screen; they go with it, and so
    // does a walkthrough.
    if (!sharingScreen) {
      exercising = false;
      unawaited(clearAnnotations());
      if (guide != null) endGuide();
    }
    if (sharingScreen) {
      emit();
      await captureNow();
      if (sharingScreen) _startCaptureTimer();
    } else {
      _captureTimer?.cancel();
      latestFrame = null;
      emit();
    }
  }

  void _startCaptureTimer() {
    _captureTimer?.cancel();
    // The preview is a thumbnail, and a fresh frame is taken before every
    // message, so it need not be refreshed often; each capture costs CPU.
    _captureTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => captureNow(),
    );
  }

  Future<void> captureNow() async {
    if (!sharingScreen) return;
    if (_captureJob != null) {
      await _captureJob;
      return;
    }
    final generation = _captureGeneration;
    captureInProgress = true;
    _captureJob = () async {
      try {
        final frame = await _captureService.capture();
        if (frame == null || frame.isEmpty) throw StateError('screenFailed');
        if (sharingScreen && generation == _captureGeneration) {
          latestFrame = frame;
        }
      } catch (_) {
        if (generation == _captureGeneration) {
          sharingScreen = false;
          latestFrame = null;
          _captureTimer?.cancel();
          unawaited(_captureService.setGlow(false));
          report('screenFailed');
        }
      } finally {
        captureInProgress = false;
        emit();
      }
    }();
    await _captureJob;
    _captureJob = null;
  }

  /// Sends a turn. [voice] marks a spoken turn: the model is asked for a
  /// short, conversational reply suited to speech and captions.
  Future<bool> sendText(
    String rawText, {
    bool retry = false,
    bool voice = false,
    String? note,
    Uint8List? image,
  }) async {
    if (busy || attaching || _micBusy) return false;
    final prompt = rawText.trim();
    if (!retry && prompt.isEmpty && pendingAttachments.isEmpty) return false;
    if (listening && !voice) {
      voiceConversation = false;
      _voiceGeneration++;
      await _pauseListening();
    }
    if (settings.apiKey.isEmpty) {
      report('keyRequired');
      return false;
    }
    if (!AiService.validBaseUrl(settings.baseUrl)) {
      report('invalidUrl');
      return false;
    }
    ChatMessage? retryUser;
    if (retry) {
      var index = messages.length - 1;
      if (index >= 0 && messages[index].role == 'assistant') index--;
      if (index < 0 || messages[index].role != 'user') return false;
      retryUser = messages[index];
    }
    // History files a model cannot read are left out of the request, so only
    // this turn's files decide whether it can be sent.
    final outgoing = retryUser?.attachments ?? pendingAttachments;
    if (!settings.sendScreen &&
        (sharingScreen || outgoing.any((a) => a.isImage))) {
      report('visionRequired');
      return false;
    }
    if (!settings.acceptsPdf && outgoing.any((a) => a.isPdf)) {
      report('pdfRequired');
      return false;
    }
    final ChatMessage user;
    if (retryUser != null) {
      if (messages.last.role == 'assistant') messages.removeLast();
      user = retryUser;
    } else {
      if (current == null) {
        final now = DateTime.now();
        final conversation = Conversation(
          id: now.microsecondsSinceEpoch.toString(),
          title: titleFrom(
            note ?? (prompt.isEmpty ? pendingAttachments.first.name : prompt),
          ),
          updatedAt: now,
        );
        conversations.add(conversation);
        selectedId = conversation.id;
      }
      user = ChatMessage(
        role: 'user',
        text: prompt.isEmpty ? t('summarizePrompt') : prompt,
        createdAt: DateTime.now(),
        hadScreen: sharingScreen,
        attachments: List.of(pendingAttachments),
        note: note,
      );
      messages.add(user);
      pendingAttachments.clear();
    }
    final target = current!;
    final history = target.messages.take(target.messages.length - 1).toList();
    final answer = ChatMessage(
      role: 'assistant',
      model: settings.model,
      text: '',
      createdAt: DateTime.now(),
      state: 'streaming',
    );
    target.messages.add(answer);
    busy = true;
    error = null;
    liveCaption = t('thinking');
    final token = ++_request;
    emit();
    SpeechUtterance? utterance;
    // The assistant may draw on a shared screen it can see.
    final annotate =
        sharingScreen && settings.sendScreen && settings.annotations;
    // The screen elements listed with this request, which drawings may
    // point at by id.
    var elements = const <ScreenTextLine>[];
    var drewThisReply = false;
    var drawCursor = 0;
    var drawing = Future<void>.value();
    void perform(String json) {
      if (!annotate || token != _request) return;
      final command = AnnotationService.parse(json, elements: elements);
      if (command == null) return;
      // A new explanation starts on a clean screen.
      if (!drewThisReply) {
        drewThisReply = true;
        if (command['type'] != 'clear') {
          unawaited(AnnotationService.clear());
          annotations = 0;
        }
      }
      if (command['type'] == 'exercise') {
        // The board's buttons, in the user's language.
        command['text'] = '${t('submitAnswer')}\n${t('clearInk')}';
        exercising = true;
      }
      if (command['type'] == 'clear') {
        unawaited(AnnotationService.clear());
        annotations = 0;
        exercising = false;
      } else {
        unawaited(AnnotationService.draw(command));
        if (command['type'] != 'close_whiteboard') annotations++;
      }
      emit();
    }

    try {
      if (_speechService != null) await speech.stopPlayback();
      // Voice turns are always spoken; typed turns when the user asks for it.
      if (voice || settings.speakReplies) {
        speech.warmUp();
        utterance = _beginSpeech(
          onCaption: (spoken) {
            if (spoken.isEmpty || token != _request) return;
            liveCaption = spoken;
            emit();
          },
          onCue: perform,
        );
      }
      if (sharingScreen) await captureNow();
      if (token != _request) return true;
      await persist();
      if (token != _request || _disposed) return true;
      // An answer handed in on the whiteboard is looked at instead of the
      // screen.
      var frame =
          image ?? (sharingScreen && settings.sendScreen ? latestFrame : null);
      if (image != null) {
        _captureService.lastText = const [];
      } else if (frame != null && annotate) {
        // The model aims its marks against a faint coordinate grid.
        _captureService.lastText = const [];
        try {
          frame = await _captureService.capture(grid: true) ?? frame;
        } catch (_) {}
        // The screen as the step will be given, for a walkthrough to notice
        // the user's changes; taken alongside the request, never holding
        // it up.
        _requestPrint = null;
        unawaited(
          _captureService.fingerprint().then(
            (print) => _requestPrint = print,
            onError: (Object _) => null,
          ),
        );
        elements = _captureService.lastElements;
        if (token != _request || _disposed) return true;
      }
      await for (final delta in _aiService.stream(
        settings: settings,
        history: history,
        message: user,
        screenFrame: frame,
        screenText: annotate ? elements : const [],
        voice: voice,
        annotate: annotate,
      )) {
        if (_disposed || token != _request) return true;
        answer.text += delta;
        // Without a voice the caption shows the reply as it arrives; with
        // one, it follows what has actually been said.
        if (utterance == null) {
          liveCaption = displayText(answer.text);
          // Without a voice, drawings keep the pace of someone reading the
          // reply aloud instead of appearing as fast as the text arrives.
          for (final match in AnnotationService.tag.allMatches(
            answer.text,
            drawCursor,
          )) {
            final before = AnnotationService.strip(
              answer.text.substring(drawCursor, match.start),
            );
            drawCursor = match.end;
            final perCharacter = looksChinese(answer.text) ? 180 : 60;
            final pause = Duration(
              milliseconds: (before.characters.length * perCharacter).clamp(
                350,
                4000,
              ),
            );
            final command = match[1]!;
            drawing = drawing.then((_) async {
              await Future<void>.delayed(pause);
              perform(command);
            });
          }
        }
        // Speech starts with the first sentence, not after the whole reply.
        utterance?.add(delta);
        emit();
      }
      if (token != _request) return true;
      if (answer.text.isEmpty) throw const AiServiceException('emptyReply');
      answer.state = 'complete';
      spokenText = answer.text;
      utterance?.close();
      _recordReview(answer.text);
      _learnTimer?.cancel();
      _learnTimer = Timer(const Duration(minutes: 3), () {
        final conversation = current;
        if (conversation != null && !busy) unawaited(_distill(conversation));
      });
      // A reply that ends with a step goal hands the screen to the user.
      final goal = annotate ? AnnotationService.awaitGoal(answer.text) : null;
      if (goal != null) {
        _beginStep(goal);
      } else if (guide != null) {
        endGuide();
      }
    } catch (e) {
      if (utterance != null) {
        unawaited(_speechService?.stopPlayback());
        liveCaption = displayText(answer.text);
      }
      if (token != _request || _disposed) return true;
      answer.state = 'error';
      report(e);
    } finally {
      if (token == _request && !_disposed) {
        busy = false;
        target.updatedAt = DateTime.now();
        emit();
        await persist();
      }
    }
    if (utterance != null && token == _request && answer.state == 'complete') {
      try {
        await utterance.done;
      } catch (e) {
        if (token == _request) {
          liveCaption = displayText(answer.text);
        }
        _reportSpeech(e);
      }
    }
    return true;
  }

  /// Watches the user do [goal] on screen.
  void _beginStep(String goal) {
    final previous = guide;
    guide = GuideStep(
      previous == null ? 1 : previous.number + (_guideAdvance ? 1 : 0),
      goal,
    );
    _guideAdvance = false;
    _guideBaseline = _requestPrint;
    _guideSettling = null;
    _guideTimer ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => _lookAtStep(),
    );
    emit();
  }

  /// Stops guiding; the conversation goes on as usual.
  void endGuide() {
    _guideTimer?.cancel();
    _guideTimer = null;
    guide = null;
    guideChecking = false;
    _guideAdvance = false;
    _guideBaseline = _guideSettling = null;
    emit();
  }

  /// One look at the screen: once it has changed and settled, the model is
  /// asked whether the step is done.
  Future<void> _lookAtStep() async {
    final step = guide;
    if (step == null) return;
    if (!sharingScreen) {
      endGuide();
      return;
    }
    if (busy || guideChecking || _guideLooking || _disposed) return;
    _guideLooking = true;
    try {
      // A few milliseconds per look: a full capture only once the screen
      // has really changed.
      final now = await _captureService.fingerprint();
      if (now == null || !identical(step, guide) || busy) return;
      final baseline = _guideBaseline ??= now;
      if (ScreenCaptureService.difference(baseline, now) <
          GuideService.changed) {
        _guideSettling = null;
        return;
      }
      // Judge a screen that has stopped changing, not one mid-typing.
      final settling = _guideSettling;
      if (settling == null ||
          ScreenCaptureService.difference(settling, now) >=
              GuideService.settled) {
        _guideSettling = now;
        return;
      }
      final frame = await _captureService.capture();
      if (frame == null || !identical(step, guide) || busy) return;
      await _checkStep(step, frame, now);
    } catch (_) {
      // A missed look is followed by the next one.
    } finally {
      _guideLooking = false;
    }
  }

  Future<void> _checkStep(
    GuideStep step,
    Uint8List frame,
    Uint8List now,
  ) async {
    guideChecking = true;
    emit();
    var status = GuideStatus.waiting;
    var reason = '';
    try {
      final instruction = messages.lastWhere(
        (m) => m.role == 'assistant',
        orElse: () =>
            ChatMessage(role: 'assistant', text: '', createdAt: DateTime.now()),
      );
      final reply = StringBuffer();
      await for (final delta in _aiService.stream(
        // A quick yes-or-no look: no deliberation needed.
        settings: settings.copyWith(thinking: ThinkingMode.none),
        background: true,
        history: const [],
        message: ChatMessage(
          role: 'user',
          text: GuideService.checkPrompt(
            step: step,
            instruction: AnnotationService.strip(instruction.text).trim(),
          ),
          createdAt: DateTime.now(),
        ),
        screenFrame: frame,
      )) {
        reply.write(delta);
      }
      final verdict = GuideService.verdict(reply.toString());
      status = verdict.status;
      reason = verdict.reason;
    } catch (_) {
      // Treated as not done yet; the next change is looked at again.
    } finally {
      guideChecking = false;
      emit();
    }
    if (!identical(step, guide) || busy || _disposed) return;
    _guideBaseline = now;
    _guideSettling = null;
    switch (status) {
      case GuideStatus.waiting:
        break;
      case GuideStatus.done:
        _guideAdvance = true;
        await sendText(
          GuideService.doneNote(step),
          voice: voiceConversation,
          note: t('guideDone').replaceAll('{n}', '${step.number}'),
        );
      case GuideStatus.wrong:
        await sendText(
          GuideService.wrongNote(step, reason),
          voice: voiceConversation,
          note: t('guideWrong').replaceAll('{n}', '${step.number}'),
        );
    }
  }

  /// The student handed in their answer on the whiteboard: the assistant
  /// looks at the board and marks it.
  Future<void> submitAnswer(Uint8List board) async {
    if (!exercising) return;
    exercising = false;
    if (busy) await _whenIdle();
    await sendText(
      '[Answer] The student has handed in their answer, written by hand on '
      'the whiteboard. The attached image is the whiteboard canvas, in the '
      'same 0–1000 board coordinates as your drawings on it. Read their '
      'working, mark it on the board and tell them how they did.',
      voice: voiceConversation,
      note: t('answerSubmitted'),
      image: board,
    );
  }

  Future<void> _whenIdle() async {
    for (var i = 0; i < 200 && busy && !_disposed; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Notes down, in the background, what was learned in [conversation]
  /// since it was last looked at.
  Future<void> _distill(Conversation conversation) async {
    if (!settings.learning ||
        settings.apiKey.isEmpty ||
        _distilling.contains(conversation.id) ||
        LearningService.isReview(conversation)) {
      return;
    }
    final count = conversation.messages.length;
    final done = learning.distilled[conversation.id] ?? 0;
    if (count < 4 || count - done < 2) return;
    _distilling.add(conversation.id);
    try {
      final reply = StringBuffer();
      await for (final delta in _aiService.stream(
        settings: settings.copyWith(thinking: ThinkingMode.none),
        history: const [],
        message: ChatMessage(
          role: 'user',
          text: LearningService.distillPrompt(conversation.messages),
          createdAt: DateTime.now(),
        ),
        background: true,
      )) {
        reply.write(delta);
      }
      if (_disposed) return;
      final noted = LearningService.items(
        reply.toString(),
        conversationId: conversation.id,
        now: DateTime.now(),
      );
      for (final item in noted) {
        final known = learning.items.any(
          (e) => e.topic == item.topic && e.question == item.question,
        );
        if (!known) learning.items.add(item);
      }
      learning.distilled[conversation.id] = count;
      await _saveLearning();
      emit();
    } catch (_) {
      // Tried again the next time the conversation is left.
    } finally {
      _distilling.remove(conversation.id);
    }
  }

  /// Reschedules the notes a review reply has marked.
  void _recordReview(String reply) {
    final results = LearningService.results(reply);
    if (results.isEmpty) return;
    final now = DateTime.now();
    for (final result in results) {
      for (final item in learning.items) {
        if (item.id == result.id) item.review(right: result.right, now: now);
      }
    }
    unawaited(_saveLearning());
  }

  Future<void> _saveLearning() async {
    try {
      await workspaceStore.saveLearning(learning);
    } catch (_) {
      // Kept in memory; saved with the next change.
    }
  }

  /// A short quiz on what is due, in a conversation of its own.
  Future<void> startReview() async {
    final due = dueReviews.take(LearningService.reviewSize).toList();
    if (due.isEmpty || busy) return;
    newConversation();
    await sendText(
      LearningService.reviewPrompt(due),
      voice: voiceConversation,
      note: t('reviewStarted').replaceAll('{n}', '${due.length}'),
    );
  }

  Future<void> deleteLearningItem(LearningItem item) async {
    learning.items.remove(item);
    emit();
    await _saveLearning();
  }

  /// The user says the current step is done.
  Future<void> guideFinished() async {
    final step = guide;
    if (step == null || busy) return;
    _guideAdvance = true;
    await sendText(
      GuideService.saidDoneNote(step),
      voice: voiceConversation,
      note: t('guideSaidDone').replaceAll('{n}', '${step.number}'),
    );
  }

  /// The user would rather skip the current step.
  Future<void> guideSkip() async {
    final step = guide;
    if (step == null || busy) return;
    _guideAdvance = true;
    await sendText(
      GuideService.skipNote(step),
      voice: voiceConversation,
      note: t('guideSkipped').replaceAll('{n}', '${step.number}'),
    );
  }

  /// Starts speech for a reply, or explains once why it can't: without a
  /// speech API, replies still appear as captions.
  SpeechUtterance? _beginSpeech({
    void Function(String spoken)? onCaption,
    void Function(String cue)? onCue,
  }) {
    final config = SpeechConfig.of(settings);
    if (!config.ready) {
      if (!_voiceMissingReported) report('ttsMissing');
      _voiceMissingReported = true;
      return null;
    }
    return speech.begin(
      config: config,
      speed: settings.speechRate,
      onCaption: onCaption,
      onCue: onCue,
    );
  }

  /// Removes everything the assistant drew on screen.
  Future<void> clearAnnotations() async {
    annotations = 0;
    emit();
    await AnnotationService.clear(board: true);
  }

  /// One line of at most 64 characters, never splitting an emoji.
  static String titleFrom(String text) {
    final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final characters = line.characters;
    return characters.length > 64 ? '${characters.take(64)}…' : line;
  }

  void stopGeneration() {
    if (!busy) return;
    voiceConversation = false;
    _voiceGeneration++;
    _awaitingReply = false;
    _voiceTurn++;
    if (listening) unawaited(_pauseListening());
    _micBusy = false;
    _request++;
    _aiService.cancel();
    if (_speechService != null) unawaited(speech.stopPlayback());
    busy = false;
    if (messages.isNotEmpty && messages.last.state == 'streaming') {
      messages.last.state = 'interrupted';
    }
    liveCaption = t('interrupted');
    emit();
    unawaited(persist());
  }

  Future<void> retryLast() async {
    await sendText('', retry: true);
  }

  Future<void> readAloud(String text) async {
    final config = SpeechConfig.of(settings);
    if (!config.ready) {
      report('ttsMissing');
      return;
    }
    try {
      spokenText = text;
      await speech.speak(text, config: config, speed: settings.speechRate);
    } catch (e) {
      _reportSpeech(e);
    }
  }

  /// Plays a short sample with a speech API that is still being set up, so
  /// it can be checked by ear. Returns the problem to show, or null.
  Future<String?> previewVoice(SpeechConfig config, double speed) async {
    try {
      spokenText = null;
      await speech.speak(t('voiceSample'), config: config, speed: speed);
      return null;
    } catch (e) {
      return describeSpeech(e);
    }
  }

  void _reportSpeech(Object exception) {
    error = describeSpeech(exception);
    errorSerial++;
    emit();
  }

  Future<void> stopAudio() async {
    if (_speechService != null) await speech.stopPlayback();
  }

  Future<void> toggleMicrophone() async {
    if (voiceConversation) {
      voiceConversation = false;
      _voiceGeneration++;
      _awaitingReply = false;
      _voiceTurn++;
      await _pauseListening();
      await stopAudio();
      emit();
      return;
    }
    if (busy || _micBusy) return;
    if (settings.apiKey.isEmpty) {
      report('keyRequired');
      return;
    }
    voiceConversation = true;
    _voiceGeneration++;
    // Connect to the voice service while the user is still talking.
    speech.warmUp();
    await _listen();
  }

  Future<void> _listen() async {
    if (!voiceConversation || _disposed || busy) return;
    final generation = _voiceGeneration;
    _micBusy = true;
    _voiceFinal = _voicePartial = '';
    _recognition.onEvent = (type, text) {
      if (!listening || generation != _voiceGeneration) return;
      if (type == 'error') {
        _silenceTimer?.cancel();
        voiceConversation = false;
        _awaitingReply = false;
        unawaited(_pauseListening());
        report(text.isEmpty ? 'speechUnavailable' : text);
        return;
      }
      if (_awaitingReply) {
        // While the assistant answers, only the user's own words count: the
        // reply leaking back through the microphone is ignored, and real
        // speech cuts the reply off like a person interrupting.
        final words = type == 'partial' || type == 'final';
        if (!words || !isUserSpeech(text)) return;
        _bargeIn();
      }
      _silenceTimer?.cancel();
      if (type == 'sound') hearing = true;
      if (type == 'silence') hearing = false;
      if (type == 'partial') {
        _voicePartial = text;
        hearing = true;
      }
      if (type == 'final') {
        _voiceFinal = '$_voiceFinal $text'.trim();
        _voicePartial = '';
      }
      liveCaption = '$_voiceFinal $_voicePartial'.trim();
      if (liveCaption.isEmpty) liveCaption = t('listening');
      if ((type == 'final' || type == 'silence') &&
          '$_voiceFinal $_voicePartial'.trim().isNotEmpty) {
        // VAD already waited ~0.45 s of silence to close the phrase; a
        // short extra pause lets the user continue the same turn.
        _silenceTimer = Timer(const Duration(milliseconds: 900), () {
          unawaited(_submitVoice(generation));
        });
      }
      emit();
    };
    try {
      if (_speechService != null) await speech.stopPlayback();
      listening = true;
      liveCaption = t('listening');
      emit();
      await _recognition.start();
      if (generation != _voiceGeneration || !voiceConversation) {
        await _pauseListening();
      }
    } catch (e) {
      voiceConversation = false;
      await _pauseListening();
      if (!_disposed) report(e);
    } finally {
      _micBusy = false;
      emit();
    }
  }

  Future<void> _pauseListening() async {
    listening = false;
    hearing = false;
    _silenceTimer?.cancel();
    await _recognition.stop();
    emit();
  }

  Future<void> _submitVoice(int generation) async {
    if (!listening || generation != _voiceGeneration || _awaitingReply) return;
    final text = '$_voiceFinal $_voicePartial'.trim();
    _voiceFinal = _voicePartial = '';
    if (text.isEmpty || !voiceConversation || _disposed) return;
    hearing = false;
    _awaitingReply = true;
    final turn = ++_voiceTurn;
    final sent = await sendText(text, voice: true);
    // A newer turn means the user spoke over this reply; keep listening.
    if (turn != _voiceTurn) return;
    _awaitingReply = false;
    if (!sent || messages.lastOrNull?.state == 'error') {
      voiceConversation = false;
      await _pauseListening();
      emit();
    }
  }

  /// The user talked over the reply: stop speaking and thinking at once and
  /// let what they are saying become the next turn.
  void _bargeIn() {
    _awaitingReply = false;
    _voiceTurn++;
    if (_speechService != null) unawaited(speech.stopPlayback());
    speaking = false;
    if (busy) {
      _request++;
      _aiService.cancel();
      busy = false;
      if (messages.lastOrNull?.state == 'streaming') {
        messages.last.state = 'interrupted';
      }
      unawaited(persist());
    }
    _voiceFinal = _voicePartial = '';
    emit();
  }

  /// Whether recognized [text] is the user speaking rather than the reply
  /// being picked up by the microphone (when echo cancellation is weak).
  bool isUserSpeech(String text) {
    String normalize(String value) => value.toLowerCase().replaceAll(
      RegExp(r'[^\p{L}\p{N}]', unicode: true),
      '',
    );
    final heard = normalize(text);
    // Echo cancellation leaves stray single words ("Yeah.", "No."); a real
    // interruption is a few characters or words long.
    final chinese = RegExp(r'[㐀-鿿]').allMatches(text).length;
    final words = RegExp(r'[A-Za-z]{2,}').allMatches(text).length;
    if (chinese < 3 && words < 2) return false;
    final reply = messages.lastOrNull?.role == 'assistant'
        ? normalize(AnnotationService.strip(messages.last.text))
        : '';
    if (reply.isEmpty) return true;
    final characters = heard.characters.toList();
    if (characters.length < 2) return !reply.contains(heard);
    var echoed = 0;
    for (var i = 0; i < characters.length - 1; i++) {
      if (reply.contains('${characters[i]}${characters[i + 1]}')) echoed++;
    }
    return echoed / (characters.length - 1) < .5;
  }

  /// What a voice conversation is doing right now, for the voice orb.
  VoiceStage get voiceStage {
    if (speaking) return VoiceStage.speaking;
    if (busy) {
      return (messages.lastOrNull?.text.isEmpty ?? true)
          ? VoiceStage.thinking
          : VoiceStage.responding;
    }
    if (listening) return hearing ? VoiceStage.hearing : VoiceStage.listening;
    return VoiceStage.idle;
  }

  /// The orb's single tap: start talking, cut a spoken reply short, or end.
  Future<void> voiceTap() async {
    if (speaking) {
      await stopAudio();
      return;
    }
    if (busy && !voiceConversation) return;
    await toggleMicrophone();
  }

  void toggleSubtitles() {
    subtitles = !subtitles;
    emit();
  }

  /// Switches between the workspace and the floating mini window. Window
  /// calls are asynchronous, so a switch in flight ignores further clicks;
  /// overlapping switches would save the wrong bounds and mix styles.
  Future<void> toggleCompact() async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
    if (_switchingWindow) return;
    _switchingWindow = true;
    try {
      if (!compact) {
        // Bounds of a maximized window are not restorable; leave that state
        // first and return to it afterwards.
        _wasMaximized = await windowManager.isMaximized();
        if (_wasMaximized) await windowManager.unmaximize();
        _normalBounds = await windowManager.getBounds();
        compact = true;
        emit();
        // A borderless floating card; its header doubles as the drag handle.
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: false,
        );
        await windowManager.setMinimumSize(const Size(360, 220));
        final mini = _miniBounds;
        if (mini != null) {
          await windowManager.setBounds(mini);
        } else {
          await windowManager.setSize(const Size(440, 320));
          await windowManager.setAlignment(Alignment.bottomRight);
        }
        await windowManager.setAlwaysOnTop(true);
      } else {
        _miniBounds = await windowManager.getBounds();
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        await windowManager.setMinimumSize(const Size(800, 600));
        await windowManager.setBounds(
          _normalBounds ?? const Rect.fromLTWH(100, 100, 1200, 820),
        );
        if (_wasMaximized) await windowManager.maximize();
        // The workspace appears only once the window is large enough for it.
        compact = false;
        emit();
      }
    } catch (_) {
      // Keep the UI consistent with whatever the window ended up as.
      compact = await windowManager.isAlwaysOnTop().catchError((_) => compact);
      emit();
    } finally {
      _switchingWindow = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _captureTimer?.cancel();
    _guideTimer?.cancel();
    _learnTimer?.cancel();
    _silenceTimer?.cancel();
    if (sharingScreen) unawaited(_captureService.setGlow(false));
    if (annotations > 0) unawaited(AnnotationService.clear(board: true));
    unawaited(_recognition.dispose());
    unawaited(_audioStateSubscription?.cancel());
    _aiService.dispose();
    if (_speechService != null) unawaited(_speechService!.dispose());
    super.dispose();
  }
}
