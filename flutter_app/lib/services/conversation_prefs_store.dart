import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Per-conversation preferences that live only on this phone.
///
/// Pin and mute are never sent to the server — they are personal, like contact
/// nicknames. Survives restarts until the app is uninstalled.
class ConversationPrefs {
  const ConversationPrefs({
    this.pinned = false,
    this.muted = false,
    this.coupleDetailsEnabled = false,
  });

  final bool pinned;
  final bool muted;
  final bool coupleDetailsEnabled;

  ConversationPrefs copyWith({
    bool? pinned,
    bool? muted,
    bool? coupleDetailsEnabled,
  }) => ConversationPrefs(
    pinned: pinned ?? this.pinned,
    muted: muted ?? this.muted,
    coupleDetailsEnabled: coupleDetailsEnabled ?? this.coupleDetailsEnabled,
  );

  Map<String, dynamic> toJson() => {
    'pinned': pinned,
    'muted': muted,
    'couple_details_enabled': coupleDetailsEnabled,
  };

  factory ConversationPrefs.fromJson(Map<String, dynamic> json) =>
      ConversationPrefs(
        pinned: json['pinned'] as bool? ?? false,
        muted: json['muted'] as bool? ?? false,
        coupleDetailsEnabled: json['couple_details_enabled'] as bool? ?? false,
      );
}

class ConversationPrefsStore {
  static const _key = 'conversation_prefs_v1';

  static Future<Map<int, ConversationPrefs>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in decoded.entries)
          int.parse(e.key): ConversationPrefs.fromJson(
            e.value as Map<String, dynamic>,
          ),
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(Map<int, ConversationPrefs> all) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = {
      for (final e in all.entries) e.key.toString(): e.value.toJson(),
    };
    await prefs.setString(_key, jsonEncode(encoded));
  }
}
