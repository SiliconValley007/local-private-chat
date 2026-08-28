import 'models.dart';

/// Copy for attachment timers: files leave the server, not the whole bubble.
String deletesFromServerLabel(DateTime expiresAt, {DateTime? now}) {
  final start = now ?? DateTime.now();
  final days = expiresAt.difference(start).inDays;
  if (days <= 0) return 'Deletes from the server today';
  if (days == 1) return 'Deletes from the server in 1 day';
  return 'Deletes from the server in $days days';
}

String removedFromServerLabel(int? ttlDays) {
  final days = ttlDays ?? 30;
  if (days <= 1) return 'Removed from the server after 1 day.';
  return 'Removed from the server after $days days.';
}

String keptOnServerLabel({
  required List<MediaRetainer> retainers,
  required int? meId,
}) {
  if (retainers.isEmpty) return '';
  final names = retainers
      .map((r) => meId != null && r.userId == meId ? 'You' : r.displayName)
      .toList();
  if (names.length == 1) return 'Kept on the server by ${names.single}.';
  if (names.length == 2) {
    return 'Kept on the server by ${names[0]} and ${names[1]}.';
  }
  final rest = names.length - 1;
  return 'Kept on the server by ${names.first} and $rest others.';
}

String? mediaStatusCaption(
  ChatMessage message, {
  required int? meId,
  required bool keptOnPhone,
}) {
  if (!message.isMediaType || message.isDeleted) return null;
  if (message.mediaGone) {
    if (keptOnPhone) return 'Playing from phone storage.';
    return removedFromServerLabel(message.mediaTtlDays);
  }
  return null;
}

String compactRemainingLabel(DateTime expiresAt, {DateTime? now}) {
  final left = expiresAt.difference(now ?? DateTime.now());
  if (left.isNegative) return 'Expired';
  if (left.inDays >= 1) return '${left.inDays}d';
  if (left.inHours >= 1) return '${left.inHours}h';
  if (left.inMinutes >= 1) return '${left.inMinutes}m';
  return '<1m';
}

String formatMediaTtlNotice({
  required String who,
  required Object fromDays,
  required Object toDays,
  String? whenLabel,
}) {
  final core =
      '$who changed attachment expiry from $fromDays days to $toDays days';
  if (whenLabel == null || whenLabel.isEmpty) return core;
  return '$core · $whenLabel';
}

String composerMediaTimerLabel(MediaPolicy? policy) {
  final days = policy?.effectiveDays ?? 30;
  if (days <= 1) return 'New photos and videos leave the server in 1 day.';
  return 'New photos and videos leave the server in $days days.';
}
