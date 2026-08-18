import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';

/// One persisted chat nudge (separate from the message transcript).
class NudgeRecord {
  const NudgeRecord({
    required this.nudgeId,
    required this.conversationId,
    required this.senderId,
    required this.senderUsername,
    required this.senderName,
    required this.variant,
    required this.at,
    this.pending = false,
  });

  final String nudgeId;
  final int conversationId;
  final int senderId;
  final String senderUsername;
  final String senderName;
  final String variant;
  final DateTime at;
  final bool pending;

  bool get isSent => false; // resolved by caller via viewer id

  factory NudgeRecord.fromJson(Map<String, dynamic> json) {
    return NudgeRecord(
      nudgeId: json['nudge_id'] as String,
      conversationId: json['conversation_id'] as int,
      senderId: json['sender_id'] as int,
      senderUsername: json['sender_username'] as String? ?? '',
      senderName: json['sender_name'] as String? ?? '',
      variant: json['variant'] as String? ?? 'wave',
      at: DateTime.parse(json['at'] as String).toUtc(),
    );
  }

  factory NudgeRecord.fromWire(Map<String, dynamic> event) =>
      NudgeRecord.fromJson({
        'nudge_id': event['nudge_id'],
        'conversation_id': event['conversation_id'],
        'sender_id': event['sender_id'],
        'sender_username': event['sender_username'],
        'sender_name': event['sender_name'],
        'variant': event['variant'],
        'at': event['at'],
      });

  NudgeRecord copyWith({
    String? nudgeId,
    int? conversationId,
    int? senderId,
    String? senderUsername,
    String? senderName,
    String? variant,
    DateTime? at,
    bool? pending,
  }) {
    return NudgeRecord(
      nudgeId: nudgeId ?? this.nudgeId,
      conversationId: conversationId ?? this.conversationId,
      senderId: senderId ?? this.senderId,
      senderUsername: senderUsername ?? this.senderUsername,
      senderName: senderName ?? this.senderName,
      variant: variant ?? this.variant,
      at: at ?? this.at,
      pending: pending ?? this.pending,
    );
  }
}

String _senderLabel(
  NudgeRecord record,
  Conversation? conversation,
  String Function(String username, String serverName) nameFor,
  String Function(ConversationMember member) nameForMember,
) {
  if (conversation != null) {
    for (final member in conversation.members) {
      if (member.userId == record.senderId) {
        return nameForMember(member);
      }
    }
  }
  return nameFor(record.senderUsername, record.senderName);
}

/// History row copy with explicit sent/received identity and group semantics.
String formatNudgeHistoryLine({
  required NudgeRecord record,
  required int? viewerUserId,
  required Conversation? conversation,
  required String Function(String username, String serverName) nameFor,
  required String Function(ConversationMember member) nameForMember,
}) {
  final variant = NudgeVariant.parse(record.variant);
  final isSent = record.senderId == viewerUserId;
  final isGroup = conversation?.type == 'group';

  if (isSent) {
    if (isGroup) {
      return 'You ${variant.groupSentPhrase}';
    }
    final peer = conversation?.peer;
    final peerName = peer != null
        ? nameFor(peer.username, peer.displayName)
        : 'them';
    return 'You ${variant.verb} $peerName';
  }

  final sender = _senderLabel(record, conversation, nameFor, nameForMember);
  if (isGroup) {
    return '$sender ${variant.groupReceivedPhrase}';
  }
  return '$sender ${variant.verb} you';
}

/// Short caption for the in-chat overlay and snackbars.
String formatNudgeOverlayCaption({
  required NudgeRecord record,
  required int? viewerUserId,
  required Conversation? conversation,
  required String Function(String username, String serverName) nameFor,
  required String Function(ConversationMember member) nameForMember,
}) => formatNudgeHistoryLine(
  record: record,
  viewerUserId: viewerUserId,
  conversation: conversation,
  nameFor: nameFor,
  nameForMember: nameForMember,
);

IconData nudgeHistoryIcon(NudgeVariant variant) {
  switch (variant) {
    case NudgeVariant.wave:
      return Icons.waving_hand_rounded;
    case NudgeVariant.poke:
      return Icons.touch_app_rounded;
    case NudgeVariant.hug:
      return Icons.favorite_rounded;
    case NudgeVariant.kiss:
      return Icons.favorite_border_rounded;
  }
}

/// The flavours of nudge, each with its own icon, buzz, and phrasing.
enum NudgeVariant {
  wave('wave', 'waved at', '\u{1F44B}'),
  poke('poke', 'poked', '\u{1F449}'),
  hug('hug', 'hugged', '\u{1F917}'),
  kiss('kiss', 'blew a kiss to', '\u{1F618}');

  const NudgeVariant(this.id, this.verb, this.emoji);

  final String id;
  final String verb;
  final String emoji;

  String get groupSentPhrase => '$verb the group';
  String get groupReceivedPhrase => '$verb the group';

  static NudgeVariant parse(String? raw) {
    for (final v in NudgeVariant.values) {
      if (v.id == raw) return v;
    }
    return NudgeVariant.wave;
  }

  void playHaptic() {
    switch (this) {
      case NudgeVariant.wave:
        HapticFeedback.mediumImpact();
      case NudgeVariant.poke:
        HapticFeedback.lightImpact();
      case NudgeVariant.hug:
        HapticFeedback.heavyImpact();
      case NudgeVariant.kiss:
        HapticFeedback.selectionClick();
    }
  }
}

/// A poke received over the socket for overlay playback.
class NudgeEvent {
  const NudgeEvent({
    required this.conversationId,
    required this.senderId,
    required this.senderName,
    this.variant = NudgeVariant.wave,
    this.caption,
  });

  final int conversationId;
  final int senderId;
  final String senderName;
  final NudgeVariant variant;
  final String? caption;
}
