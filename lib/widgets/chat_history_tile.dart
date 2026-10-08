import 'package:flutter/material.dart';
import 'motion.dart';

/// Keeps row actions available to keyboard users while showing them on hover.
class ChatHistoryTile extends StatefulWidget {
  const ChatHistoryTile({
    super.key,
    required this.title,
    required this.selected,
    required this.pinned,
    required this.menu,
    required this.onTap,
    this.onContextMenu,
  });
  final String title;
  final bool selected;
  final bool pinned;
  final Widget menu;
  final VoidCallback? onTap;
  final ValueChanged<Offset>? onContextMenu;
  @override
  State<ChatHistoryTile> createState() => _ChatHistoryTileState();
}

class _ChatHistoryTileState extends State<ChatHistoryTile> {
  bool hovered = false;
  bool focused = false;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final revealed = hovered || focused || widget.selected;
    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: Focus(
        onFocusChange: (value) => setState(() => focused = value),
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: widget.selected
                ? colors.surfaceContainerHighest
                : hovered
                ? colors.surfaceContainerHighest.withValues(alpha: .6)
                : colors.surfaceContainerHighest.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: widget.onTap,
              onSecondaryTapDown: widget.onContextMenu == null
                  ? null
                  : (details) => widget.onContextMenu!(details.globalPosition),
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 38,
                child: Row(
                  children: [
                    // Accent pill that grows in when the row becomes current.
                    AnimatedContainer(
                      duration: Motion.medium,
                      curve: Motion.emphasized,
                      width: 3,
                      height: widget.selected ? 16 : 0,
                      margin: const EdgeInsets.only(left: 3, right: 6),
                      decoration: BoxDecoration(
                        color: colors.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    if (widget.pinned) ...[
                      Icon(
                        Icons.push_pin_outlined,
                        size: 13,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: widget.selected
                              ? FontWeight.w500
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                    AnimatedOpacity(
                      opacity: revealed ? 1 : 0,
                      duration: Motion.fast,
                      child: IgnorePointer(
                        ignoring: !revealed,
                        child: widget.menu,
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
