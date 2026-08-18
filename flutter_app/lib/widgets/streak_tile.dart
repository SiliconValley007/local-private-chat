import 'package:flutter/material.dart';

import '../couple_details.dart';

/// The streak row in the couple details sheet.
///
/// Shown whenever couple details are on, streak or no streak: a row that
/// vanishes when the count is zero looks like a feature that was removed.
class StreakTile extends StatelessWidget {
  const StreakTile({super.key, required this.days});

  final int days;

  @override
  Widget build(BuildContext context) {
    final lines = streakLines(days);
    return ListTile(
      leading: Opacity(
        opacity: days > 0 ? 1 : 0.4,
        child: const Text('🔥', style: TextStyle(fontSize: 22)),
      ),
      title: Text(lines.title),
      subtitle: Text(lines.subtitle),
    );
  }
}
