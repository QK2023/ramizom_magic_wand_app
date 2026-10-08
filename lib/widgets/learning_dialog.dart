import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/learning.dart';
import 'motion.dart';

/// The learning notebook: each point learned, the mistake made about it,
/// and when it comes up for review.
class LearningDialog extends StatefulWidget {
  const LearningDialog({
    super.key,
    required this.items,
    required this.language,
    required this.onDelete,
  });
  final List<LearningItem> items;
  final String language;
  final Future<void> Function(LearningItem item) onDelete;
  @override
  State<LearningDialog> createState() => _LearningDialogState();
}

class _LearningDialogState extends State<LearningDialog> {
  late final items = List.of(widget.items)
    ..sort((a, b) => a.due.compareTo(b.due));
  String t(String key) => AppStrings(widget.language).t(key);

  String when(DateTime due) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = DateTime(
      due.year,
      due.month,
      due.day,
    ).difference(today).inDays;
    if (days <= 0) return t('dueToday');
    if (days == 1) return t('dueTomorrow');
    return t('dueInDays').replaceAll('{n}', '$days');
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      child: SizedBox(
        width: 580,
        height: 600,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 14, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      t('learningRecords'),
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
            ),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          t('learningEmpty'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(24, 8, 16, 24),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const Divider(height: 24),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return Appear(
                          key: ObjectKey(item),
                          enabled: false,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.topic,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (item.point.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(item.point),
                                    ],
                                    if (item.mistake.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        '${t('mistakeLabel')}${item.mistake}',
                                        style: TextStyle(color: colors.error),
                                      ),
                                    ],
                                    const SizedBox(height: 6),
                                    Text(
                                      t(
                                        'nextReview',
                                      ).replaceAll('{when}', when(item.due)),
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: t('delete'),
                                onPressed: () async {
                                  setState(() => items.remove(item));
                                  await widget.onDelete(item);
                                },
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 19,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
