import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Parsing and display of server timestamps.
///
/// Two rules keep clocks honest here:
///  * everything from the server is UTC, so it is parsed as UTC even when the
///    string carries no zone marker, and
///  * everything shown to a person is converted to their local time and
///    formatted with the 12/24-hour style their phone is set to.

/// True when the string already says which zone it is in.
bool _hasZoneMarker(String raw) {
  if (raw.endsWith('Z') || raw.endsWith('z')) return true;
  // Look for +HH:MM / -HH:MM after the time part, not the date's own dashes.
  final timeStart = raw.indexOf('T');
  if (timeStart < 0) return false;
  final time = raw.substring(timeStart);
  return time.contains('+') || time.contains('-');
}

/// Parses a server timestamp, treating a zone-less value as UTC.
///
/// Dart reads "2026-08-11T05:53:12" as *local* time, so without this an 11:23
/// IST message was displayed as 05:53.
DateTime parseServerTime(String raw) {
  final text = raw.trim();
  return DateTime.parse(_hasZoneMarker(text) ? text : '${text}Z').toUtc();
}

DateTime? tryParseServerTime(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  try {
    return parseServerTime(raw);
  } catch (_) {
    return null;
  }
}

/// Whether this phone is set to a 24-hour clock.
bool _uses24Hour(BuildContext context) =>
    MediaQuery.of(context).alwaysUse24HourFormat;

/// "5:53 PM" or "17:53", matching the phone's clock setting.
String formatClockTime(BuildContext context, DateTime when) {
  final local = when.toLocal();
  return _uses24Hour(context)
      ? DateFormat.Hm().format(local)
      : DateFormat.jm().format(local);
}

/// Day heading inside a conversation: Today, Yesterday, a weekday, or a date.
String formatDayLabel(DateTime when) {
  final local = when.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(local.year, local.month, local.day);
  final days = today.difference(that).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return DateFormat.EEEE().format(local);
  if (local.year == now.year) return DateFormat('d MMMM').format(local);
  return DateFormat('d MMMM y').format(local);
}

/// Gallery section heading: "MAY", or "MAY 2025" when not this year.
String formatMonthHeading(DateTime when) {
  final local = when.toLocal();
  final now = DateTime.now();
  if (local.year == now.year) {
    return DateFormat.MMMM().format(local).toUpperCase();
  }
  return DateFormat.yMMMM().format(local).toUpperCase();
}

/// Compact gallery date stamp: 14/05/26
String formatShortDate(DateTime when) {
  return DateFormat('dd/MM/yy').format(when.toLocal());
}

/// Right-hand timestamp in the chat list.
String formatListTimestamp(BuildContext context, DateTime when) {
  final local = when.toLocal();
  final now = DateTime.now();
  final sameDay =
      local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  if (sameDay) return formatClockTime(context, when);
  if (now.difference(local).inDays < 7) return DateFormat.E().format(local);
  return DateFormat.MMMd().format(local);
}

/// A moment in the reader's own timezone, with the day spelled out:
/// "today at 5:53 PM", "tomorrow at 5:53 PM", "Thursday at 5:53 PM",
/// "18 Aug at 5:53 PM".
String formatMomentWithDay(BuildContext context, DateTime when) {
  final local = when.toLocal();
  final now = DateTime.now();
  final days = DateTime(
    local.year,
    local.month,
    local.day,
  ).difference(DateTime(now.year, now.month, now.day)).inDays;
  final clock = formatClockTime(context, when);
  if (days == 0) return 'today at $clock';
  if (days == 1) return 'tomorrow at $clock';
  if (days == -1) return 'yesterday at $clock';
  if (days > 1 && days < 7) {
    return '${DateFormat.EEEE().format(local)} at $clock';
  }
  if (local.year == now.year) {
    return '${DateFormat('d MMM').format(local)} at $clock';
  }
  return '${DateFormat('d MMM y').format(local)} at $clock';
}

/// When a disappearing message goes, in words: "Disappears tomorrow at 7:41 AM".
///
/// The timer icon alone only says that a message is on a clock, not which one,
/// so anyone who forgot the setting had no way to find out.
String formatDisappearsAt(BuildContext context, DateTime when) =>
    'Disappears ${formatMomentWithDay(context, when)}';

/// "last seen today at 5:53 PM" — spelled out, because a bare "05:53" told the
/// user neither which day nor whether it was morning or evening.
String formatLastSeen(BuildContext context, DateTime when) {
  final local = when.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(local.year, local.month, local.day);
  final days = today.difference(that).inDays;
  final clock = formatClockTime(context, when);

  if (days == 0) {
    final minutes = now.difference(local).inMinutes;
    if (minutes < 1) return 'last seen just now';
    if (minutes < 60) {
      return 'last seen $minutes minute${minutes == 1 ? '' : 's'} ago';
    }
    return 'last seen today at $clock';
  }
  if (days == 1) return 'last seen yesterday at $clock';
  if (days < 7) return 'last seen ${DateFormat.EEEE().format(local)} at $clock';
  if (local.year == now.year) {
    return 'last seen ${DateFormat('d MMM').format(local)} at $clock';
  }
  return 'last seen ${DateFormat('d MMM y').format(local)}';
}
