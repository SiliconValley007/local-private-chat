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
