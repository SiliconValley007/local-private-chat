import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/services/contacts_store.dart';
import 'package:local_chat/services/notification_service.dart';
import 'package:local_chat/time_format.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// intl separates the time from AM/PM with a narrow no-break space; compare on
/// plain spaces so the expectations stay readable.
String _plain(String value) => value.replaceAll('\u202f', ' ');

/// Formats [when] with the clock style the phone is set to.
Future<String> _clock(
  WidgetTester tester,
  DateTime when, {
  required bool use24Hour,
}) async {
  var result = '';
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(alwaysUse24HourFormat: use24Hour),
      child: Builder(
        builder: (context) {
          result = _plain(formatClockTime(context, when));
          return const SizedBox();
        },
      ),
    ),
  );
  return result;
}

void main() {
  group('server timestamps', () {
    test('a zone-less string is read as UTC, not local time', () {
      final parsed = parseServerTime('2026-08-11T05:53:12.732591');
      expect(parsed.isUtc, isTrue);
      expect(parsed, DateTime.utc(2026, 8, 11, 5, 53, 12, 732, 591));
    });

    test('an explicit Z is honoured', () {
      expect(
        parseServerTime('2026-08-11T05:53:12Z'),
        DateTime.utc(2026, 8, 11, 5, 53, 12),
      );
    });

    test('an offset is converted to UTC', () {
      expect(
        parseServerTime('2026-08-11T11:23:12+05:30'),
        DateTime.utc(2026, 8, 11, 5, 53, 12),
      );
    });

    test('junk and empty values fall back to null', () {
      expect(tryParseServerTime(null), isNull);
      expect(tryParseServerTime(''), isNull);
      expect(tryParseServerTime('not a date'), isNull);
    });
  });

  group('clock display', () {
    testWidgets('12-hour phones get an AM/PM marker', (tester) async {
      final morning = DateTime(2026, 8, 11, 5, 53).toUtc();
      final evening = DateTime(2026, 8, 11, 17, 53).toUtc();
      expect(await _clock(tester, morning, use24Hour: false), '5:53 AM');
      expect(await _clock(tester, evening, use24Hour: false), '5:53 PM');
    });

    testWidgets('24-hour phones keep the 24-hour clock', (tester) async {
      final evening = DateTime(2026, 8, 11, 17, 53).toUtc();
      expect(await _clock(tester, evening, use24Hour: true), '17:53');
    });

    testWidgets('last seen names the day and the meridiem', (tester) async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final when = DateTime(
        yesterday.year,
        yesterday.month,
        yesterday.day,
        17,
        53,
      ).toUtc();
      var label = '';
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(alwaysUse24HourFormat: false),
          child: Builder(
            builder: (context) {
              label = _plain(formatLastSeen(context, when));
              return const SizedBox();
            },
          ),
        ),
      );
      expect(label, 'last seen yesterday at 5:53 PM');
    });

    testWidgets('a few minutes ago reads as minutes, not a clock time', (
      tester,
    ) async {
      final when = DateTime.now().subtract(const Duration(minutes: 5)).toUtc();
      var label = '';
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(alwaysUse24HourFormat: false),
          child: Builder(
            builder: (context) {
              label = formatLastSeen(context, when);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(label, 'last seen 5 minutes ago');
    });

    test('day headings say Today and Yesterday', () {
      expect(formatDayLabel(DateTime.now().toUtc()), 'Today');
      expect(
        formatDayLabel(
          DateTime.now().subtract(const Duration(days: 1)).toUtc(),
        ),
        'Yesterday',
      );
    });
  });

  group('renaming people', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a nickname is saved and read back', () async {
      final store = ContactsStore();
      await store.setAlias('faye', 'Riya from work');
      expect(await store.aliases(), {'faye': 'Riya from work'});
    });

    test('blank names clear the nickname', () async {
      final store = ContactsStore();
      await store.setAlias('faye', 'Riya from work');
      await store.setAlias('faye', '   ');
      expect(await store.aliases(), isEmpty);
    });

    test('names are trimmed', () async {
      final store = ContactsStore();
      await store.setAlias('faye', '  Riya  ');
      expect((await store.aliases())['faye'], 'Riya');
    });

    test('a restored backup merges over what is already here', () async {
      final store = ContactsStore();
      await store.setAlias('faye', 'Riya');
      final merged = await store.mergeAliases({
        'faye': 'Riya from work',
        'bob': 'Landlord',
      });
      expect(merged, {'faye': 'Riya from work', 'bob': 'Landlord'});
      expect(await store.aliases(), merged);
    });

    test('push notifications use the private local name', () async {
      final store = ContactsStore();
      await store.setAlias('faye', 'Riya from work');

      final title = await NotificationService.instance.notificationTitleFromData({
        'sender_username': 'faye',
        'sender_name': 'Faye',
      });

      expect(title, 'Riya from work');
    });

    test('push notifications fall back to the server name', () async {
      final title = await NotificationService.instance.notificationTitleFromData({
        'sender_username': 'unknown',
        'sender_name': 'Unknown Person',
      });

      expect(title, 'Unknown Person');
    });
  });
}
