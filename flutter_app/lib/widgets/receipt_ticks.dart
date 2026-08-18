import 'package:flutter/material.dart';

/// WhatsApp-style delivery ticks for outgoing messages.
///
/// [level]: -1 pending, 0 sent, 1 delivered, 2 read.
class ReceiptTicks extends StatelessWidget {
  const ReceiptTicks({
    super.key,
    required this.level,
    this.onPhoto = false,
    this.size = 14,
  });

  final int level;
  final bool onPhoto;
  final double size;

  @override
  Widget build(BuildContext context) {
    final muted = onPhoto
        ? Colors.white
        : Theme.of(context).colorScheme.outline;
    if (level < 0) {
      return Icon(Icons.access_time_rounded, size: size - 1, color: muted);
    }
    if (level == 0) {
      return Icon(Icons.done_rounded, size: size, color: muted);
    }
    return Icon(
      Icons.done_all_rounded,
      size: size,
      color: level >= 2 ? const Color(0xFF2563EB) : muted,
    );
  }
}
