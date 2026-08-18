import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Local use-counts for reaction emoji so the picker can surface "frequent".
class ReactionFreqStore {
  static const _key = 'reaction_freq_v1';

  static Future<Map<String, int>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in decoded.entries) e.key: (e.value as num?)?.toInt() ?? 0,
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> record(String emoji) async {
    final prefs = await SharedPreferences.getInstance();
    final counts = await load();
    counts[emoji] = (counts[emoji] ?? 0) + 1;
    await prefs.setString(_key, jsonEncode(counts));
  }

  /// Up to [limit] most-used emoji, falling back to [fallback] when empty.
  static Future<List<String>> frequent({
    int limit = 6,
    List<String> fallback = const [],
  }) async {
    final counts = await load();
    if (counts.isEmpty) return fallback.take(limit).toList();
    final ranked = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final out = <String>[];
    for (final e in ranked) {
      if (out.length >= limit) break;
      out.add(e.key);
    }
    for (final e in fallback) {
      if (out.length >= limit) break;
      if (!out.contains(e)) out.add(e);
    }
    return out;
  }
}
