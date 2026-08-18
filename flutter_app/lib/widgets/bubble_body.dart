import 'package:flutter/material.dart';

/// Lays a message body out with its timestamp trailing it, the way WhatsApp does.
///
/// The clock shares the last line when there is room and drops to its own
/// right-aligned line when the body fills the width. The important part is that
/// this shrinks to fit its contents: a bubble around "Ok" stays as narrow as
/// "Ok" plus the clock, instead of stretching to the maximum bubble width and
/// making every message look the same size.
class BubbleBody extends StatelessWidget {
  const BubbleBody({super.key, required this.body, required this.meta});

  final Widget body;

  /// The timestamp, plus delivery ticks on your own messages.
  final Widget meta;

  /// Gap between the body and the clock when they share a line.
  static const gap = 8.0;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.end,
      spacing: gap,
      children: [body, meta],
    );
  }
}
