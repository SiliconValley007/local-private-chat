import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One unsent text or list that must survive a process death.
///
/// Attachments already retry in place because the file is still on disk for
/// that send. A typed message has nowhere to live except this queue, so it is
/// written down before the request leaves and forgotten only once the server
/// has accepted it.
class OutboxItem {
  const OutboxItem({
    required this.clientId,
    required this.conversationId,
    required this.body,
    required this.createdAt,
    this.type = 'text',
    this.replyToMessageId,
  });

  final String clientId;
  final int conversationId;
  final String type;
  final String body;
  final int? replyToMessageId;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'client_id': clientId,
    'conversation_id': conversationId,
    'type': type,
    'body': body,
    'reply_to_message_id': replyToMessageId,
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  factory OutboxItem.fromJson(Map<String, dynamic> json) {
    return OutboxItem(
      clientId: json['client_id'] as String,
      conversationId: json['conversation_id'] as int,
      type: json['type'] as String? ?? 'text',
      body: json['body'] as String,
      replyToMessageId: json['reply_to_message_id'] as int?,
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
    );
  }
}

/// Caps the queue so a phone that was offline for days cannot grow forever.
const int outboxCap = 100;

class OutboxStore {
  const OutboxStore._();

  static String _keyFor(int userId) => 'outbox_v1_$userId';

  static Future<List<OutboxItem>> load(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyFor(userId));
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return [
        for (final row in decoded)
          OutboxItem.fromJson(row as Map<String, dynamic>),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> save(int userId, List<OutboxItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = items.length > outboxCap
        ? items.sublist(items.length - outboxCap)
        : items;
    if (trimmed.isEmpty) {
      await prefs.remove(_keyFor(userId));
      return;
    }
    await prefs.setString(
      _keyFor(userId),
      jsonEncode([for (final item in trimmed) item.toJson()]),
    );
  }

  static Future<void> enqueue(int userId, OutboxItem item) async {
    final all = [...await load(userId)];
    if (all.any((e) => e.clientId == item.clientId)) return;
    all.add(item);
    await save(userId, all);
  }

  static Future<void> remove(int userId, String clientId) async {
    final all = await load(userId);
    final next = [
      for (final item in all)
        if (item.clientId != clientId) item,
    ];
    if (next.length == all.length) return;
    await save(userId, next);
  }
}
