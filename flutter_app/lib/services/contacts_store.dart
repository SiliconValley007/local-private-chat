import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class LocalContact {
  LocalContact({
    required this.userId,
    required this.username,
    required this.displayName,
  });

  final int userId;
  final String username;
  final String displayName;

  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'username': username,
    'display_name': displayName,
  };

  factory LocalContact.fromJson(Map<String, dynamic> json) => LocalContact(
    userId: json['user_id'] as int,
    username: json['username'] as String,
    displayName: json['display_name'] as String,
  );
}

/// Device-local address book plus the nicknames you gave people.
///
/// Nicknames are keyed by username rather than user id because that is what a
/// restored backup can always match on, and they are kept apart from the saved
/// contacts so you can rename someone you never saved.
class ContactsStore {
  static const _key = 'local_contacts_v1';
  static const _aliasKey = 'contact_aliases_v1';

  /// username -> the name you chose for that person on this phone.
  Future<Map<String, String>> aliases() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_aliasKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final entry in decoded.entries)
          if ('${entry.value}'.trim().isNotEmpty)
            entry.key: '${entry.value}'.trim(),
      };
    } catch (_) {
      return {};
    }
  }

  /// Stores a nickname, or clears it when [alias] is null or blank.
  Future<Map<String, String>> setAlias(String username, String? alias) async {
    final next = await aliases();
    final trimmed = alias?.trim() ?? '';
    if (trimmed.isEmpty) {
      next.remove(username);
    } else {
      next[username] = trimmed;
    }
    await _writeAliases(next);
    return next;
  }

  /// Merges nicknames from a restored backup over whatever is on this phone.
  Future<Map<String, String>> mergeAliases(Map<String, String> incoming) async {
    final next = await aliases();
    next.addAll(incoming);
    await _writeAliases(next);
    return next;
  }

  Future<void> _writeAliases(Map<String, String> values) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_aliasKey, jsonEncode(values));
  }

  Future<List<LocalContact>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => LocalContact.fromJson(e as Map<String, dynamic>))
        .toList()
      ..sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );
  }

  Future<void> upsert(LocalContact contact) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await list();
    final next = [
      for (final c in current)
        if (c.userId != contact.userId && c.username != contact.username) c,
      contact,
    ];
    await prefs.setString(
      _key,
      jsonEncode(next.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> remove(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    final next = [
      for (final c in await list())
        if (c.userId != userId) c,
    ];
    await prefs.setString(
      _key,
      jsonEncode(next.map((e) => e.toJson()).toList()),
    );
  }
}
