import 'dart:convert';

import 'package:flutter/material.dart';

/// Parsed call-log body (`type=call` message JSON).
class CallLogInfo {
  const CallLogInfo({
    required this.media,
    required this.outcome,
    this.durationSecs,
    this.endedByUserId,
    this.callId,
  });

  final String media;
  final String outcome;
  final int? durationSecs;
  final int? endedByUserId;
  final String? callId;

  bool get isVideo => media == 'video';

  bool get isNegative =>
      isMissedOutcome(outcome) ||
      outcome == 'rejected' ||
      outcome == 'busy' ||
      outcome == 'cancelled' ||
      outcome == 'unreachable';
}

/// Normalizes legacy and current server outcomes to a canonical set.
String normalizeCallOutcome(String raw) {
  switch (raw) {
    case 'completed':
    case 'answered':
      return 'answered';
    case 'declined':
    case 'no_answer':
    case 'missed':
      return 'missed';
    case 'rejected':
    case 'busy':
    case 'cancelled':
    case 'unreachable':
      return raw;
    default:
      return raw.isEmpty ? 'missed' : raw;
  }
}

bool isMissedOutcome(String outcome) =>
    normalizeCallOutcome(outcome) == 'missed';

/// Parses a call-log JSON body; never throws and never returns raw JSON text.
CallLogInfo parseCallLogBody(String? body) {
  if (body == null || body.trim().isEmpty) {
    return const CallLogInfo(media: 'audio', outcome: 'missed');
  }
  try {
    final data = jsonDecode(body) as Map<String, dynamic>;
    return CallLogInfo(
      media: data['media'] as String? ?? 'audio',
      outcome: normalizeCallOutcome(data['outcome'] as String? ?? 'missed'),
      durationSecs: data['duration_secs'] as int?,
      endedByUserId: data['ended_by_user_id'] as int?,
      callId: data['call_id'] as String?,
    );
  } catch (_) {
    return const CallLogInfo(media: 'audio', outcome: 'missed');
  }
}

String formatCallDuration(int secs) {
  final m = secs ~/ 60;
  final s = secs % 60;
  if (m == 0) return '$s secs';
  return '$m min ${s.toString().padLeft(2, '0')} secs';
}

String _mediaKind(CallLogInfo info, {required bool missedLabel}) {
  if (info.isVideo) {
    return missedLabel ? 'Missed video call' : 'Video call';
  }
  return missedLabel ? 'Missed voice call' : 'Voice call';
}

String _outcomeHeadline(CallLogInfo info) {
  switch (info.outcome) {
    case 'answered':
      return _mediaKind(info, missedLabel: false);
    case 'rejected':
      return info.isVideo ? 'Declined video call' : 'Declined voice call';
    case 'busy':
      return info.isVideo ? 'Busy · video call' : 'Busy · voice call';
    case 'cancelled':
      return info.isVideo ? 'Cancelled video call' : 'Cancelled voice call';
    case 'unreachable':
      return info.isVideo
          ? 'Unavailable · video call'
          : 'Unavailable · voice call';
    case 'missed':
      return _mediaKind(info, missedLabel: true);
    default:
      return _mediaKind(info, missedLabel: info.isNegative);
  }
}

String? _endedBySuffix(
  CallLogInfo info, {
  int? viewerUserId,
  String? endedByName,
}) {
  if (info.endedByUserId == null) return null;
  if (info.outcome != 'answered') return null;
  if (viewerUserId != null && info.endedByUserId == viewerUserId) {
    return 'You ended';
  }
  final name = endedByName?.trim();
  if (name != null && name.isNotEmpty) {
    return '$name ended';
  }
  return 'Call ended';
}

/// One-line preview for inbox, starred, search, and notifications.
String formatCallLogPreview(
  CallLogInfo info, {
  int? viewerUserId,
  String? endedByName,
  bool includeEndedBy = false,
}) {
  final parts = <String>[_outcomeHeadline(info)];
  if (info.outcome == 'answered' && info.durationSecs != null) {
    parts.add(formatCallDuration(info.durationSecs!));
  }
  if (includeEndedBy) {
    final ended = _endedBySuffix(
      info,
      viewerUserId: viewerUserId,
      endedByName: endedByName,
    );
    if (ended != null) parts.add(ended);
  }
  return parts.join(' · ');
}

/// Chat transcript label (includes duration and who ended when present).
String formatCallLogTranscript(
  CallLogInfo info, {
  int? viewerUserId,
  String? endedByName,
}) => formatCallLogPreview(
  info,
  viewerUserId: viewerUserId,
  endedByName: endedByName,
  includeEndedBy: true,
);

/// Icon for call-log rows; color is chosen by the caller from theme.
IconData callLogIcon(CallLogInfo info) {
  if (info.isNegative) {
    return info.isVideo
        ? Icons.videocam_off_rounded
        : Icons.phone_missed_rounded;
  }
  return info.isVideo ? Icons.videocam_rounded : Icons.call_rounded;
}
