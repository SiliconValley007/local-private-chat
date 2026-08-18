import 'package:flutter/material.dart';

/// Placeholders shown while a screen's first load is still outstanding.
///
/// These stand in for rows that are on their way. The alternative — painting an
/// "there is nothing here" illustration and swapping it for content a moment
/// later — tells the reader something untrue and then contradicts itself.

/// A single muted block that breathes, standing in for one line or tile.
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({
    required this.width,
    required this.height,
    this.radius = 8,
    super.key,
  });

  final double width;
  final double height;
  final double radius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  // Built here rather than lazily: a placeholder can be disposed before it ever
  // builds — a fast load replaces it within the frame — and a late field would
  // then create its ticker from inside dispose, looking up an ancestor that is
  // already gone.
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A still block would be indistinguishable from a broken layout, so the
    // pulse is what marks it as waiting rather than finished.
    final animate = !MediaQuery.disableAnimationsOf(context);
    return FadeTransition(
      opacity: animate
          ? Tween(begin: 0.35, end: 0.7).animate(_controller)
          : const AlwaysStoppedAnimation(0.5),
      child: Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

/// Stand-in bubbles for a transcript that has not answered yet.
///
/// Alternating sides and widths so it reads as a conversation loading rather
/// than a list of identical bars.
class TranscriptSkeleton extends StatelessWidget {
  const TranscriptSkeleton({super.key});

  static const List<({bool mine, double width, double height})> _rows = [
    (mine: false, width: 190, height: 40),
    (mine: true, width: 140, height: 40),
    (mine: false, width: 230, height: 58),
    (mine: true, width: 170, height: 40),
    (mine: false, width: 120, height: 40),
    (mine: true, width: 210, height: 58),
  ];

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Semantics(
        label: 'Loading messages',
        child: ListView(
          reverse: true,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (final row in _rows)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: row.mine
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: SkeletonBox(
                    width: row.width,
                    height: row.height,
                    radius: 16,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Stand-in rows for a list of chats, starred messages or search results.
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({this.rows = 7, this.label = 'Loading', super.key});

  final int rows;
  final String label;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Semantics(
        label: label,
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          physics: const NeverScrollableScrollPhysics(),
          itemCount: rows,
          itemBuilder: (context, index) => const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                SkeletonBox(width: 48, height: 48, radius: 24),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBox(width: 140, height: 13),
                      SizedBox(height: 9),
                      SkeletonBox(width: 220, height: 11),
                    ],
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
