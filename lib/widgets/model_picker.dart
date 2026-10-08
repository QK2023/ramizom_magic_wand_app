import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../models/app_settings.dart';
import '../models/model_catalog.dart';
import '../services/ai_service.dart';
import 'motion.dart';

/// Picks a model. DeepSeek lists its models at once; a custom endpoint lists
/// whatever it serves, or takes a model ID.
class ModelPicker extends StatefulWidget {
  const ModelPicker({
    super.key,
    required this.current,
    required this.language,
    required this.loadModels,
    required this.provider,
    required this.providerLabel,
  });
  final String current;
  final String language;
  final AiProvider provider;
  final String providerLabel;
  final Future<List<AiModel>> Function() loadModels;
  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<ModelPicker> {
  final search = TextEditingController();
  late final preset = ModelCatalog.of(widget.provider);
  late final featured = [
    for (final m in preset?.models ?? const <ModelPreset>[])
      AiModel(id: m.id, name: m.name, acceptsImages: m.vision),
  ];
  late final bool all = preset == null;
  List<AiModel>? catalog;
  bool loading = false;
  bool failed = false;
  String t(String key) => AppStrings(widget.language).t(key);
  bool get custom => preset == null;

  @override
  void initState() {
    super.initState();
    if (all) load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      final result = await widget.loadModels();
      if (mounted) setState(() => catalog = result);
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final query = search.text.trim();
    final source = all ? catalog ?? const <AiModel>[] : featured;
    final items = source
        .where(
          (model) => '${model.id} ${model.name}'.toLowerCase().contains(
            query.toLowerCase(),
          ),
        )
        .toList();
    final busy = all && loading;
    return Dialog(
      child: SizedBox(
        width: 520,
        height: custom ? 560 : 360,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t('chooseModel'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: t('close'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Text(
                widget.providerLabel,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              if (custom) ...[
                TextField(
                  controller: search,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  // Enter takes the best match, or a typed custom model ID.
                  onSubmitted: (_) {
                    if (items.isNotEmpty && !busy) {
                      Navigator.pop(context, items.first);
                    } else if (custom && query.isNotEmpty) {
                      Navigator.pop(context, AiModel(id: query, name: query));
                    }
                  },
                  decoration: InputDecoration(
                    hintText: t('searchModels'),
                    prefixIcon: const Icon(Icons.search, size: 18),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Expanded(
                child: AnimatedSwitcher(
                  duration: Motion.medium,
                  child: busy
                      ? const Center(
                          key: ValueKey('loading'),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : all && failed
                      ? Center(
                          key: const ValueKey('failed'),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                t('modelListFailed'),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 12),
                              TextButton.icon(
                                onPressed: load,
                                icon: const Icon(Icons.refresh, size: 18),
                                label: Text(t('retry')),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          key: ValueKey(all),
                          itemCount: items.length,
                          itemBuilder: (context, index) {
                            final model = items[index];
                            final selected = model.id == widget.current;
                            final notes = [
                              if (!all && index == 0 && query.isEmpty)
                                t('recommended'),
                              if (model.acceptsImages == false) t('textOnly'),
                              if (all && model.name != model.id) model.id,
                            ];
                            return ListTile(
                              dense: true,
                              selected: selected,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              title: Text(
                                model.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: notes.isEmpty
                                  ? null
                                  : Text(
                                      notes.join(' · '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              trailing: selected
                                  ? const Icon(Icons.check, size: 18)
                                  : model.acceptsImages == true
                                  ? Tooltip(
                                      message: t('visionEnabled'),
                                      child: Icon(
                                        Icons.image_outlined,
                                        size: 18,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    )
                                  : null,
                              onTap: () => Navigator.pop(context, model),
                            );
                          },
                        ),
                ),
              ),
              if (custom && query.isNotEmpty) ...[
                const Divider(),
                TextButton.icon(
                  onPressed: () =>
                      Navigator.pop(context, AiModel(id: query, name: query)),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(
                    '${t('useModelId')} $query',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
