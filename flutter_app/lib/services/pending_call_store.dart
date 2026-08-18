import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Metadata for an incoming call that arrived while the app was away.
class PendingCall {
  const PendingCall({
    required this.callId,
    required this.conversationId,
    required this.media,
    required this.callerId,
    required this.callerName,
    required this.callerUsername,
  });

  final String callId;
  final int conversationId;
  final String media;
  final int callerId;
  final String callerName;
  final String callerUsername;

  Map<String, dynamic> toJson() => {
    'call_id': callId,
    'conversation_id': conversationId,
    'media': media,
    'caller_id': callerId,
    'caller_name': callerName,
    'caller_username': callerUsername,
  };

  factory PendingCall.fromJson(Map<String, dynamic> json) => PendingCall(
    callId: '${json['call_id'] ?? ''}',
    conversationId: json['conversation_id'] as int? ?? 0,
    media: '${json['media'] ?? 'audio'}',
    callerId: json['caller_id'] as int? ?? 0,
    callerName: '${json['caller_name'] ?? 'Incoming call'}',
    callerUsername: '${json['caller_username'] ?? ''}',
  );

  factory PendingCall.fromPushData(Map<String, dynamic> data) => PendingCall(
    callId: '${data['call_id'] ?? ''}',
    conversationId: int.tryParse('${data['conversation_id'] ?? ''}') ?? 0,
    media: '${data['media'] ?? 'audio'}',
    callerId: int.tryParse('${data['caller_id'] ?? ''}') ?? 0,
    callerName: '${data['caller_name'] ?? 'Incoming call'}',
    callerUsername: '${data['caller_username'] ?? ''}',
  );

  factory PendingCall.fromServer(
    Map<String, dynamic> data, {
    String? callerName,
    String? callerUsername,
  }) => PendingCall(
    callId: '${data['call_id'] ?? ''}',
    conversationId: data['conversation_id'] as int? ?? 0,
    media: '${data['media'] ?? 'audio'}',
    callerId: data['caller_id'] as int? ?? 0,
    callerName: callerName ?? '${data['caller_name'] ?? 'Incoming call'}',
    callerUsername: callerUsername ?? '${data['caller_username'] ?? ''}',
  );
}

/// Persists one pending call across process death (notification tap path).
class PendingCallStore {
  PendingCallStore._();
  static final instance = PendingCallStore._();

  static const _key = 'pending_call_v1';

  Future<void> save(PendingCall call) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(call.toJson()));
  }

  Future<PendingCall?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return PendingCall.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
