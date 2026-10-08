import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import '../controllers/app_controller.dart';
import '../l10n/app_strings.dart';
import '../models/app_settings.dart';
import '../models/model_catalog.dart';
import '../models/chat_message.dart';
import '../models/voice_stage.dart';
import '../services/ai_service.dart';
import '../services/annotation_service.dart';
import '../widgets/chat_history_tile.dart';
import '../widgets/learning_dialog.dart';
import '../widgets/model_picker.dart';
import '../widgets/motion.dart';
import '../widgets/settings_dialog.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  static const promptKeys = {
    'explain': Icons.desktop_windows_outlined,
    'summarize': Icons.subject_rounded,
    'translate': Icons.translate_rounded,
    'write': Icons.edit_note_rounded,
  };
  AppController get c => widget.controller;
  final input = TextEditingController();
  final search = TextEditingController();
  final scroll = ScrollController();
  final captionScroll = ScrollController();
  final focus = FocusNode();
  final searchFocus = FocusNode();
  final scaffold = GlobalKey<ScaffoldState>();
  final Map<String, String> drafts = {};
  late final AnimationController listFade;
  String lastCaption = '';
  String lastMessageSignature = '';
  String? lastSelected;
  int lastCount = 0;
  int lastError = 0;
  bool sidebar = true;
  bool promptsOpen = false;
  bool showJump = false;
  double composerHeight = 132;
  String t(String key) => c.t(key);
  ColorScheme get colors => Theme.of(context).colorScheme;

  List<Conversation> get filteredConversations {
    final query = search.text.trim().toLowerCase();
    return c.sortedConversations
        .where(
          (conversation) =>
              query.isEmpty ||
              conversation.title.toLowerCase().contains(query) ||
              conversation.messages.any(
                (message) => message.text.toLowerCase().contains(query),
              ),
        )
        .toList();
  }

  bool get scrollReady =>
      scroll.hasClients && scroll.position.hasContentDimensions;

  @override
  void initState() {
    super.initState();
    listFade = AnimationController(
      vsync: this,
      duration: Motion.medium,
      value: 1,
    );
    lastSelected = c.selectedId;
    lastCount = c.messages.length;
    c.addListener(changed);
    focus.addListener(focusChanged);
    scroll.addListener(scrolled);
  }

  @override
  void dispose() {
    c.removeListener(changed);
    listFade.dispose();
    input.dispose();
    search.dispose();
    scroll.dispose();
    captionScroll.dispose();
    focus.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void focusChanged() {
    if (mounted) setState(() {});
  }

  void scrolled() {
    final show = scrollReady && scroll.position.extentAfter > 320;
    if (show != showJump) setState(() => showJump = show);
  }

  void changed() {
    final captionChanged = lastCaption != c.liveCaption;
    lastCaption = c.liveCaption;
    final followCaption =
        !captionScroll.hasClients ||
        !captionScroll.position.hasContentDimensions ||
        captionScroll.position.extentAfter < 48;
    final switched = c.selectedId != lastSelected;
    lastSelected = c.selectedId;
    final added = c.messages.length != lastCount;
    lastCount = c.messages.length;
    final signature =
        '${c.selectedId}:${c.messages.length}:${c.messages.lastOrNull?.text.length}';
    final messageChanged = signature != lastMessageSignature;
    lastMessageSignature = signature;
    final nearBottom = !scrollReady || scroll.position.extentAfter < 120;
    if (switched && c.messages.isNotEmpty) listFade.forward(from: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (captionChanged && followCaption && captionScroll.hasClients) {
        captionScroll.jumpTo(captionScroll.position.maxScrollExtent);
      }
      if (c.errorSerial != lastError && c.error != null) {
        lastError = c.errorSerial;
        notice(c.error!);
      }
      if (!scrollReady) return;
      final end = scroll.position.maxScrollExtent;
      if (switched) {
        scroll.jumpTo(end);
      } else if (messageChanged && nearBottom) {
        // Streaming grows the reply many times a second; jumping keeps it
        // pinned without stacking scroll animations.
        if (added) {
          scroll.animateTo(
            end,
            duration: Motion.medium,
            curve: Motion.emphasized,
          );
        } else {
          scroll.jumpTo(end);
        }
      }
    });
  }

  Future<void> settings({int initialTab = 0}) async {
    final result = await showMagicDialog<AppSettings>(
      context: context,
      builder: (_) => SettingsDialog(
        initial: c.settings,
        initialTab: initialTab,
        onPreviewVoice: c.previewVoice,
        onStopPreview: c.stopAudio,
      ),
    );
    if (result != null) {
      try {
        await c.updateSettings(result);
        if (mounted) notice(t('saved'));
      } catch (e) {
        c.report(e);
      }
    }
  }

  String get providerName =>
      ModelCatalog.of(c.settings.provider)?.name ??
      Uri.tryParse(c.settings.baseUrl)?.host ??
      t('customApi');

  String modelName(String id) =>
      ModelCatalog.displayName(c.settings.provider, id);

  Future<void> chooseModel() async {
    if (c.busy) return;
    if (c.settings.apiKey.isEmpty) {
      await settings(initialTab: 1);
      return;
    }
    final selected = await showMagicDialog<AiModel>(
      context: context,
      builder: (_) => ModelPicker(
        current: c.settings.model,
        language: c.settings.language,
        provider: c.settings.provider,
        providerLabel: providerName,
        loadModels: c.availableModels,
      ),
    );
    if (selected != null) {
      try {
        await c.selectModel(selected);
      } catch (error) {
        c.report(error);
      }
    }
  }

  Future<void> showPrompts() async {
    closeNavigation();
    promptsOpen = true;
    await showMagicDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(
          width: 560,
          height: 580,
          child: ListenableBuilder(listenable: c, builder: (_, _) => tools()),
        ),
      ),
    );
    promptsOpen = false;
  }

  Future<void> shareScreen() async {
    if (!c.sharingScreen && !c.settings.sendScreen) {
      c.report('visionRequired');
      return;
    }
    await c.toggleScreenSharing();
  }

  Future<void> viewScreen() => showMagicDialog<void>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 680,
        height: 460,
        child: ListenableBuilder(
          listenable: c,
          builder: (_, _) => screenPreview(),
        ),
      ),
    ),
  );

  void notice(String text) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 4),
        showCloseIcon: true,
        closeIconColor: colors.onInverseSurface,
        dismissDirection: DismissDirection.horizontal,
      ),
    );
  }

  void closeNavigation() => scaffold.currentState?.closeDrawer();

  void showNavigation({bool searching = false}) {
    if (MediaQuery.sizeOf(context).width < 900) {
      scaffold.currentState?.openDrawer();
    } else {
      setState(() => sidebar = searching || !sidebar);
    }
    if (searching) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) searchFocus.requestFocus();
      });
    }
  }

  Future<void> dictate() async {
    closeNavigation();
    if (mounted) await c.toggleMicrophone();
  }

  void fresh() {
    if (c.busy) return;
    closeNavigation();
    // Already on a new chat: keep the draft and attachments in place.
    if (c.selectedId == null) {
      focus.requestFocus();
      return;
    }
    drafts[c.selectedId!] = input.text;
    c.newConversation();
    input.text = drafts.remove('new') ?? '';
    focus.requestFocus();
  }

  void openConversation(Conversation conversation) {
    if (c.busy) return;
    drafts[c.selectedId ?? 'new'] = input.text;
    c.selectConversation(conversation.id);
    closeNavigation();
    input.text = drafts[conversation.id] ?? '';
  }

  Future<void> send() async {
    if (c.busy) return;
    final value = input.text;
    // Keep the draft until synchronous validation has accepted it.
    final future = c.sendText(value);
    if (c.busy) {
      input.clear();
      drafts.remove(c.selectedId);
    }
    await future;
  }

  void jumpToLatest() {
    if (!scrollReady) return;
    scroll.animateTo(
      scroll.position.maxScrollExtent,
      duration: Motion.slow,
      curve: Motion.emphasized,
    );
  }

  Future<void> rename(Conversation conversation) async {
    final field = TextEditingController(text: conversation.title);
    final result = await showMagicDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('rename')),
        content: TextField(
          autofocus: true,
          controller: field,
          maxLength: 100,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: Text(t('save')),
          ),
        ],
      ),
    );
    // Dialog route owns the field while its dismissal animation is in flight.
    if (result != null) await c.renameConversation(conversation, result);
  }

  Future<void> delete(Conversation conversation) async {
    final yes = await showMagicDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('deleteConfirm')),
        content: Text(t('deleteDetail')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.error,
              foregroundColor: colors.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('delete')),
          ),
        ],
      ),
    );
    if (yes == true) await c.deleteConversation(conversation);
  }

  Future<void> export(Conversation conversation) async {
    try {
      final destination = await getSaveLocation(
        suggestedName:
            'Magic Wand - ${conversation.title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')}.md',
        acceptedTypeGroups: [
          const XTypeGroup(label: 'Markdown', extensions: ['md']),
        ],
      );
      if (destination == null) return;
      final text =
          '# ${conversation.title}\n\n${conversation.messages.map((m) => '## ${m.role == 'user' ? t('you') : 'Magic Wand'}\n\n${m.note ?? AnnotationService.strip(m.text)}\n\n${m.attachments.map((a) => "- ${a.name}").join("\n")}').join('\n\n')}';
      await XFile.fromData(
        Uint8List.fromList(utf8.encode(text)),
        mimeType: 'text/markdown',
      ).saveTo(destination.path);
      if (mounted) notice(t('exported'));
    } catch (e) {
      c.report(e);
    }
  }

  Future<void> editShortcut([TaskShortcut? shortcut]) async {
    final name = TextEditingController(text: shortcut?.name);
    final prompt = TextEditingController(text: shortcut?.prompt);
    final key = GlobalKey<FormState>();
    final result = await showMagicDialog<TaskShortcut>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t(shortcut == null ? 'createTool' : 'edit')),
        content: SizedBox(
          width: 480,
          child: Form(
            key: key,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: name,
                    autofocus: true,
                    decoration: InputDecoration(labelText: t('name')),
                    validator: (v) =>
                        (v ?? '').trim().isEmpty ? t('required') : null,
                  ),
                  const SizedBox(height: 18),
                  TextFormField(
                    controller: prompt,
                    minLines: 4,
                    maxLines: 8,
                    decoration: InputDecoration(labelText: t('toolPrompt')),
                    validator: (v) =>
                        (v ?? '').trim().isEmpty ? t('required') : null,
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (key.currentState!.validate()) {
                Navigator.pop(
                  context,
                  TaskShortcut(
                    id:
                        shortcut?.id ??
                        DateTime.now().microsecondsSinceEpoch.toString(),
                    name: name.text.trim(),
                    prompt: prompt.text.trim(),
                  ),
                );
              }
            },
            child: Text(t('save')),
          ),
        ],
      ),
    );
    if (result != null) await c.saveShortcut(result);
  }

  void usePrompt(String prompt) {
    if (promptsOpen) Navigator.pop(context);
    input.text = prompt;
    focus.requestFocus();
    input.selection = TextSelection.collapsed(offset: input.text.length);
  }

  void usePromptCard(String key) {
    usePrompt(t('${key}Prompt'));
    // Explaining the screen needs it, so start sharing when the model can see.
    if (key == 'explain' && !c.sharingScreen && c.settings.sendScreen) {
      unawaited(c.toggleScreenSharing());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final narrow = MediaQuery.sizeOf(context).width < 900;
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): fresh,
          const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
              showNavigation(searching: true),
          const SingleActivator(LogicalKeyboardKey.escape): c.stopGeneration,
        },
        child: Scaffold(
          key: scaffold,
          drawer: narrow && !c.compact
              ? Drawer(width: 280, child: SafeArea(child: side()))
              : null,
          body: c.loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : Appear(
                  key: ValueKey(c.compact),
                  offset: Offset.zero,
                  scale: c.compact ? .96 : .99,
                  child: c.compact ? mini() : workspace(),
                ),
        ),
      );
    },
  );

  Widget workspace() => LayoutBuilder(
    builder: (context, box) {
      final showSidebar = sidebar && box.maxWidth >= 900;
      final showPanel = c.sharingScreen && box.maxWidth >= 1200;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          reveal(
            showSidebar ? side(key: const ValueKey('sidebar')) : null,
            layout: ('sidebar', box.maxWidth >= 900),
          ),
          Expanded(
            child: Column(
              children: [
                header(showSidebar),
                Expanded(child: stage()),
              ],
            ),
          ),
          reveal(
            showPanel
                ? SizedBox(
                    key: const ValueKey('screen-panel'),
                    width: 280,
                    height: double.infinity,
                    child: screenPreview(),
                  )
                : null,
            layout: ('screen', box.maxWidth >= 1200),
          ),
        ],
      );
    },
  );

  /// Slides a side column open or closed when the user toggles it. Crossing a
  /// [layout] breakpoint while resizing switches instantly, so the main column
  /// is never squeezed by a column that is still animating away.
  Widget reveal(Widget? child, {required (String, bool) layout}) =>
      AnimatedSwitcher(
        key: ValueKey(layout),
        duration: Motion.medium,
        switchInCurve: Motion.emphasized,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) =>
            Stack(fit: StackFit.passthrough, children: [...previous, ?current]),
        transitionBuilder: (child, animation) => SizeTransition(
          axis: Axis.horizontal,
          alignment: Alignment.centerLeft,
          sizeFactor: animation,
          child: FadeTransition(opacity: animation, child: child),
        ),
        child: child ?? const SizedBox.shrink(),
      );

  Widget icon(
    IconData symbol,
    String label,
    VoidCallback? action, {
    bool selected = false,
  }) => IconButton(
    tooltip: label,
    onPressed: action,
    icon: Icon(symbol, size: 20),
    style: selected
        ? IconButton.styleFrom(
            backgroundColor: colors.primaryContainer,
            foregroundColor: colors.onPrimaryContainer,
          )
        : null,
  );

  Widget side({Key? key}) {
    final filtered = filteredConversations;
    return Material(
      key: key,
      color: colors.surfaceContainerLow,
      child: Container(
        width: 256,
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(
              color: colors.outlineVariant.withValues(alpha: .45),
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(width: 8),
                WandMark(size: 22, spinning: c.busy),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Magic Wand',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -.3,
                    ),
                  ),
                ),
                icon(Icons.space_dashboard_outlined, t('navigation'), () {
                  if (MediaQuery.sizeOf(context).width < 900) {
                    closeNavigation();
                  } else {
                    showNavigation();
                  }
                }),
              ],
            ),
            const SizedBox(height: 22),
            nav(
              Icons.edit_square,
              t('newChat'),
              fresh,
              trailing: const _KeyHint('Ctrl N'),
            ),
            const SizedBox(height: 2),
            nav(Icons.bookmarks_outlined, t('tools'), showPrompts),
            const SizedBox(height: 18),
            TextField(
              key: const ValueKey('history-search'),
              controller: search,
              focusNode: searchFocus,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: t('search'),
                prefixIcon: const Icon(Icons.search_rounded, size: 17),
                suffixIcon: search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: t('clearSearch'),
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () => setState(search.clear),
                      ),
                filled: true,
                fillColor: colors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: colors.outlineVariant),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: colors.primary),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  if (c.conversations.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 28, 12, 12),
                      child: Column(
                        children: [
                          Icon(
                            Icons.forum_outlined,
                            size: 22,
                            color: colors.onSurfaceVariant.withValues(
                              alpha: .6,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            t('emptyHistory'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (filtered.isEmpty && search.text.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        t('noResults'),
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  for (final group in historyGroups(filtered).entries) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 16, 8, 8),
                      child: Text(
                        t(group.key),
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    for (final conversation in group.value)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: ChatHistoryTile(
                          key: ValueKey('chat-${conversation.id}'),
                          title: conversation.title,
                          selected: c.selectedId == conversation.id,
                          pinned: conversation.pinned,
                          menu: conversationMenu(conversation),
                          onContextMenu: c.busy
                              ? null
                              : (position) =>
                                    contextMenu(conversation, position),
                          onTap: c.busy
                              ? null
                              : () => openConversation(conversation),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 10),
            nav(
              Icons.link_rounded,
              t('connections'),
              () {
                closeNavigation();
                settings(initialTab: 1);
              },
              trailing: AnimatedSwitcher(
                duration: Motion.medium,
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: Icon(
                  c.settings.apiKey.isEmpty
                      ? Icons.add_rounded
                      : Icons.check_circle_rounded,
                  key: ValueKey(c.settings.apiKey.isEmpty),
                  size: 16,
                  color: c.settings.apiKey.isEmpty
                      ? colors.onSurfaceVariant
                      : const Color(0xFF2BB673),
                ),
              ),
            ),
            nav(Icons.settings_outlined, t('settings'), () {
              closeNavigation();
              settings();
            }),
          ],
        ),
      ),
    );
  }

  Map<String, List<Conversation>> historyGroups(List<Conversation> chats) {
    final groups = <String, List<Conversation>>{};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    for (final chat in chats) {
      final date = chat.updatedAt;
      final day = DateTime(date.year, date.month, date.day);
      final key = chat.pinned
          ? 'pinnedChats'
          : day == today
          ? 'today'
          : day == today.subtract(const Duration(days: 1))
          ? 'yesterday'
          : 'earlier';
      (groups[key] ??= []).add(chat);
    }
    return groups;
  }

  Widget nav(
    IconData symbol,
    String title,
    VoidCallback action, {
    Widget? trailing,
  }) => Material(
    color: Colors.transparent,
    borderRadius: BorderRadius.circular(8),
    child: InkWell(
      onTap: action,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 38,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(symbol, size: 17, color: colors.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    ),
  );

  Widget header(bool showSidebar) => SizedBox(
    height: 56,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          if (!showSidebar) ...[
            icon(
              Icons.space_dashboard_outlined,
              t('navigation'),
              showNavigation,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: AnimatedSwitcher(
              duration: Motion.medium,
              switchInCurve: Motion.emphasized,
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.centerLeft,
                children: [...previous, ?current],
              ),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween(
                    begin: const Offset(0, .35),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: Text(
                c.current?.title ?? t('newChat'),
                key: ValueKey(c.current?.title ?? ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          if (c.current != null) conversationMenu(c.current!),
          icon(
            Icons.picture_in_picture_alt_outlined,
            t('floating'),
            () => unawaited(c.toggleCompact()),
          ),
        ],
      ),
    ),
  );

  Widget conversationMenu(Conversation conversation) => PopupMenuButton<String>(
    tooltip: t('edit'),
    enabled: !c.busy,
    onSelected: (v) {
      switch (v) {
        case 'rename':
          rename(conversation);
        case 'pin':
          c.pinConversation(conversation);
        case 'export':
          export(conversation);
        case 'delete':
          delete(conversation);
      }
    },
    itemBuilder: (_) => menuItems(conversation),
    icon: const Icon(Icons.more_horiz, size: 18),
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 180, maxWidth: 240),
  );

  List<PopupMenuEntry<String>> menuItems(Conversation conversation) => [
    for (final (value, symbol, label) in [
      ('rename', Icons.drive_file_rename_outline, 'rename'),
      (
        'pin',
        conversation.pinned ? Icons.push_pin : Icons.push_pin_outlined,
        conversation.pinned ? 'unpin' : 'pin',
      ),
      ('export', Icons.file_download_outlined, 'export'),
      ('delete', Icons.delete_outline_rounded, 'delete'),
    ])
      PopupMenuItem(
        value: value,
        child: Row(
          children: [
            Icon(
              symbol,
              size: 17,
              color: value == 'delete' ? colors.error : colors.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Text(
              t(label),
              style: TextStyle(color: value == 'delete' ? colors.error : null),
            ),
          ],
        ),
      ),
  ];

  Future<void> contextMenu(Conversation conversation, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(position);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(local.dx, local.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 240),
      items: menuItems(conversation),
    );
    if (!mounted || c.busy) return;
    switch (action) {
      case 'rename':
        await rename(conversation);
      case 'pin':
        await c.pinConversation(conversation);
      case 'export':
        await export(conversation);
      case 'delete':
        await delete(conversation);
    }
  }

  /// The chat area. The composer keeps one place in the tree, so its focus
  /// and draft survive while it glides from the welcome view to the bottom.
  Widget stage() {
    final empty = c.messages.isEmpty;
    final fadeHeight = composerHeight + 52;
    return Stack(
      children: [
        Positioned.fill(child: messageList(composerHeight + 44)),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: fadeHeight,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: empty ? 0 : 1,
              duration: Motion.medium,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      colors.surface.withValues(alpha: 0),
                      colors.surface,
                    ],
                    stops: [0, (40 / fadeHeight).clamp(0, 1)],
                  ),
                ),
              ),
            ),
          ),
        ),
        AnimatedAlign(
          alignment: empty ? const Alignment(0, -.15) : Alignment.bottomCenter,
          duration: Motion.slow,
          curve: Motion.emphasized,
          child: SingleChildScrollView(
            primary: false,
            padding: EdgeInsets.fromLTRB(
              28,
              empty ? 28 : 0,
              28,
              empty ? 28 : 20,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    collapse(empty ? hero() : null),
                    MeasureSize(
                      onChange: (size) {
                        if (mounted && size.height != composerHeight) {
                          setState(() => composerHeight = size.height);
                        }
                      },
                      child: composer(),
                    ),
                    collapse(empty ? suggestions() : null),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: composerHeight + 32,
          child: Center(
            child: IgnorePointer(
              ignoring: empty || !showJump,
              child: AnimatedScale(
                scale: !empty && showJump ? 1 : .6,
                duration: Motion.medium,
                curve: Motion.emphasized,
                child: AnimatedOpacity(
                  opacity: !empty && showJump ? 1 : 0,
                  duration: Motion.fast,
                  child: Material(
                    color: colors.surfaceContainerLowest,
                    shape: CircleBorder(
                      side: BorderSide(color: colors.outlineVariant),
                    ),
                    elevation: 3,
                    shadowColor: Colors.black26,
                    child: IconButton(
                      tooltip: t('scrollToBottom'),
                      onPressed: jumpToLatest,
                      icon: const Icon(Icons.arrow_downward_rounded, size: 18),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Folds content away vertically while fading it.
  Widget collapse(Widget? child) => AnimatedSwitcher(
    duration: Motion.medium,
    switchInCurve: Motion.emphasized,
    switchOutCurve: Curves.easeInCubic,
    transitionBuilder: (child, animation) => SizeTransition(
      sizeFactor: animation,
      alignment: Alignment.center,
      child: FadeTransition(opacity: animation, child: child),
    ),
    // Full width so content is centred whatever its intrinsic width.
    child: SizedBox(key: child?.key, width: double.infinity, child: child),
  );

  Widget messageList(double bottom) => FadeTransition(
    opacity: CurvedAnimation(parent: listFade, curve: Curves.easeOut),
    child: SlideTransition(
      position: Tween(
        begin: const Offset(0, .015),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: listFade, curve: Motion.emphasized)),
      child: ListView.builder(
        controller: scroll,
        padding: EdgeInsets.fromLTRB(28, 28, 28, bottom),
        itemCount: c.messages.length,
        itemBuilder: (context, index) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: SizedBox(
              width: double.infinity,
              child: message(c.messages[index], index),
            ),
          ),
        ),
      ),
    ),
  );

  Widget hero() => Padding(
    key: const ValueKey('hero'),
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      children: [
        Appear(
          duration: Motion.slow,
          offset: Offset.zero,
          scale: .5,
          child: const WandMark(size: 72, glow: true),
        ),
        const SizedBox(height: 20),
        Appear(
          delay: const Duration(milliseconds: 80),
          child: Text(
            t('welcome'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 30,
              height: 1.3,
              fontWeight: FontWeight.w600,
              letterSpacing: -.8,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Appear(
          delay: const Duration(milliseconds: 140),
          child: Text(
            t('welcomeSub'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: colors.onSurfaceVariant),
          ),
        ),
        if (c.settings.apiKey.isEmpty)
          Appear(
            delay: const Duration(milliseconds: 200),
            child: Padding(
              padding: const EdgeInsets.only(top: 22),
              child: setupBanner(),
            ),
          )
        else if (c.dueReviews.isNotEmpty)
          Appear(
            delay: const Duration(milliseconds: 200),
            child: Padding(
              padding: const EdgeInsets.only(top: 22),
              child: reviewCard(),
            ),
          )
        else if (c.settings.learning && c.learning.items.isNotEmpty)
          Appear(
            delay: const Duration(milliseconds: 200),
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: TextButton.icon(
                onPressed: showLearning,
                icon: const Icon(Icons.menu_book_outlined, size: 18),
                label: Text(
                  t(
                    'learningCount',
                  ).replaceAll('{n}', '${c.learning.items.length}'),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  /// What is due for review today, with a way in.
  Widget reviewCard() {
    final due = c.dueReviews;
    final topics = due
        .map((item) => item.topic)
        .toSet()
        .take(3)
        .join(c.settings.language == 'zh' ? '、' : ', ');
    return Material(
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.school_outlined,
                size: 20,
                color: colors.primary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t(
                      'reviewTitle',
                    ).replaceAll('{n}', '${due.length.clamp(0, 99)}'),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    topics,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: showLearning,
              child: Text(t('learningRecords')),
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: c.busy ? null : () => unawaited(c.startReview()),
              child: Text(t('reviewStart')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> showLearning() => showMagicDialog<void>(
    context: context,
    builder: (_) => LearningDialog(
      items: c.learning.items,
      language: c.settings.language,
      onDelete: c.deleteLearningItem,
    ),
  );

  Widget setupBanner() => Material(
    color: colors.surfaceContainerLow,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(color: colors.outlineVariant),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => settings(initialTab: 1),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
        child: Row(
          children: [
            const WandMark(size: 30),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t('configure'),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t('configureHint'),
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_rounded, size: 18, color: colors.primary),
          ],
        ),
      ),
    ),
  );

  Widget suggestions() => Padding(
    key: const ValueKey('suggestions'),
    padding: const EdgeInsets.only(top: 18),
    child: LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 520 ? 2 : 1;
        final width = (box.maxWidth - 12 * (columns - 1)) / columns;
        var index = 0;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final entry in promptKeys.entries)
              Appear(
                delay: Duration(milliseconds: 200 + 60 * index++),
                offset: const Offset(0, 16),
                child: SizedBox(
                  width: width,
                  child: _PromptCard(
                    icon: entry.value,
                    title: t(entry.key),
                    description: t('${entry.key}Desc'),
                    onTap: () => usePromptCard(entry.key),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );

  Widget composer() {
    final focused = focus.hasFocus;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: focus.requestFocus,
      child: GlowBorder(
        active: c.busy || c.listening,
        radius: 18,
        child: AnimatedContainer(
          duration: Motion.medium,
          curve: Motion.emphasized,
          padding: const EdgeInsets.fromLTRB(18, 16, 10, 10),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: focused
                  ? colors.primary.withValues(alpha: .4)
                  : colors.outlineVariant,
            ),
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.black.withValues(alpha: focused ? .45 : .2)
                    : focused
                    ? colors.primary.withValues(alpha: .10)
                    : Colors.black.withValues(alpha: .035),
                blurRadius: focused ? 28 : 12,
                offset: Offset(0, focused ? 8 : 3),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedSize(
                duration: Motion.medium,
                curve: Motion.emphasized,
                alignment: Alignment.topLeft,
                child: c.guide == null
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: guideBar(),
                      ),
              ),
              AnimatedSize(
                duration: Motion.medium,
                curve: Motion.emphasized,
                alignment: Alignment.topLeft,
                child:
                    c.pendingAttachments.isEmpty &&
                        !c.sharingScreen &&
                        c.annotations == 0 &&
                        !c.exercising
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            if (c.sharingScreen)
                              Appear(
                                key: const ValueKey('screen-chip'),
                                offset: Offset.zero,
                                scale: .85,
                                child: InputChip(
                                  avatar: _LiveDot(color: colors.error),
                                  label: Text(t('screenTitle')),
                                  onPressed: viewScreen,
                                  onDeleted: shareScreen,
                                  deleteButtonTooltipMessage: t('stopScreen'),
                                ),
                              ),
                            if (c.exercising)
                              Appear(
                                key: const ValueKey('exercise-chip'),
                                offset: Offset.zero,
                                scale: .85,
                                child: Chip(
                                  avatar: Icon(
                                    Icons.edit_note_rounded,
                                    size: 18,
                                    color: colors.primary,
                                  ),
                                  label: Text(t('exerciseHint')),
                                ),
                              ),
                            if (c.annotations > 0)
                              Appear(
                                key: const ValueKey('annotations-chip'),
                                offset: Offset.zero,
                                scale: .85,
                                child: InputChip(
                                  avatar: Icon(
                                    Icons.draw_outlined,
                                    size: 16,
                                    color: colors.primary,
                                  ),
                                  label: Text(t('annotationsShown')),
                                  onDeleted: () =>
                                      unawaited(c.clearAnnotations()),
                                  deleteButtonTooltipMessage: t(
                                    'clearAnnotations',
                                  ),
                                ),
                              ),
                            for (final a in c.pendingAttachments)
                              Appear(
                                key: ObjectKey(a),
                                offset: Offset.zero,
                                scale: .85,
                                child: attachmentChip(a, removable: true),
                              ),
                          ],
                        ),
                      ),
              ),
              Focus(
                onKeyEvent: (_, event) {
                  if (event is! KeyUpEvent &&
                      event.logicalKey == LogicalKeyboardKey.enter &&
                      !HardwareKeyboard.instance.isShiftPressed &&
                      !input.value.composing.isValid) {
                    // Holding Enter must not insert newlines either.
                    if (event is KeyDownEvent) send();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  key: const ValueKey('message-input'),
                  controller: input,
                  focusNode: focus,
                  minLines: 2,
                  maxLines: 7,
                  style: const TextStyle(fontSize: 15, height: 1.5),
                  decoration: InputDecoration(
                    hintText: t('messagePlaceholder'),
                    hintStyle: TextStyle(color: colors.onSurfaceVariant),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              AnimatedSize(
                duration: Motion.medium,
                curve: Motion.emphasized,
                alignment: Alignment.topLeft,
                child: c.voiceConversation
                    ? Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          children: [
                            orbButton(26),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                c.listening
                                    ? c.liveCaption
                                    : stageLabel(c.voiceStage),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.primary,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: const ValueKey('model-selector'),
                        onPressed: c.busy ? null : chooseModel,
                        style: TextButton.styleFrom(
                          foregroundColor: colors.onSurface,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                          minimumSize: const Size(0, 32),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(9),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.auto_awesome_outlined,
                              size: 14,
                              color: colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                c.settings.apiKey.isEmpty
                                    ? t('chooseModel')
                                    : modelName(c.settings.model),
                                style: const TextStyle(fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 16,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  icon(
                    Icons.add_rounded,
                    t('attach'),
                    c.busy || c.attaching ? null : c.attachFiles,
                  ),
                  icon(
                    Icons.desktop_windows_outlined,
                    t(c.sharingScreen ? 'stopScreen' : 'screen'),
                    shareScreen,
                    selected: c.sharingScreen,
                  ),
                  PulseRings(
                    active: c.listening,
                    color: colors.primary,
                    child: icon(
                      c.voiceConversation
                          ? Icons.mic_rounded
                          : Icons.mic_none_rounded,
                      t(c.voiceConversation ? 'endVoice' : 'listen'),
                      c.busy && !c.voiceConversation ? null : dictate,
                      selected: c.voiceConversation,
                    ),
                  ),
                  const SizedBox(width: 6),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: input,
                    builder: (_, value, _) {
                      final canSend =
                          !c.attaching &&
                          (value.text.trim().isNotEmpty ||
                              c.pendingAttachments.isNotEmpty);
                      return sendButton(
                        c.busy
                            ? c.stopGeneration
                            : canSend
                            ? send
                            : null,
                        size: 34,
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Send turns into stop with a quarter turn while a reply streams.
  Widget sendButton(VoidCallback? action, {required double size}) =>
      AnimatedScale(
        scale: action == null ? .88 : 1,
        duration: Motion.fast,
        curve: Curves.easeOut,
        child: IconButton.filled(
          onPressed: action,
          tooltip: t(c.busy ? 'stop' : 'send'),
          style: IconButton.styleFrom(
            backgroundColor: colors.primary,
            foregroundColor: colors.onPrimary,
            disabledBackgroundColor: colors.surfaceContainerHighest,
            disabledForegroundColor: colors.onSurfaceVariant.withValues(
              alpha: .5,
            ),
            shape: const CircleBorder(),
            minimumSize: Size(size, size),
          ),
          icon: AnimatedSwitcher(
            duration: Motion.medium,
            switchInCurve: Motion.emphasized,
            transitionBuilder: (child, animation) => RotationTransition(
              turns: Tween<double>(begin: .75, end: 1).animate(animation),
              child: ScaleTransition(scale: animation, child: child),
            ),
            child: Icon(
              c.busy ? Icons.stop_rounded : Icons.arrow_upward_rounded,
              key: ValueKey(c.busy),
              size: 18,
            ),
          ),
        ),
      );

  Widget attachmentChip(Attachment a, {bool removable = false}) => InputChip(
    avatar: Icon(
      a.isImage
          ? Icons.image_outlined
          : a.isPdf
          ? Icons.picture_as_pdf_outlined
          : Icons.description_outlined,
      size: 18,
    ),
    label: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    onPressed: () => previewAttachment(a),
    onDeleted: removable && !c.busy ? () => c.removeAttachment(a) : null,
    deleteButtonTooltipMessage: t('remove'),
  );

  Future<void> previewAttachment(Attachment a) async {
    final file = File(a.path);
    if (!await file.exists()) {
      c.report('fileMissing');
      return;
    }
    String? text;
    if (!a.isImage && !a.isPdf) {
      try {
        text = await file.readAsString();
      } on FileSystemException {
        c.report('fileUnsupported');
        return;
      }
    }
    if (!mounted) return;
    await showMagicDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 850, maxHeight: 650),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        a.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      tooltip: t('close'),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: a.isImage
                      ? InteractiveViewer(
                          child: Image.file(
                            file,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.broken_image_outlined),
                          ),
                        )
                      : a.isPdf
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.picture_as_pdf_outlined,
                                size: 60,
                              ),
                              const SizedBox(height: 20),
                              Text(a.name),
                              const SizedBox(height: 12),
                              Text('${(a.size / 1024).round()} KB'),
                            ],
                          ),
                        )
                      : SingleChildScrollView(
                          child: SelectableText(text ?? ''),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The step being done in a walkthrough, with ways to move it along.
  Widget guideBar() {
    final step = c.guide!;
    return Appear(
      key: const ValueKey('guide-bar'),
      offset: const Offset(0, 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        decoration: BoxDecoration(
          color: colors.primaryContainer.withValues(alpha: .45),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.primary.withValues(alpha: .25)),
        ),
        child: Row(
          children: [
            AnimatedSwitcher(
              duration: Motion.fast,
              child: c.guideChecking
                  ? SizedBox.square(
                      key: const ValueKey('checking'),
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.primary,
                      ),
                    )
                  : Icon(
                      Icons.touch_app_outlined,
                      key: const ValueKey('waiting'),
                      size: 20,
                      color: colors.primary,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t('guideTitle').replaceAll('{n}', '${step.number}'),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: Motion.fast,
                    child: Text(
                      t(c.guideChecking ? 'guideChecking' : 'guideWaiting'),
                      key: ValueKey(c.guideChecking),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: c.busy ? null : () => unawaited(c.guideSkip()),
              child: Text(t('guideSkipButton')),
            ),
            const SizedBox(width: 4),
            FilledButton.tonal(
              onPressed: c.busy ? null : () => unawaited(c.guideFinished()),
              child: Text(t('guideFinishedButton')),
            ),
            IconButton(
              tooltip: t('guideEnd'),
              onPressed: c.endGuide,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  /// A turn the app added itself, such as "step 2 done".
  Widget noteMessage(ChatMessage m) => Appear(
    key: ObjectKey(m),
    enabled:
        DateTime.now().difference(m.createdAt) < const Duration(seconds: 1),
    offset: const Offset(0, 8),
    child: Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(99),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.task_alt_rounded, size: 15, color: colors.primary),
              const SizedBox(width: 6),
              Text(
                m.note!,
                style: TextStyle(
                  fontSize: 12.5,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget message(ChatMessage m, int index) {
    if (m.note != null) return noteMessage(m);
    final user = m.role == 'user';
    final last = index == c.messages.length - 1;
    // Only messages created a moment ago animate in; history renders still.
    final fresh =
        DateTime.now().difference(m.createdAt) < const Duration(seconds: 1);
    return Appear(
      key: ObjectKey(m),
      enabled: fresh,
      offset: Offset(user ? 12 : 0, 14),
      child: _Hover(
        builder: (context, hovered) => Padding(
          padding: const EdgeInsets.only(bottom: 28),
          child: Column(
            crossAxisAlignment: user
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (!user)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      WandMark(size: 20, spinning: m.state == 'streaming'),
                      const SizedBox(width: 8),
                      Text(
                        m.model == null ? 'Magic Wand' : modelName(m.model!),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              if (m.attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    alignment: user ? WrapAlignment.end : WrapAlignment.start,
                    children: m.attachments
                        .map((a) => attachmentChip(a))
                        .toList(),
                  ),
                ),
              if (m.hadScreen)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.desktop_windows_outlined,
                        size: 14,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        t('screenAttached'),
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              if (user)
                Container(
                  constraints: const BoxConstraints(maxWidth: 620),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainer,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(20),
                      topRight: Radius.circular(20),
                      bottomLeft: Radius.circular(20),
                      bottomRight: Radius.circular(6),
                    ),
                  ),
                  child: SelectableText(
                    m.text,
                    style: const TextStyle(fontSize: 16, height: 1.6),
                  ),
                )
              else if (m.text.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: m.state == 'streaming'
                      ? ThinkingIndicator(label: t('thinking'))
                      : Text(
                          t(
                            m.state == 'interrupted' ? 'interrupted' : 'failed',
                          ),
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RichReply(
                        text: AnnotationService.strip(m.text),
                        onCopy: () => notice(t('copied')),
                      ),
                      if (m.state == 'streaming')
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: StreamingCaret(),
                        ),
                    ],
                  ),
                ),
              if (!user && m.state != 'streaming')
                AnimatedOpacity(
                  opacity: last || hovered ? 1 : 0,
                  duration: Motion.fast,
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _CopyButton(
                        text: AnnotationService.strip(m.text),
                        label: t('copy'),
                        doneLabel: t('copied'),
                      ),
                      icon(
                        c.speaking && c.spokenText == m.text
                            ? Icons.stop_circle_outlined
                            : Icons.volume_up_outlined,
                        t(
                          c.speaking && c.spokenText == m.text
                              ? 'stopAudio'
                              : 'readAloud',
                        ),
                        () {
                          if (c.speaking && c.spokenText == m.text) {
                            c.stopAudio();
                          } else {
                            c.readAloud(m.text);
                          }
                        },
                      ),
                      if (last)
                        icon(
                          Icons.refresh_rounded,
                          t('retry'),
                          c.busy ? null : () => c.retryLast(),
                        ),
                      if (m.state == 'interrupted' || m.state == 'error')
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            t(m.state == 'error' ? 'failed' : 'interrupted'),
                            style: TextStyle(
                              color: m.state == 'error'
                                  ? colors.error
                                  : colors.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget screenPreview() => Material(
    color: colors.surfaceContainerLow,
    child: Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: colors.outlineVariant)),
      ),
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t('screenContext'),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                icon(Icons.close_rounded, t('stopScreen'), () {
                  shareScreen();
                  if (Navigator.of(context).canPop()) Navigator.pop(context);
                }),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Icon(
                  Icons.desktop_windows_outlined,
                  size: 16,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t('screenTitle'),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (c.sharingScreen)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: colors.error.withValues(alpha: .1),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _LiveDot(color: colors.error, size: 6),
                        const SizedBox(width: 5),
                        Text(
                          t('live'),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: colors.error,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 180,
                child: ColoredBox(
                  color: colors.surfaceContainerHighest,
                  child: AnimatedSwitcher(
                    duration: Motion.slow,
                    child: c.latestFrame == null
                        ? Center(
                            key: const ValueKey('waiting'),
                            child: c.sharingScreen
                                ? const CircularProgressIndicator(
                                    strokeWidth: 2,
                                  )
                                : const Icon(Icons.desktop_windows_outlined),
                          )
                        : SizedBox.expand(
                            key: const ValueKey('frame'),
                            child: Image.memory(
                              c.latestFrame!,
                              // A new frame arrives every two seconds; decode
                              // it at the preview's size, not the screen's.
                              cacheHeight:
                                  (180 * MediaQuery.devicePixelRatioOf(context))
                                      .round(),
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                            ),
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              t('screenNotice'),
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: c.sharingScreen && !c.captureInProgress
                  ? c.captureNow
                  : null,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: Text(t('refreshPreview')),
            ),
            const SizedBox(height: 8),
            if (c.sharingScreen)
              TextButton.icon(
                onPressed: () {
                  shareScreen();
                  if (Navigator.of(context).canPop()) Navigator.pop(context);
                },
                icon: const Icon(Icons.stop_screen_share_outlined, size: 17),
                label: Text(t('stopScreen')),
              ),
          ],
        ),
      ),
    ),
  );

  Widget tools() {
    var index = 0;
    Widget tile({
      required Widget leading,
      required String title,
      String? subtitle,
      Widget? trailing,
      required VoidCallback onTap,
    }) => Appear(
      delay: Duration(milliseconds: 30 * index++),
      offset: const Offset(0, 8),
      child: ListTile(
        leading: leading,
        title: Text(title, style: const TextStyle(fontSize: 14)),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12.5,
                  color: colors.onSurfaceVariant,
                ),
              ),
        trailing: trailing,
        onTap: onTap,
      ),
    );
    Widget badge(IconData symbol) => Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: .6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(symbol, size: 18, color: colors.onPrimaryContainer),
    );
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t('tools'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              icon(
                Icons.close_rounded,
                t('close'),
                () => Navigator.pop(context),
              ),
            ],
          ),
          Text(
            t('toolsSub'),
            style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              children: [
                for (final entry in promptKeys.entries)
                  tile(
                    leading: badge(entry.value),
                    title: t(entry.key),
                    subtitle: t('${entry.key}Desc'),
                    trailing: const Icon(Icons.arrow_forward_rounded, size: 16),
                    onTap: () => usePrompt(t('${entry.key}Prompt')),
                  ),
                if (c.shortcuts.isNotEmpty) const Divider(height: 28),
                for (final shortcut in c.shortcuts)
                  tile(
                    leading: badge(Icons.bookmark_border_rounded),
                    title: shortcut.name,
                    onTap: () => usePrompt(shortcut.prompt),
                    trailing: PopupMenuButton<String>(
                      icon: const Icon(Icons.more_horiz, size: 18),
                      onSelected: (v) {
                        if (v == 'edit') {
                          editShortcut(shortcut);
                        } else {
                          c.removeShortcut(shortcut);
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 'edit', child: Text(t('edit'))),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(t('delete')),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => editShortcut(),
            icon: const Icon(Icons.add, size: 17),
            label: Text(t('createTool')),
          ),
        ],
      ),
    );
  }

  String stageLabel(VoiceStage stage) => t(switch (stage) {
    VoiceStage.idle => 'tapToTalk',
    VoiceStage.listening || VoiceStage.hearing => 'listening',
    VoiceStage.thinking => 'thinking',
    VoiceStage.responding => 'responding',
    VoiceStage.speaking => 'tapToInterrupt',
  });

  /// The voice orb as a button: talk, interrupt a spoken reply, or end.
  Widget orbButton(double size) {
    final stage = c.voiceConversation || c.speaking
        ? c.voiceStage
        : VoiceStage.idle;
    return Tooltip(
      message: stageLabel(stage),
      child: Semantics(
        button: true,
        label: stageLabel(stage),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: c.busy && !c.voiceConversation && !c.speaking
                ? null
                : () => unawaited(c.voiceTap()),
            child: VoiceOrb(
              key: const ValueKey('voice-orb'),
              stage: stage,
              size: size,
            ),
          ),
        ),
      ),
    );
  }

  /// Starts a window drag from the mini header, which has no title bar.
  void dragWindow() {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return;
    unawaited(windowManager.startDragging().catchError((Object _) {}));
  }

  /// The floating companion: a voice orb, live captions and a slim composer.
  Widget mini() => LayoutBuilder(
    builder: (context, box) {
      final tall = box.maxHeight >= 300;
      final orbSize = tall
          ? (box.maxHeight * .32).clamp(80.0, 156.0)
          : (box.maxHeight * .34).clamp(48.0, 64.0);
      final lastUser = c.messages.reversed
          .where((m) => m.role == 'user')
          .firstOrNull;
      final captions = c.subtitles
          ? ShaderMask(
              // Older lines dissolve at the top instead of being cut off.
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black],
                stops: [0, .12],
              ).createShader(bounds),
              child: Scrollbar(
                controller: captionScroll,
                child: SingleChildScrollView(
                  key: const ValueKey('mini-captions'),
                  controller: captionScroll,
                  padding: const EdgeInsets.fromLTRB(0, 10, 10, 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: SelectionArea(
                      child: Column(
                        crossAxisAlignment: tall
                            ? CrossAxisAlignment.center
                            : CrossAxisAlignment.start,
                        children: [
                          if (lastUser != null && !c.listening)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                lastUser.text,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: tall
                                    ? TextAlign.center
                                    : TextAlign.start,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          AnimatedDefaultTextStyle(
                            duration: Motion.medium,
                            textAlign: tall
                                ? TextAlign.center
                                : TextAlign.start,
                            style: Theme.of(context).textTheme.bodyLarge!
                                .copyWith(
                                  fontSize: tall ? 17 : 15,
                                  height: 1.55,
                                  color: c.liveCaption.isEmpty
                                      ? colors.onSurfaceVariant
                                      : colors.onSurface,
                                ),
                            child: Text(
                              c.liveCaption.isEmpty
                                  ? t('placeholder')
                                  : plainCaption(c.liveCaption),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            )
          : const SizedBox.expand();
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: tall ? const Alignment(0, -.35) : const Alignment(-.8, 0),
            radius: tall ? .9 : 1.2,
            colors: [
              const Color(0xFF2F80FF).withValues(alpha: .10),
              const Color(0xFF2F80FF).withValues(alpha: 0),
            ],
          ),
        ),
        child: Column(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => dragWindow(),
              child: SizedBox(
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 6, 0),
                  child: Row(
                    children: [
                      WandMark(size: 20, spinning: c.busy),
                      const SizedBox(width: 9),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: Motion.medium,
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.centerLeft,
                            children: [...previous, ?current],
                          ),
                          child: Text(
                            c.voiceConversation || c.busy || c.speaking
                                ? stageLabel(c.voiceStage)
                                : 'Magic Wand',
                            key: ValueKey(
                              c.voiceConversation || c.busy || c.speaking
                                  ? c.voiceStage
                                  : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      if (c.guide != null)
                        icon(
                          Icons.check_circle_outline_rounded,
                          t('guideFinishedButton'),
                          c.busy ? null : () => unawaited(c.guideFinished()),
                        ),
                      if (c.annotations > 0)
                        icon(
                          Icons.layers_clear_outlined,
                          t('clearAnnotations'),
                          () => unawaited(c.clearAnnotations()),
                        ),
                      icon(
                        Icons.closed_caption_outlined,
                        t('subtitles'),
                        c.toggleSubtitles,
                        selected: c.subtitles,
                      ),
                      icon(
                        Icons.open_in_full_rounded,
                        t('expand'),
                        () => c.toggleCompact(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: tall
                    ? Column(
                        children: [
                          const SizedBox(height: 6),
                          orbButton(orbSize),
                          Expanded(child: captions),
                        ],
                      )
                    : Row(
                        children: [
                          orbButton(orbSize),
                          const SizedBox(width: 12),
                          Expanded(child: captions),
                        ],
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              child: SizedBox(
                height: 40,
                child: Row(
                  children: [
                    icon(
                      c.sharingScreen
                          ? Icons.stop_screen_share_outlined
                          : Icons.screen_share_outlined,
                      t(c.sharingScreen ? 'stopScreen' : 'screen'),
                      shareScreen,
                      selected: c.sharingScreen,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('mini-message-input'),
                        controller: input,
                        focusNode: focus,
                        maxLines: 1,
                        onChanged: (_) => setState(() {}),
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => send(),
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: t('placeholder'),
                          filled: true,
                          fillColor: colors.surfaceContainer,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide(
                              color: colors.primary.withValues(alpha: .4),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Typing turns the mic into send, like mainstream assistants.
                    AnimatedSwitcher(
                      duration: Motion.medium,
                      transitionBuilder: (child, animation) =>
                          ScaleTransition(scale: animation, child: child),
                      child: c.busy || input.text.trim().isNotEmpty
                          ? KeyedSubtree(
                              key: const ValueKey('send'),
                              child: sendButton(
                                c.busy ? c.stopGeneration : send,
                                size: 40,
                              ),
                            )
                          : PulseRings(
                              key: const ValueKey('mic'),
                              active: c.listening,
                              color: colors.primary,
                              child: IconButton.filled(
                                tooltip: t(
                                  c.voiceConversation ? 'endVoice' : 'listen',
                                ),
                                onPressed: dictate,
                                style: IconButton.styleFrom(
                                  minimumSize: const Size(40, 40),
                                  shape: const CircleBorder(),
                                  backgroundColor: c.voiceConversation
                                      ? colors.primary
                                      : colors.surfaceContainerHighest,
                                  foregroundColor: c.voiceConversation
                                      ? colors.onPrimary
                                      : colors.onSurface,
                                ),
                                icon: Icon(
                                  c.voiceConversation
                                      ? Icons.mic_rounded
                                      : Icons.mic_none_rounded,
                                  size: 20,
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// A small keyboard shortcut hint, e.g. "Ctrl N".
class _KeyHint extends StatelessWidget {
  const _KeyHint(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          height: 1.3,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A steady status dot with a soft halo.
class _LiveDot extends StatelessWidget {
  const _LiveDot({required this.color, this.size = 8});
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      boxShadow: [
        BoxShadow(color: color.withValues(alpha: .45), blurRadius: size),
      ],
    ),
  );
}

/// Rebuilds with whether the pointer is over the child.
class _Hover extends StatefulWidget {
  const _Hover({required this.builder});
  final Widget Function(BuildContext context, bool hovered) builder;
  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
  bool hovered = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => hovered = true),
    onExit: (_) => setState(() => hovered = false),
    child: widget.builder(context, hovered),
  );
}

/// Copies text and briefly turns into a check mark.
class _CopyButton extends StatefulWidget {
  const _CopyButton({
    required this.text,
    required this.label,
    required this.doneLabel,
  });
  final String text;
  final String label;
  final String doneLabel;
  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool done = false;
  Timer? reset;

  Future<void> copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => done = true);
    reset?.cancel();
    reset = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => done = false);
    });
  }

  @override
  void dispose() {
    reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: done ? widget.doneLabel : widget.label,
    onPressed: copy,
    icon: AnimatedSwitcher(
      duration: Motion.fast,
      transitionBuilder: (child, animation) =>
          ScaleTransition(scale: animation, child: child),
      child: Icon(
        done ? Icons.check_rounded : Icons.copy_outlined,
        key: ValueKey(done),
        size: 18,
        color: done ? const Color(0xFF2BB673) : null,
      ),
    ),
  );
}

/// A welcome suggestion that lifts slightly under the pointer.
class _PromptCard extends StatefulWidget {
  const _PromptCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;
  @override
  State<_PromptCard> createState() => _PromptCardState();
}

class _PromptCardState extends State<_PromptCard> {
  bool hovered = false;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: AnimatedSlide(
        offset: Offset(0, hovered ? -.04 : 0),
        duration: Motion.fast,
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: hovered
                ? colors.surfaceContainerLowest
                : colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: hovered
                  ? colors.primary.withValues(alpha: .3)
                  : colors.outlineVariant.withValues(alpha: .7),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: hovered ? .06 : 0),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: Motion.fast,
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: hovered
                            ? colors.primary
                            : colors.primaryContainer.withValues(alpha: .6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        widget.icon,
                        size: 18,
                        color: hovered
                            ? colors.onPrimary
                            : colors.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String plainCaption(String text) => text
    .replaceAll(RegExp(r'```[\s\S]*?```'), '')
    .replaceAll(RegExp(r'[#*`_]'), '')
    .trim();

class RichReply extends StatelessWidget {
  const RichReply({super.key, required this.text, this.onCopy});
  final String text;
  final VoidCallback? onCopy;
  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(Localizations.localeOf(context).toLanguageTag());
    return SelectionArea(
      child: GptMarkdown(
        text,
        style: TextStyle(
          fontSize: 16,
          height: 1.65,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        useDollarSignsForLatex: true,
        styleSheet: GptMarkdownStyleSheet(
          codeBlock: CodeBlockStyle(
            copyLabel: strings.t('copy'),
            copiedLabel: strings.t('copied'),
            fontSize: 14,
          ),
        ),
        imageBuilder: (context, url, width, height) {
          final uri = Uri.tryParse(url);
          return OutlinedButton.icon(
            icon: const Icon(Icons.image_outlined),
            label: Text(uri?.host ?? ''),
            onPressed: uri != null && ['https', 'http'].contains(uri.scheme)
                ? () => launchUrl(uri, mode: LaunchMode.externalApplication)
                : null,
          );
        },
        onCodeCopy: (_) => onCopy?.call(),
        onLinkTap: (url, _) async {
          final uri = Uri.tryParse(url);
          if (uri != null && ['https', 'http'].contains(uri.scheme)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
      ),
    );
  }
}
