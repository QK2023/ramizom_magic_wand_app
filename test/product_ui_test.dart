import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramizom_magic_wand/models/model_catalog.dart';
import 'package:ramizom_magic_wand/models/app_settings.dart';
import 'package:ramizom_magic_wand/widgets/settings_dialog.dart';
import 'package:ramizom_magic_wand/controllers/app_controller.dart';
import 'package:ramizom_magic_wand/l10n/app_strings.dart';
import 'package:ramizom_magic_wand/main.dart';
import 'package:ramizom_magic_wand/models/chat_message.dart';
import 'package:ramizom_magic_wand/services/ai_service.dart';
import 'package:ramizom_magic_wand/widgets/model_picker.dart';
import 'package:ramizom_magic_wand/screens/home_screen.dart';
import 'controller_test.dart' show FakeRecognition, MemoryStore, silentSpeech;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final code = FontLoader('packages/gpt_markdown/JetBrainsMono')
      ..addFont(
        rootBundle.load(
          'packages/gpt_markdown/lib/fonts/JetBrainsMono-Regular.ttf',
        ),
      );
    await code.load();
    // Real fonts make the generated QA captures representative of the Windows UI.
    for (final pair in [
      ['Segoe UI', r'C:\Windows\Fonts\segoeui.ttf'],
      ['Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc'],
    ]) {
      final file = File(pair[1]);
      if (await file.exists()) {
        final loader = FontLoader(pair[0])
          ..addFont(
            file.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await loader.load();
      }
    }
  });
  Future<void> shot(WidgetTester tester, GlobalKey key, String name) async {
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/qa/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'sidebar history search, shortcut navigation, settings and five locales work',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1240, 840));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final c = AppController(workspaceStore: MemoryStore())..loading = false;
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MagicWandApp(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await shot(tester, key, 'home-zh');

      final saved = Conversation(
        id: 'test',
        title: 'A saved conversation',
        updatedAt: DateTime(2026, 10, 5),
        messages: [
          ChatMessage(
            role: 'user',
            text: 'Find this research',
            createdAt: DateTime(2026),
          ),
        ],
      );
      c.conversations.add(saved);
      c.emit();
      await tester.pumpAndSettle();
      expect(find.text('A saved conversation'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'no match');
      await tester.pumpAndSettle();
      expect(find.text('没有找到匹配的对话。'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'research');
      await tester.pumpAndSettle();
      await shot(tester, key, 'history-zh');
      await tester.tap(find.text('A saved conversation').last);
      await tester.pumpAndSettle();
      expect(c.selectedId, 'test');

      await tester.tap(find.text('提示词'));
      await tester.pumpAndSettle();
      await shot(tester, key, 'shortcuts-zh');
      await tester.tap(find.text('创建快捷任务'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'My review');
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'Review the attached code.',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(c.shortcuts.single.name, 'My review');
      await tester.ensureVisible(find.text('My review'));
      await tester.tap(find.text('My review'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'Review the attached code.',
      );
      await tester.tap(find.text('提示词'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自然地翻译'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        contains('翻译'),
      );

      for (final language in AppStrings.languages.keys) {
        c.settings = c.settings.copyWith(language: language);
        c.emit();
        await tester.pumpAndSettle();
        expect(find.text(AppStrings(language).t('tools')), findsOneWidget);
        await tester.tap(find.text(AppStrings(language).t('settings')));
        await tester.pumpAndSettle();
        expect(find.text(AppStrings(language).t('language')), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (language == 'en') await shot(tester, key, 'settings-en');
        await tester.tap(find.byTooltip(AppStrings(language).t('close')));
        await tester.pumpAndSettle();
      }
      c.settings = c.settings.copyWith(language: 'en', theme: 'dark');
      c.newConversation();
      c.emit();
      await tester.pumpAndSettle();
      await shot(tester, key, 'home-dark');
      c.compact = true;
      c.emit();
      await tester.binding.setSurfaceSize(const Size(500, 200));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await shot(tester, key, 'mini-en');
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets('narrow navigation opens, selects history and closes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = AppController(workspaceStore: MemoryStore())..loading = false;
    c.settings = c.settings.copyWith(language: 'en');
    c.conversations.add(
      Conversation(
        id: 'narrow',
        title: 'Saved on a narrow window',
        updatedAt: DateTime(2026),
        messages: [
          ChatMessage(
            role: 'user',
            text: 'A saved message',
            createdAt: DateTime(2026),
          ),
        ],
      ),
    );
    await tester.pumpWidget(MagicWandApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Navigation'));
    await tester.pumpAndSettle();
    expect(find.text('Saved on a narrow window'), findsOneWidget);
    await tester.tap(find.text('Saved on a narrow window'));
    await tester.pumpAndSettle();
    expect(c.selectedId, 'narrow');
    expect(find.byType(Drawer), findsNothing);
    expect(find.text('A saved message'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets(
    'notices can be dismissed and expire with accessible navigation',
    (tester) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final c = AppController(workspaceStore: MemoryStore())..loading = false;
      c.settings = c.settings.copyWith(language: 'en');
      await tester.pumpWidget(MagicWandApp(controller: c));
      c.report('First notice');
      await tester.pumpAndSettle();
      expect(find.text('First notice'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      c.report('Second notice');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets('voice chat stays in app and preserves typed draft', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final recognition = FakeRecognition();
    final c = AppController(
      workspaceStore: MemoryStore(),
      recognitionService: recognition,
      speechService: silentSpeech(),
    )..loading = false;
    c.settings = c.settings.copyWith(language: 'en', apiKey: 'test');
    await tester.pumpWidget(MagicWandApp(controller: c));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Keep my draft');
    await tester.tap(find.byTooltip('Voice chat'));
    // The listening pulse repeats until voice chat ends, so pump a few frames.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(recognition.starts, 1);
    expect(c.conversations, isEmpty);
    expect(c.error, isNull);
    expect(c.listening, isTrue);
    expect(c.voiceConversation, isTrue);
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      'Keep my draft',
    );
    await tester.tap(find.byTooltip('End voice chat'));
    await tester.pumpAndSettle();
    expect(c.listening, isFalse);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets(
    'history menus fit and right click does not select the conversation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final c = AppController(workspaceStore: MemoryStore())..loading = false;
      c.settings = c.settings.copyWith(language: 'en');
      c.conversations.add(
        Conversation(
          id: 'menu',
          title: 'A saved chat',
          updatedAt: DateTime.now(),
        ),
      );
      await tester.pumpWidget(MagicWandApp(controller: c));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('chat-menu'));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('history-search'))).dy,
        lessThan(tester.getTopLeft(row).dy),
      );
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.addPointer(location: tester.getCenter(row));
      await mouse.down(tester.getCenter(row));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(c.selectedId, isNull);
      expect(find.byType(PopupMenuItem<String>), findsNWidgets(4));
      expect(
        tester.getSize(find.byType(PopupMenuItem<String>).first).width,
        greaterThanOrEqualTo(180),
      );
      await tester.tap(find.text('Pin'));
      await tester.pumpAndSettle();
      expect(c.conversations.single.pinned, isTrue);
      await mouse.moveTo(tester.getCenter(row));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: row, matching: find.byIcon(Icons.more_horiz)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuItem<String>), findsNWidgets(4));
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(700, 500));
      await tester.pumpAndSettle();
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets('mini captions scroll fully across sizes and languages', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = AppController(workspaceStore: MemoryStore())
      ..loading = false
      ..compact = true;
    final key = GlobalKey();
    c.liveCaption = List.generate(
      35,
      (i) => 'Caption line $i — a complete sentence.',
    ).join('\n');
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MagicWandApp(controller: c),
      ),
    );
    for (final language in AppStrings.languages.keys) {
      c.settings = c.settings.copyWith(language: language);
      c.emit();
      for (final size in [
        const Size(360, 220),
        const Size(500, 230),
        const Size(720, 420),
      ]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final viewport = find.byKey(const ValueKey('mini-captions'));
        final widget = tester.widget<SingleChildScrollView>(viewport);
        expect(widget.controller!.position.maxScrollExtent, greaterThan(0));
        await tester.drag(viewport, const Offset(0, -250));
        await tester.pumpAndSettle();
        expect(widget.controller!.offset, greaterThan(0));
        widget.controller!.jumpTo(widget.controller!.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(find.textContaining('Caption line 34'), findsOneWidget);
      }
    }
    await shot(tester, key, 'mini-scroll-fr');
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('markdown, code, equations and tables render without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1040, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = AppController(workspaceStore: MemoryStore())..loading = false;
    c.settings = c.settings.copyWith(language: 'en');
    final key = GlobalKey();
    const text = r'''## A clearer view
**Markdown** should read like a document, with a useful [reference](https://example.com).

The area is $A = \pi r^2$.

\[
\frac{-b \pm \sqrt{b^2-4ac}}{2a}
\]

```dart
final message = 'Hello, Magic Wand';
print(message);
```

| Feature | Ready |
| --- | --- |
| Screen context | Yes |
| Files | Yes |
''';
    final conversation = Conversation(
      id: 'rich',
      title: 'A clearer view',
      updatedAt: DateTime(2026),
      messages: [
        ChatMessage(role: 'assistant', text: text, createdAt: DateTime(2026)),
      ],
    );
    c.conversations.add(conversation);
    c.selectedId = conversation.id;
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MagicWandApp(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RichReply), findsOneWidget);
    expect(find.text(text), findsNothing);
    expect(tester.takeException(), isNull);
    await shot(tester, key, 'rich-reply');
    await tester.binding.setSurfaceSize(const Size(800, 600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets(
    'screen context remains visible while conversation and composer fit',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final c = AppController(workspaceStore: MemoryStore())..loading = false;
      c.settings = c.settings.copyWith(
        apiKey: 'test',
        model: 'example/vision-model',
      );
      final now = DateTime.now();
      final active = Conversation(
        id: 'screen',
        title: '一起看一下这份产品设计',
        updatedAt: now,
        messages: [
          ChatMessage(
            role: 'user',
            text: '帮我看看屏幕上的界面，主要操作是不是足够清楚？',
            createdAt: now,
            hadScreen: true,
          ),
          ChatMessage(
            role: 'assistant',
            model: 'example/vision-model',
            text:
                '## 先看主要操作\n\n界面已经将输入区域和聊天记录分开。接下来可以从这三个角度检查：\n\n1. **下一步是否明确**：模型选择和发送按钮都在输入框中。\n2. **上下文是否可见**：共享画面始终可检查，也可以随时停止。\n3. **对话是否连贯**：历史记录直接从左侧打开。',
            createdAt: now,
          ),
        ],
      );
      c.conversations.addAll([
        active,
        Conversation(
          id: 'pinned',
          title: '本周阅读笔记',
          updatedAt: now,
          pinned: true,
        ),
        Conversation(
          id: 'yesterday',
          title: '翻译与整理',
          updatedAt: now.subtract(const Duration(days: 1)),
        ),
        Conversation(
          id: 'earlier',
          title: '旅行计划',
          updatedAt: now.subtract(const Duration(days: 4)),
        ),
      ]);
      c.selectedId = active.id;
      c.sharingScreen = true;
      await tester.runAsync(() async {
        c.latestFrame = await File('build/qa/home-zh.png').readAsBytes();
      });
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MagicWandApp(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => precacheImage(
          MemoryImage(c.latestFrame!),
          tester.element(find.byType(HomeScreen)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('屏幕内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shot(tester, key, 'workspace-redesign-zh');
      await tester.binding.setSurfaceSize(const Size(800, 600));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('正在共享的屏幕'));
      await tester.pumpAndSettle();
      expect(find.text('屏幕内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'custom model picker filters the endpoint catalog and keeps manual entry',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelPicker(
              current: 'vendor/vision',
              language: 'en',
              provider: AiProvider.custom,
              providerLabel: 'Test provider',
              loadModels: () async => [
                const AiModel(
                  id: 'vendor/vision',
                  name: 'Vision Model',
                  acceptsImages: true,
                ),
                const AiModel(
                  id: 'vendor/text',
                  name: 'Text Model',
                  acceptsImages: false,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Vision Model'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'vision');
      await tester.pumpAndSettle();
      expect(find.text('Text Model'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelPicker(
              current: 'vendor/vision',
              language: 'en',
              provider: AiProvider.custom,
              providerLabel: 'Test provider',
              loadModels: () async =>
                  throw const AiServiceException('HTTP 404'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not load models.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'custom/model-id');
      await tester.pumpAndSettle();
      expect(find.text('Use custom/model-id'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('built-in providers offer their models without typing IDs', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var loads = 0;
    Future<void> open(AiProvider provider) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelPicker(
              key: ValueKey(provider),
              current: ModelCatalog.of(provider)!.defaultModel.id,
              language: 'zh',
              provider: provider,
              providerLabel: ModelCatalog.of(provider)!.name,
              loadModels: () async {
                loads++;
                return const [AiModel(id: 'vendor/extra', name: 'Extra')];
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await open(AiProvider.deepSeek);
    expect(find.text('DeepSeek V4.1 Flash'), findsOneWidget);
    expect(find.text('DeepSeek V4 Pro'), findsOneWidget);
    // Featured lists need no search box, network or model IDs.
    expect(find.byType(TextField), findsNothing);
    expect(loads, 0);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('DeepSeek settings offer models and thinking depth', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    AppSettings? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => saved = await showDialog<AppSettings>(
                context: context,
                builder: (_) => const SettingsDialog(
                  initial: AppSettings(language: 'en', apiKey: 'k'),
                  initialTab: 1,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Base URL'), findsNothing);
    expect(find.text('DeepSeek V4.1 Flash'), findsOneWidget);
    // Only DeepSeek and a custom API are offered.
    await tester.tap(find.text('DeepSeek').first);
    await tester.pumpAndSettle();
    expect(find.text('Custom API'), findsWidgets);
    expect(find.text('OpenRouter'), findsNothing);
    expect(find.text('Gemini'), findsNothing);
    await tester.tap(find.text('DeepSeek').last);
    await tester.pumpAndSettle();
    // Thinking: off, low, high, max.
    for (final label in ['Off', 'Low', 'High', 'Max']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('Max'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved!.provider, AiProvider.deepSeek);
    expect(saved!.baseUrl, ModelCatalog.deepSeek.baseUrl);
    expect(saved!.model, 'deepseek-flash');
    expect(saved!.thinking, ThinkingMode.max);
    expect(saved!.sendScreen, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('voice settings pick an Edge voice and play samples', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    AppSettings? saved;
    final previewed = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => saved = await showDialog<AppSettings>(
                context: context,
                builder: (_) => SettingsDialog(
                  initial: const AppSettings(language: 'zh', apiKey: 'k'),
                  initialTab: 2,
                  onPreviewVoice: (config, speed) async {
                    previewed.add(config.voice);
                    return '语音: 无法连接';
                  },
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('晓晓 · 温暖亲切'), findsOneWidget);
    expect(find.text('云希 · 阳光少年'), findsOneWidget);
    final yunxi = find.byKey(const ValueKey('voice-zh-CN-YunxiNeural'));
    await tester.ensureVisible(yunxi);
    await tester.tap(
      find.descendant(of: yunxi, matching: find.byType(IconButton)),
    );
    await tester.pumpAndSettle();
    expect(previewed, ['zh-CN-YunxiNeural']);
    expect(find.text('语音: 无法连接'), findsOneWidget);
    final emma = find.byKey(
      const ValueKey('voice-en-US-EmmaMultilingualNeural'),
    );
    await tester.ensureVisible(emma);
    await tester.tap(emma);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved!.speechVoice, 'en-US-EmmaMultilingualNeural');
    expect(tester.takeException(), isNull);
  });
}
