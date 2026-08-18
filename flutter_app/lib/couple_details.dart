class AnniversaryCountdown {
  const AnniversaryCountdown({required this.days});

  final int days;
  bool get isToday => days == 0;

  String get label {
    if (isToday) return 'Happy anniversary!';
    if (days == 1) return 'Anniversary tomorrow';
    return '$days days to anniversary';
  }
}

/// Treats an anniversary as a recurring month/day, regardless of stored year.
AnniversaryCountdown? anniversaryCountdown(String? raw, {DateTime? from}) {
  if (raw == null) return null;
  final date = DateTime.tryParse(raw);
  if (date == null) return null;
  final clock = from ?? DateTime.now();
  final today = DateTime(clock.year, clock.month, clock.day);
  var next = DateTime(clock.year, date.month, date.day);
  if (next.isBefore(today)) {
    next = DateTime(clock.year + 1, date.month, date.day);
  }
  return AnniversaryCountdown(days: next.difference(today).inDays);
}

/// Wording for the chat menu's anniversary entry.
class CoupleMenuLabel {
  const CoupleMenuLabel({required this.title, required this.subtitle});

  final String title;
  final String subtitle;
}

/// Does this chat offer the anniversary entry at all?
///
/// Every one-to-one chat does, whether or not it has been switched on — a chat
/// that has never been asked is the one that needs a way to answer. Group chats
/// have no couple to speak of.
bool offersCoupleDetails(String conversationType) => conversationType == 'dm';

/// What the couple sheet says about the streak, including when there isn't one.
class StreakLines {
  const StreakLines({required this.title, required this.subtitle});

  final String title;
  final String subtitle;
}

/// Wording for the streak row.
///
/// A count of zero used to hide the row altogether, which read as the streak
/// having been removed from the app rather than simply not being under way. It
/// now says so, and says what starts one.
StreakLines streakLines(int days) {
  if (days <= 0) {
    return const StreakLines(
      title: 'No streak yet',
      subtitle: 'A streak starts on a day you both send a message.',
    );
  }
  return StreakLines(
    title: days == 1 ? '1-day streak' : '$days-day streak',
    subtitle: 'A day counts when both of you send a message.',
  );
}

/// Names the menu entry after what it does while it is switched off, so a chat
/// with a parent in it shows nothing more suggestive than a date reminder.
CoupleMenuLabel coupleMenuLabel({
  required bool enabled,
  required int streakDays,
  AnniversaryCountdown? countdown,
}) {
  if (!enabled) {
    return const CoupleMenuLabel(
      title: 'Anniversary and streak',
      subtitle: 'Off',
    );
  }
  return CoupleMenuLabel(
    title: streakDays > 0
        ? 'Couple details · $streakDays-day streak'
        : 'Couple details',
    subtitle: countdown?.label ?? 'On',
  );
}
