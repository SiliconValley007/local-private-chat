import 'package:flutter/material.dart';

/// A bottom-sheet layout with a fixed header and a bounded, scrollable action list.
///
/// Message menus can gain several attachment actions, subtitles, and expiry
/// information. A plain `Column(mainAxisSize: min)` is clipped by the modal
/// sheet's viewport on shorter phones, making its last actions unreachable.
class ScrollableActionSheet extends StatelessWidget {
  const ScrollableActionSheet({
    super.key,
    required this.header,
    required this.children,
    this.maxHeightFraction = 0.85,
  });

  final Widget header;
  final List<Widget> children;
  final double maxHeightFraction;

  static const actionsKey = Key('scrollable-action-sheet-actions');

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * maxHeightFraction,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            header,
            const Divider(height: 1),
            Flexible(
              child: ListView(
                key: actionsKey,
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                children: children,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
