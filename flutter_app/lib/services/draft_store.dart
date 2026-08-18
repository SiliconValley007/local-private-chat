import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Unsent composer text keyed by conversation id. Cleared when a message sends.
class DraftStore {
  static const _key = 'composer_drafts_v1';

  static Future<Map<int, String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in decoded.entries)
          if ((e.value as String?)?.trim().isNotEmpty == true)
            int.parse(e.key): e.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(Map<int, String> all) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = {
      for (final e in all.entries)
        if (e.value.trim().isNotEmpty) e.key.toString(): e.value,
    };
    await prefs.setString(_key, jsonEncode(encoded));
  }

  static Future<void> setDraft(int conversationId, String text) async {
    final all = await load();
    final trimmed = text.trimRight();
    if (trimmed.isEmpty) {
      all.remove(conversationId);
    } else {
      all[conversationId] = text;
    }
    await save(all);
  }

  static Future<String?> getDraft(int conversationId) async {
    final all = await load();
    return all[conversationId];
  }

  static Future<void> clearDraft(int conversationId) async {
    final all = await load();
    if (all.remove(conversationId) != null) await save(all);
  }
}
