import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../services/reaction_freq_store.dart';

/// Emoji offered on the quick reaction bar, in WhatsApp's order.
const kQuickReactions = [
  '\u2764\uFE0F',
  '\u{1F44D}',
  '\u{1F602}',
  '\u{1F62E}',
  '\u{1F622}',
  '\u{1F64F}',
];

/// A larger curated set for the "more" grid. Kept dependency-free; the picker
/// also lets you type any emoji from the system keyboard, so this is just a
/// fast path for common ones.
const _pickerEmojis = <String>[
  '\u2764\uFE0F',
  '\u{1F9E1}',
  '\u{1F49B}',
  '\u{1F49A}',
  '\u{1F499}',
  '\u{1F49C}',
  '\u{1F5A4}',
  '\u{1F90D}',
  '\u{1F44D}',
  '\u{1F44E}',
  '\u{1F44F}',
  '\u{1F64C}',
  '\u{1F64F}',
  '\u{1F4AA}',
  '\u{1F44A}',
  '\u{1F91D}',
  '\u{1F602}',
  '\u{1F923}',
  '\u{1F60A}',
  '\u{1F60D}',
  '\u{1F970}',
  '\u{1F618}',
  '\u{1F617}',
  '\u{1F929}',
  '\u{1F60E}',
  '\u{1F914}',
  '\u{1F644}',
  '\u{1F60F}',
  '\u{1F612}',
  '\u{1F61E}',
  '\u{1F622}',
  '\u{1F62D}',
  '\u{1F621}',
  '\u{1F620}',
  '\u{1F92C}',
  '\u{1F631}',
  '\u{1F633}',
  '\u{1F62E}',
  '\u{1F97A}',
  '\u{1F914}',
  '\u{1F389}',
  '\u{1F38A}',
  '\u2728',
  '\u{1F525}',
  '\u{1F4AF}',
  '\u2705',
  '\u274C',
  '\u2757',
  '\u{1F440}',
  '\u{1F44B}',
  '\u{1F91F}',
  '\u270C\uFE0F',
  '\u{1F919}',
  '\u{1F448}',
  '\u{1F449}',
  '\u{1F446}',
  '\u{1F339}',
  '\u{1F33B}',
  '\u{1F337}',
  '\u{1F382}',
  '\u{1F381}',
  '\u{1F48B}',
  '\u{1F498}',
  '\u{1F495}',
];

/// A floating pill of quick emoji shown above the long-pressed message.
///
/// Tapping an emoji reports it; the "+" reports null so the caller can open the
/// full picker. The emoji you already reacted with is highlighted.
class ReactionBar extends StatefulWidget {
  const ReactionBar({
    super.key,
    required this.onPick,
    required this.onMore,
    this.myEmoji,
  });

  final ValueChanged<String> onPick;
  final VoidCallback onMore;
  final String? myEmoji;

  @override
  State<ReactionBar> createState() => _ReactionBarState();
}

class _ReactionBarState extends State<ReactionBar> {
  List<String> _emoji = kQuickReactions;

  @override
  void initState() {
    super.initState();
    ReactionFreqStore.frequent(fallback: kQuickReactions).then((list) {
      if (mounted && list.isNotEmpty) setState(() => _emoji = list);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final e in _emoji)
            _ReactionButton(
              emoji: e,
              selected: e == widget.myEmoji,
              onTap: () => widget.onPick(e),
            ),
          IconButton(
            tooltip: 'More',
            icon: const Icon(Icons.add_circle_outline_rounded),
            onPressed: widget.onMore,
          ),
        ],
      ),
    );
  }
}

class _ReactionButton extends StatelessWidget {
  const _ReactionButton({
    required this.emoji,
    required this.selected,
    required this.onTap,
  });

  final String emoji;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? scheme.primary.withValues(alpha: 0.18) : null,
        ),
        child: Text(emoji, style: const TextStyle(fontSize: 24)),
      ),
    );
  }
}

/// Opens the full reaction picker. Returns the chosen emoji, or null if
/// dismissed. Includes a type-any field so a person can react with any emoji
/// their keyboard offers, not just the curated grid.
Future<String?> showReactionPicker(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => const _ReactionPickerSheet(),
  );
}

class _ReactionPickerSheet extends StatefulWidget {
  const _ReactionPickerSheet();

  @override
  State<_ReactionPickerSheet> createState() => _ReactionPickerSheetState();
}

class _ReactionPickerSheetState extends State<_ReactionPickerSheet> {
  final _controller = TextEditingController();
  List<String> _frequent = const [];

  @override
  void initState() {
    super.initState();
    ReactionFreqStore.frequent(limit: 8, fallback: kQuickReactions).then((
      list,
    ) {
      if (mounted) setState(() => _frequent = list);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submitTyped() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    // Take just the first emoji grapheme so a stray word can't be sent.
    final first = text.characters.first;
    Navigator.pop(context, first);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset, left: 12, right: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'React with any emoji',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  autofocus: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submitTyped(),
                  inputFormatters: [LengthLimitingTextInputFormatter(8)],
                  decoration: const InputDecoration(
                    hintText: 'Type or paste an emoji',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _submitTyped, child: const Text('React')),
            ],
          ),
          if (_frequent.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Frequent', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              children: [
                for (final e in _frequent)
                  InkWell(
                    onTap: () => Navigator.pop(context, e),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(e, style: const TextStyle(fontSize: 26)),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Flexible(
            child: GridView.count(
              crossAxisCount: 8,
              shrinkWrap: true,
              children: [
                for (final e in _pickerEmojis)
                  InkWell(
                    onTap: () => Navigator.pop(context, e),
                    child: Center(
                      child: Text(e, style: const TextStyle(fontSize: 26)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// The little emoji tallies shown under a bubble. Tapping a chip toggles your
/// own reaction with that emoji.
class ReactionChips extends StatelessWidget {
  const ReactionChips({
    super.key,
    required this.reactions,
    required this.onToggle,
    this.alignEnd = false,
  });

  final List<ReactionAgg> reactions;
  final ValueChanged<String> onToggle;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final r in reactions)
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => onToggle(r.emoji),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: r.reactedByMe
                    ? scheme.primary.withValues(alpha: 0.18)
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: r.reactedByMe
                      ? scheme.primary.withValues(alpha: 0.5)
                      : scheme.outlineVariant,
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(r.emoji, style: const TextStyle(fontSize: 13)),
                  if (r.count > 1) ...[
                    const SizedBox(width: 3),
                    Text(
                      '${r.count}',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}
