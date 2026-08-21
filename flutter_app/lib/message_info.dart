import 'package:flutter/material.dart';

import 'models.dart';

/// Blue used for read double-ticks on bubbles and Message info.
const Color receiptReadTickColor = Color(0xFF2563EB);

/// Delivered ticks stay muted. Only a Read row uses the blue double-tick.
Color messageInfoStatusColor({
  required bool readRow,
  required bool reached,
  required Color muted,
}) {
  if (!reached) return muted;
  return readRow ? receiptReadTickColor : muted;
}

class MessageRecipientInfo {
  const MessageRecipientInfo({
    required this.userId,
    required this.name,
    this.deliveredAt,
    this.readAt,
  });

  final int userId;
  final String name;
  final DateTime? deliveredAt;
  final DateTime? readAt;

  bool get hasRead => readAt != null;
  bool get hasDelivered => deliveredAt != null || hasRead;

  /// Reading proves delivery even if a delayed delivery event was never seen.
  DateTime? get effectiveDeliveredAt => deliveredAt ?? readAt;
}

/// Builds truthful per-recipient status. A missing receipt is represented as
/// waiting, never guessed from aggregate ticks.
List<MessageRecipientInfo> messageRecipientInfo({
  required ChatMessage message,
  required Map<int, String> recipientNames,
}) {
  final receipts = {
    for (final receipt in message.receipts) receipt.userId: receipt,
  };
  final result = [
    for (final entry in recipientNames.entries)
      MessageRecipientInfo(
        userId: entry.key,
        name: entry.value,
        deliveredAt: receipts[entry.key]?.deliveredAt,
        readAt: receipts[entry.key]?.readAt,
      ),
  ];
  result.sort((a, b) {
    final aRank = a.hasRead ? 2 : (a.hasDelivered ? 1 : 0);
    final bRank = b.hasRead ? 2 : (b.hasDelivered ? 1 : 0);
    final phase = bRank.compareTo(aRank);
    if (phase != 0) return phase;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return result;
}
