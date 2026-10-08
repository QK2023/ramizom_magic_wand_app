import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../models/app_settings.dart';
import '../models/model_catalog.dart';
import '../services/ai_service.dart';
import '../services/edge_tts.dart';
import '../services/speech_service.dart';
import '../theme.dart';
import 'motion.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.initial,
    this.initialTab = 0,
    this.onPreviewVoice,
    this.onStopPreview,
  });
  final AppSettings initial;
  final int initialTab;

  /// Plays a sample with the speech API as filled in; returns the problem
  /// to show, or null once it has played.
  final Future<String?> Function(SpeechConfig config, double speed)?
  onPreviewVoice;
  final Future<void> Function()? onStopPreview;
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final form = GlobalKey<FormState>();
  late AppSettings value = widget.initial;
  late final keyField = TextEditingController(text: value.apiKey);
  late final url = TextEditingController(text: value.baseUrl);
  late final model = TextEditingController(text: value.model);
  // The voice whose sample is playing.
  String? previewing;
  String? previewProblem;
  bool reveal = false;
  late int tab = widget.initialTab;
  final Map<AiProvider, List<String>> drafts = {};
  String t(String k) => AppStrings(value.language).t(k);
  @override
  void dispose() {
    if (previewing != null) widget.onStopPreview?.call();
    for (final c in [keyField, url, model]) {
      c.dispose();
    }
    super.dispose();
  }

  void provider(AiProvider next) {
    if (next == value.provider) return;
    drafts[value.provider] = [keyField.text, url.text, model.text];
    final preset = ModelCatalog.of(next);
    final data =
        drafts[next] ??
        ['', preset?.baseUrl ?? '', preset?.defaultModel.id ?? ''];
    setState(() {
      keyField.text = data[0];
      url.text = data[1];
      model.text = data[2];
      value = value.copyWith(
        provider: next,
        sendScreen:
            ModelCatalog.find(next, data[2])?.vision ??
            (preset == null ? value.sendScreen : true),
      );
    });
  }

  /// Picks one of the provider's built-in models.
  void presetModel(String id) => setState(() {
    model.text = id;
    final known = ModelCatalog.find(value.provider, id);
    if (known != null) value = value.copyWith(sendScreen: known.vision);
  });

  /// Plays a sample of [voice]; tapping again stops it.
  Future<void> preview(String voice) async {
    final play = widget.onPreviewVoice;
    if (play == null) return;
    final stopping = previewing == voice;
    if (previewing != null) await widget.onStopPreview?.call();
    if (stopping) return;
    setState(() {
      value = value.copyWith(speechVoice: voice);
      previewing = voice;
      previewProblem = null;
    });
    final problem = await play(SpeechConfig(voice: voice), value.speechRate);
    if (!mounted || previewing != voice) return;
    setState(() {
      previewing = null;
      previewProblem = problem;
    });
  }

  Widget field(
    String label,
    TextEditingController c, {
    bool secret = false,
    int lines = 1,
    String? helper,
    String? Function(String?)? validator,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: TextFormField(
      controller: c,
      obscureText: secret && !reveal,
      maxLines: lines,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        suffixIcon: secret
            ? IconButton(
                onPressed: () => setState(() => reveal = !reveal),
                icon: Icon(
                  reveal
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              )
            : null,
      ),
    ),
  );
  Widget dropdown<T>(
    String label,
    T selected,
    List<DropdownMenuItem<T>> items,
    ValueChanged<T?> changed, {
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: DropdownButtonFormField<T>(
      key: ValueKey('$label:$selected'),
      initialValue: selected,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, helperText: helper),
      items: items,
      onChanged: changed,
    ),
  );
  Widget sectionNavigation(bool vertical) {
    final entries = {
      0: ('general', Icons.tune_rounded),
      1: ('connection', Icons.link_rounded),
      2: ('voice', Icons.mic_none_rounded),
    };
    final buttons = entries.entries
        .map(
          (entry) => Padding(
            padding: const EdgeInsets.only(bottom: 4, right: 4),
            child: AnimatedContainer(
              duration: Motion.fast,
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest
                    .withValues(alpha: tab == entry.key ? 1 : 0),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: () => setState(() => tab = entry.key),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisSize: vertical
                          ? MainAxisSize.max
                          : MainAxisSize.min,
                      children: [
                        Icon(entry.value.$2, size: 17),
                        const SizedBox(width: 10),
                        Text(
                          t(entry.value.$1),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        )
        .toList();
    return vertical ? Column(children: buttons) : Wrap(children: buttons);
  }

  @override
  Widget build(BuildContext context) {
    final languages = AppStrings.languages;
    return Theme(
      data: buildMagicWandTheme(
        brightness: value.theme == 'dark'
            ? Brightness.dark
            : value.theme == 'light'
            ? Brightness.light
            : Theme.of(context).brightness,
        accentColor: value.accentColor,
      ),
      child: Dialog(
        child: SizedBox(
          width: 800,
          height: 610,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 14, 18),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        t('settings'),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: t('close'),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 19),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final vertical = box.maxWidth >= 640;
                    final body = Expanded(
                      child: Form(
                        key: form,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(28, 22, 28, 16),
                          child: AnimatedSwitcher(
                            duration: Motion.medium,
                            switchInCurve: Motion.emphasized,
                            switchOutCurve: Curves.easeIn,
                            layoutBuilder: (current, previous) => Stack(
                              alignment: Alignment.topCenter,
                              children: [...previous, ?current],
                            ),
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                                  opacity: animation,
                                  child: SlideTransition(
                                    position: Tween(
                                      begin: const Offset(0, .03),
                                      end: Offset.zero,
                                    ).animate(animation),
                                    child: child,
                                  ),
                                ),
                            child: Column(
                              key: ValueKey(tab),
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (tab == 0) ...[
                                  dropdown(
                                    t('language'),
                                    value.language,
                                    languages.entries
                                        .map(
                                          (e) => DropdownMenuItem(
                                            value: e.key,
                                            child: Text(e.value),
                                          ),
                                        )
                                        .toList(),
                                    (v) => setState(
                                      () => value = value.copyWith(language: v),
                                    ),
                                  ),
                                  dropdown(
                                    t('appearance'),
                                    value.theme,
                                    ['light', 'dark', 'system']
                                        .map(
                                          (v) => DropdownMenuItem(
                                            value: v,
                                            child: Text(t(v)),
                                          ),
                                        )
                                        .toList(),
                                    (v) => setState(
                                      () => value = value.copyWith(theme: v),
                                    ),
                                  ),
                                  Text(
                                    t('themeColor'),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 12,
                                    runSpacing: 12,
                                    children: magicWandAccentColors.entries.map(
                                      (entry) {
                                        final selected =
                                            value.accentColor == entry.key;
                                        return Tooltip(
                                          message: t('accent_${entry.key}'),
                                          child: Semantics(
                                            label: t('accent_${entry.key}'),
                                            selected: selected,
                                            button: true,
                                            child: InkWell(
                                              key: ValueKey(
                                                'accent-${entry.key}',
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(99),
                                              onTap: () => setState(
                                                () => value = value.copyWith(
                                                  accentColor: entry.key,
                                                ),
                                              ),
                                              child: AnimatedContainer(
                                                duration: const Duration(
                                                  milliseconds: 160,
                                                ),
                                                width: 42,
                                                height: 42,
                                                decoration: BoxDecoration(
                                                  color: entry.value,
                                                  shape: BoxShape.circle,
                                                  border: Border.all(
                                                    color: selected
                                                        ? Theme.of(context)
                                                              .colorScheme
                                                              .onSurface
                                                        : Colors.transparent,
                                                    width: 2,
                                                  ),
                                                  boxShadow: selected
                                                      ? [
                                                          BoxShadow(
                                                            color: entry.value
                                                                .withValues(
                                                                  alpha: .28,
                                                                ),
                                                            blurRadius: 10,
                                                          ),
                                                        ]
                                                      : null,
                                                ),
                                                child: selected
                                                    ? const Icon(
                                                        Icons.check,
                                                        color: Colors.white,
                                                        size: 20,
                                                      )
                                                    : null,
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ).toList(),
                                  ),
                                  const SizedBox(height: 18),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(t('learningSetting')),
                                    subtitle: Text(t('learningSettingHint')),
                                    value: value.learning,
                                    onChanged: (v) => setState(
                                      () => value = value.copyWith(learning: v),
                                    ),
                                  ),
                                ],
                                if (tab == 1) ...[
                                  dropdown(
                                    t('provider'),
                                    value.provider,
                                    ModelCatalog.providers
                                        .map(
                                          (v) => DropdownMenuItem(
                                            value: v,
                                            child: Text(
                                              ModelCatalog.of(v)?.name ??
                                                  t('customApi'),
                                            ),
                                          ),
                                        )
                                        .toList(),
                                    (v) {
                                      if (v != null) provider(v);
                                    },
                                  ),
                                  field(
                                    t('apiKey'),
                                    keyField,
                                    secret: true,
                                    helper: switch (ModelCatalog.of(
                                      value.provider,
                                    )) {
                                      final preset? =>
                                        '${t('getKeyAt')} ${preset.keyUrl}',
                                      null => null,
                                    },
                                  ),
                                  if (ModelCatalog.of(value.provider)
                                      case final preset?)
                                    dropdown(
                                      t('model'),
                                      model.text,
                                      [
                                        for (final m in [
                                          ...preset.models,
                                          // A model chosen from the full
                                          // catalog stays selectable.
                                          if (ModelCatalog.find(
                                                value.provider,
                                                model.text,
                                              ) ==
                                              null)
                                            ModelPreset(
                                              model.text,
                                              ModelCatalog.displayName(
                                                value.provider,
                                                model.text,
                                              ),
                                              vision: value.sendScreen,
                                            ),
                                        ])
                                          DropdownMenuItem(
                                            value: m.id,
                                            child: _ModelOption(
                                              model: m,
                                              recommended:
                                                  m == preset.defaultModel,
                                              recommendedLabel: t(
                                                'recommended',
                                              ),
                                              noImagesLabel: t('textOnly'),
                                            ),
                                          ),
                                      ],
                                      (v) {
                                        if (v != null) presetModel(v);
                                      },
                                    ),
                                  if (value.provider == AiProvider.deepSeek)
                                    _ThinkingChoice(
                                      label: t('thinkingMode'),
                                      hint: t('thinkingHint'),
                                      value: value.thinking,
                                      name: (m) => t('thinking_${m.name}'),
                                      onChanged: (m) => setState(
                                        () =>
                                            value = value.copyWith(thinking: m),
                                      ),
                                    ),
                                  if (ModelCatalog.of(value.provider) ==
                                      null) ...[
                                    field(
                                      t('baseUrl'),
                                      url,
                                      helper: t('baseUrlHint'),
                                      validator: (v) =>
                                          AiService.validBaseUrl(v ?? '')
                                          ? null
                                          : t('invalidUrl'),
                                    ),
                                    field(
                                      t('modelId'),
                                      model,
                                      validator: (v) => (v ?? '').trim().isEmpty
                                          ? t('required')
                                          : null,
                                    ),
                                    SwitchListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(t('visionEnabled')),
                                      value: value.sendScreen,
                                      onChanged: (v) => setState(
                                        () => value = value.copyWith(
                                          sendScreen: v,
                                        ),
                                      ),
                                    ),
                                  ],
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(t('annotations')),
                                    subtitle: Text(t('annotationsHint')),
                                    value: value.annotations,
                                    onChanged: (v) => setState(
                                      () => value = value.copyWith(
                                        annotations: v,
                                      ),
                                    ),
                                  ),
                                ],
                                if (tab == 2) ...[
                                  Text(
                                    t('replyVoice'),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    t('replyVoiceHint'),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                  const SizedBox(height: 16),
                                  for (final group in [
                                    (
                                      'voicesChinese',
                                      EdgeTts.voices.where(
                                        (v) => v.id.startsWith('zh-'),
                                      ),
                                    ),
                                    (
                                      'voicesMultilingual',
                                      EdgeTts.voices.where(
                                        (v) => !v.id.startsWith('zh-'),
                                      ),
                                    ),
                                  ]) ...[
                                    Text(
                                      t(group.$1),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                    ),
                                    const SizedBox(height: 10),
                                    LayoutBuilder(
                                      builder: (context, box) {
                                        final width = (box.maxWidth - 12) / 2;
                                        return Wrap(
                                          spacing: 12,
                                          runSpacing: 10,
                                          children: [
                                            for (final voice in group.$2)
                                              SizedBox(
                                                width: width,
                                                child: _VoiceChoice(
                                                  key: ValueKey(
                                                    'voice-${voice.id}',
                                                  ),
                                                  label: voice.label(
                                                    value.language,
                                                  ),
                                                  female: voice.female,
                                                  selected:
                                                      value.speechVoice ==
                                                      voice.id,
                                                  playing:
                                                      previewing == voice.id,
                                                  previewLabel: t('preview'),
                                                  onSelect: () => setState(
                                                    () =>
                                                        value = value.copyWith(
                                                          speechVoice: voice.id,
                                                        ),
                                                  ),
                                                  onPreview:
                                                      widget.onPreviewVoice ==
                                                          null
                                                      ? null
                                                      : () => preview(voice.id),
                                                ),
                                              ),
                                          ],
                                        );
                                      },
                                    ),
                                    const SizedBox(height: 18),
                                  ],
                                  AnimatedSize(
                                    duration: Motion.fast,
                                    child: previewProblem == null
                                        ? const SizedBox(width: double.infinity)
                                        : Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 12,
                                            ),
                                            child: Text(
                                              previewProblem!,
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.error,
                                              ),
                                            ),
                                          ),
                                  ),
                                  const SizedBox(height: 18),
                                  Row(
                                    children: [
                                      Text(t('speechRate')),
                                      Expanded(
                                        child: Slider(
                                          value: value.speechRate,
                                          min: .8,
                                          max: 1.4,
                                          divisions: 6,
                                          label:
                                              '${value.speechRate.toStringAsFixed(1)}×',
                                          onChanged: (v) => setState(
                                            () => value = value.copyWith(
                                              speechRate: v,
                                            ),
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 40,
                                        child: Text(
                                          '${value.speechRate.toStringAsFixed(1)}×',
                                          textAlign: TextAlign.end,
                                        ),
                                      ),
                                    ],
                                  ),
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(t('speakReplies')),
                                    subtitle: Text(t('speakRepliesHint')),
                                    value: value.speakReplies,
                                    onChanged: (v) => setState(
                                      () => value = value.copyWith(
                                        speakReplies: v,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                    if (!vertical) {
                      return Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                            child: sectionNavigation(false),
                          ),
                          body,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 175,
                          child: ColoredBox(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerLow,
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: sectionNavigation(true),
                            ),
                          ),
                        ),
                        body,
                      ],
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(t('cancel')),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: () {
                        // Built-in providers always use their own endpoint.
                        final preset = ModelCatalog.of(value.provider);
                        if (preset != null) url.text = preset.baseUrl;
                        if (!AiService.validBaseUrl(url.text.trim()) ||
                            model.text.trim().isEmpty) {
                          setState(() => tab = 1);
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) form.currentState?.validate();
                          });
                          return;
                        }
                        if (!form.currentState!.validate()) return;
                        Navigator.pop(
                          context,
                          value.copyWith(
                            apiKey: keyField.text.trim(),
                            baseUrl: url.text.trim(),
                            model: model.text.trim(),
                          ),
                        );
                      },
                      child: Text(t('save')),
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
}

/// DeepSeek's thinking depth as a row of four segments.
class _ThinkingChoice extends StatelessWidget {
  const _ThinkingChoice({
    required this.label,
    required this.hint,
    required this.value,
    required this.name,
    required this.onChanged,
  });
  final String label;
  final String hint;
  final ThinkingMode value;
  final String Function(ThinkingMode) name;
  final ValueChanged<ThinkingMode> onChanged;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          SegmentedButton<ThinkingMode>(
            showSelectedIcon: false,
            segments: [
              for (final mode in ThinkingMode.values)
                ButtonSegment(value: mode, label: Text(name(mode))),
            ],
            selected: {value},
            onSelectionChanged: (v) => onChanged(v.first),
          ),
        ],
      ),
    );
  }
}

/// A built-in model in the model menu, with a short note when it is the
/// recommended one or cannot read images.
class _ModelOption extends StatelessWidget {
  const _ModelOption({
    required this.model,
    required this.recommended,
    required this.recommendedLabel,
    required this.noImagesLabel,
  });
  final ModelPreset model;
  final bool recommended;
  final String recommendedLabel;
  final String noImagesLabel;
  @override
  Widget build(BuildContext context) {
    final note = recommended
        ? recommendedLabel
        : model.vision
        ? null
        : noImagesLabel;
    return Row(
      children: [
        Flexible(child: Text(model.name, overflow: TextOverflow.ellipsis)),
        if (note != null) ...[
          const SizedBox(width: 10),
          Text(
            note,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// One voice to choose, with a sample to play.
class _VoiceChoice extends StatelessWidget {
  const _VoiceChoice({
    super.key,
    required this.label,
    required this.female,
    required this.selected,
    required this.playing,
    required this.previewLabel,
    required this.onSelect,
    this.onPreview,
  });
  final String label;
  final bool female;
  final bool selected;
  final bool playing;
  final String previewLabel;
  final VoidCallback onSelect;
  final VoidCallback? onPreview;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: Motion.fast,
      decoration: BoxDecoration(
        color: selected
            ? colors.primaryContainer.withValues(alpha: .55)
            : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onSelect,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
            child: Row(
              children: [
                Icon(
                  female ? Icons.face_3_outlined : Icons.face_outlined,
                  size: 19,
                  color: selected ? colors.primary : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: previewLabel,
                  onPressed: onPreview,
                  icon: Icon(
                    playing ? Icons.stop_rounded : Icons.play_arrow_rounded,
                    size: 20,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
