import 'models.dart';

/// Merges [incoming] server or wire rows into the on-device [local] transcript.
///
/// Rows are keyed by server id and client id so an optimistic echo can be
/// reconciled without dropping websocket updates that arrived while HTTP was
/// in flight. Receipt, reaction, and deletion state only ever moves forward.
List<ChatMessage> mergeConversationMessages({
  required List<ChatMessage> local,
  required List<ChatMessage> incoming,
}) {
  final slots = <ChatMessage>[];

  int? findSlot(ChatMessage message) {
    if (message.clientId != null) {
      for (var i = 0; i < slots.length; i++) {
        if (slots[i].clientId == message.clientId) return i;
      }
    }
    if (message.id > 0) {
      for (var i = 0; i < slots.length; i++) {
        if (slots[i].id == message.id) return i;
      }
    }
    return null;
  }

  void absorb(ChatMessage message) {
    final index = findSlot(message);
    if (index == null) {
      slots.add(message);
      return;
    }
    slots[index] = mergeMessagePair(slots[index], message);
  }

  for (final message in local) {
    absorb(message);
  }
  for (final message in incoming) {
    absorb(message);
  }

  final merged = List<ChatMessage>.from(slots)
    ..sort((a, b) => a.id.compareTo(b.id));
  return merged;
}

/// Combines two views of the same message without regressing local mutations.
ChatMessage mergeMessagePair(ChatMessage local, ChatMessage remote) {
  final left = local;
  final right = remote;
  final confirmed = left.id > 0 ? left : (right.id > 0 ? right : right);
  final other = identical(confirmed, left) ? right : left;

  return confirmed.copyWith(
    id: confirmed.id > 0 ? confirmed.id : other.id,
    body: _preferBody(left, right),
    editedAt: _latestTime(left.editedAt, right.editedAt),
    deletedAt: left.deletedAt ?? right.deletedAt,
    receipts: mergeReceipts(left.receipts, right.receipts),
    reactions: mergeReactions(left.reactions, right.reactions),
    pending: confirmed.id > 0 ? false : (left.pending || right.pending),
    replyTo: confirmed.replyTo ?? other.replyTo,
  );
}

String? _preferBody(ChatMessage left, ChatMessage right) {
  final a = left.body;
  final b = right.body;
  if (a == null || a.isEmpty) return b;
  if (b == null || b.isEmpty) return a;
  if (left.id > 0 && right.id <= 0) return a;
  if (right.id > 0 && left.id <= 0) return b;
  return b;
}

DateTime? _latestTime(DateTime? a, DateTime? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a.isAfter(b) ? a : b;
}

/// Receipt ticks are monotonic per recipient.
List<Receipt> mergeReceipts(List<Receipt> a, List<Receipt> b) {
  final byUser = <int, Receipt>{};
  for (final receipt in [...a, ...b]) {
    final existing = byUser[receipt.userId];
    if (existing == null) {
      byUser[receipt.userId] = receipt;
      continue;
    }
    byUser[receipt.userId] = Receipt(
      userId: receipt.userId,
      deliveredAt: _latestTime(existing.deliveredAt, receipt.deliveredAt),
      readAt: _latestTime(existing.readAt, receipt.readAt),
    );
  }
  return byUser.values.toList();
}

/// Keeps the richer reaction row when websocket and HTTP disagree.
List<ReactionAgg> mergeReactions(List<ReactionAgg> a, List<ReactionAgg> b) {
  final byEmoji = <String, ReactionAgg>{};
  for (final reaction in [...a, ...b]) {
    final existing = byEmoji[reaction.emoji];
    if (existing == null) {
      byEmoji[reaction.emoji] = reaction;
      continue;
    }
    final userIds = {...existing.userIds, ...reaction.userIds}.toList();
    final count =
        userIds.length > existing.count || userIds.length > reaction.count
        ? userIds.length
        : (existing.count > reaction.count ? existing.count : reaction.count);
    byEmoji[reaction.emoji] = ReactionAgg(
      emoji: reaction.emoji,
      count: count,
      reactedByMe: existing.reactedByMe || reaction.reactedByMe,
      userIds: userIds,
    );
  }
  return byEmoji.values.toList();
}

/// Highest server message id in [messages], or null when none are confirmed.
int? maxServerMessageId(Iterable<ChatMessage> messages) {
  var max = 0;
  for (final message in messages) {
    if (message.id > max) max = message.id;
  }
  return max > 0 ? max : null;
}
