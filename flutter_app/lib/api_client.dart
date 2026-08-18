import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';
import 'errors.dart';
import 'models.dart';
import 'nudge_log.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient();

  static const _tokenKey = 'auth_token';
  static const _baseUrlKey = 'base_url';
  static const _userKey = 'user_json';
  static const _requestTimeout = Duration(seconds: 20);
  static const _uploadTimeout = Duration(minutes: 3);

  final _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  String? baseUrl;
  String? token;
  ChatUser? currentUser;

  Future<void> loadPersisted() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString(_baseUrlKey)?.trim();
    if (savedUrl == null || savedUrl.isEmpty) {
      baseUrl = AppConfig.defaultServerUrl;
      await prefs.setString(_baseUrlKey, baseUrl!);
    } else {
      baseUrl = savedUrl.replaceAll(RegExp(r'/+$'), '');
    }

    token = await _secure.read(key: _tokenKey);
    final userJson = prefs.getString(_userKey);
    if (token != null && token!.isNotEmpty && userJson != null) {
      try {
        currentUser = ChatUser.fromJson(
          jsonDecode(userJson) as Map<String, dynamic>,
        );
      } catch (_) {
        currentUser = null;
        token = null;
        await _secure.delete(key: _tokenKey);
        await prefs.remove(_userKey);
      }
    } else {
      // Incomplete session — force clean login
      token = null;
      currentUser = null;
    }
  }

  Future<void> setBaseUrl(String url) async {
    baseUrl = url.replaceAll(RegExp(r'/+$'), '');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, baseUrl!);
  }

  Future<void> resetServerUrlToDefault() async {
    await setBaseUrl(AppConfig.defaultServerUrl);
  }

  Future<void> _persistAuth(String newToken, ChatUser user) async {
    token = newToken;
    currentUser = user;
    await _secure.write(key: _tokenKey, value: newToken);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(_userToJson(user)));
  }

  Map<String, dynamic> _userToJson(ChatUser user) => {
    'id': user.id,
    'username': user.username,
    'display_name': user.displayName,
    'last_seen_at': user.lastSeenAt?.toIso8601String(),
    'is_online': user.isOnline,
    'has_avatar': user.hasAvatar,
    'avatar_version': user.avatarVersion,
    'mood': user.mood,
  };

  /// The signed-in user's id, used so parsed messages know which reactions
  /// are yours.
  int? get meId => currentUser?.id;

  Future<void> logout() async {
    token = null;
    currentUser = null;
    await _secure.delete(key: _tokenKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userKey);
  }

  Future<ChatUser> fetchMe() async {
    final res = await _send(
      () => http.get(_uri('/api/auth/me'), headers: _headers(jsonBody: false)),
    );
    final data = await _decode(res);
    final user = ChatUser.fromJson(data);
    currentUser = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(_userToJson(user)));
    return user;
  }

  /// Space available on the server volume that stores uploaded attachments.
  Future<Map<String, dynamic>> fetchServerStorage() async {
    final res = await _send(
      () => http.get(
        _uri('/api/system/storage'),
        headers: _headers(jsonBody: false),
      ),
    );
    return _decode(res);
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    if (baseUrl == null || baseUrl!.isEmpty) {
      throw ApiException(
        'No server address is set yet. Open Server settings and enter your server URL.',
      );
    }
    return Uri.parse('$baseUrl$path').replace(queryParameters: query);
  }

  Map<String, String> _headers({bool jsonBody = true}) {
    final h = <String, String>{};
    if (jsonBody) h['Content-Type'] = 'application/json';
    if (token != null) h['Authorization'] = 'Bearer $token';
    return h;
  }

  /// Runs a request and converts transport failures into readable messages.
  Future<http.Response> _send(
    Future<http.Response> Function() request, {
    Duration? timeout,
  }) async {
    try {
      return await request().timeout(timeout ?? _requestTimeout);
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(networkMessageFor(e));
    }
  }

  /// Reads a JSON reply, raising [ApiException] with a readable message on error.
  dynamic _parse(http.Response res) {
    dynamic decoded;
    if (res.body.isNotEmpty) {
      try {
        decoded = jsonDecode(res.body);
      } on FormatException {
        decoded = null;
      }
    }
    if (res.statusCode >= 400) {
      throw ApiException(
        _messageFrom(decoded, res.statusCode),
        statusCode: res.statusCode,
      );
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _decode(http.Response res) async {
    final decoded = _parse(res);
    if (decoded is Map<String, dynamic>) return decoded;
    return {};
  }

  List<dynamic> _decodeList(http.Response res) {
    final decoded = _parse(res);
    if (decoded is List) return decoded;
    throw ApiException(networkMessageFor(const FormatException()));
  }

  /// Pulls a human sentence out of an error body, whatever shape it arrives in.
  ///
  /// This server sends `{"detail": "<sentence>"}`, but a bare FastAPI or a proxy
  /// in between can still answer with a list of validation dicts or plain HTML.
  String _messageFrom(dynamic decoded, int statusCode) {
    final detail = decoded is Map<String, dynamic> ? decoded['detail'] : null;
    if (detail is String && detail.trim().isNotEmpty) return detail.trim();
    if (detail is List) {
      final parts = <String>[];
      for (final item in detail) {
        if (item is Map && item['msg'] is String) {
          var msg = (item['msg'] as String).trim();
          if (msg.startsWith('Value error, ')) {
            msg = msg.substring('Value error, '.length);
          }
          if (msg.isNotEmpty && !parts.contains(msg)) parts.add(msg);
        }
      }
      if (parts.isNotEmpty) return parts.take(3).join(' ');
    }
    return statusMessageFor(statusCode);
  }

  Future<ChatUser> register(
    String username,
    String password, {
    String? displayName,
  }) async {
    final res = await _send(
      () => http.post(
        _uri('/api/auth/register'),
        headers: _headers(),
        body: jsonEncode({
          'username': username,
          'password': password,
          if (displayName != null && displayName.isNotEmpty)
            'display_name': displayName,
        }),
      ),
    );
    final data = await _decode(res);
    final user = ChatUser.fromJson(data['user'] as Map<String, dynamic>);
    await _persistAuth(data['token'] as String, user);
    return user;
  }

  Future<ChatUser> login(String username, String password) async {
    final res = await _send(
      () => http.post(
        _uri('/api/auth/login'),
        headers: _headers(),
        body: jsonEncode({'username': username, 'password': password}),
      ),
    );
    final data = await _decode(res);
    final user = ChatUser.fromJson(data['user'] as Map<String, dynamic>);
    await _persistAuth(data['token'] as String, user);
    return user;
  }

  /// Replace the signed-in user's password. Requires the current one.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _send(
      () => http.post(
        _uri('/api/auth/change-password'),
        headers: _headers(),
        body: jsonEncode({
          'current_password': currentPassword,
          'new_password': newPassword,
        }),
      ),
    );
  }

  Future<List<ChatUser>> listUsers({String? q}) async {
    final query = (q != null && q.trim().isNotEmpty) ? {'q': q.trim()} : null;
    final res = await _send(
      () => http.get(
        _uri('/api/users', query),
        headers: _headers(jsonBody: false),
      ),
    );
    return _decodeList(
      res,
    ).map((e) => ChatUser.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<ChatUser> getUserByUsername(String username) async {
    final res = await _send(
      () => http.get(
        _uri('/api/users/by-username/${Uri.encodeComponent(username)}'),
        headers: _headers(jsonBody: false),
      ),
    );
    final data = await _decode(res);
    return ChatUser.fromJson(data);
  }

  Future<void> registerDeviceToken(
    String token, {
    String platform = 'android',
  }) async {
    final res = await _send(
      () => http.post(
        _uri('/api/devices'),
        headers: _headers(),
        body: jsonEncode({'token': token, 'platform': platform}),
      ),
    );
    await _decode(res);
  }

  Future<void> unregisterDeviceToken(String token) async {
    final res = await _send(
      () => http.delete(
        _uri('/api/devices'),
        headers: _headers(),
        body: jsonEncode({'token': token, 'platform': 'android'}),
      ),
    );
    await _decode(res);
  }

  Future<void> putBackup({
    required String ciphertextB64,
    required String saltB64,
    required String nonceB64,
  }) async {
    final res = await _send(
      () => http.put(
        _uri('/api/backup'),
        headers: _headers(),
        body: jsonEncode({
          'ciphertext_b64': ciphertextB64,
          'salt_b64': saltB64,
          'nonce_b64': nonceB64,
        }),
      ),
    );
    await _decode(res);
  }

  Future<Map<String, String>> getBackup() async {
    final res = await _send(
      () => http.get(_uri('/api/backup'), headers: _headers(jsonBody: false)),
    );
    final data = await _decode(res);
    return {
      'ciphertext_b64': data['ciphertext_b64'] as String,
      'salt_b64': data['salt_b64'] as String,
      'nonce_b64': data['nonce_b64'] as String,
      if (data['updated_at'] != null)
        'updated_at': data['updated_at'] as String,
    };
  }

  Future<List<Conversation>> listConversations() async {
    final res = await _send(
      () => http.get(
        _uri('/api/conversations'),
        headers: _headers(jsonBody: false),
      ),
    );
    return _decodeList(
      res,
    ).map((e) => Conversation.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Conversation> createDm(int userId) async {
    final res = await _send(
      () => http.post(
        _uri('/api/conversations/dm'),
        headers: _headers(),
        body: jsonEncode({'user_id': userId}),
      ),
    );
    final data = await _decode(res);
    return Conversation.fromJson(data);
  }

  Future<Conversation> createGroup(String title, List<int> memberIds) async {
    final res = await _send(
      () => http.post(
        _uri('/api/conversations/groups'),
        headers: _headers(),
        body: jsonEncode({'title': title, 'member_ids': memberIds}),
      ),
    );
    final data = await _decode(res);
    return Conversation.fromJson(data);
  }

  Future<List<ChatMessage>> listMessages(
    int conversationId, {
    int? beforeId,
    int? afterId,
  }) async {
    final query = <String, String>{'limit': '50'};
    if (beforeId != null) query['before_id'] = '$beforeId';
    if (afterId != null) query['after_id'] = '$afterId';
    final res = await _send(
      () => http.get(
        _uri('/api/conversations/$conversationId/messages', query),
        headers: _headers(jsonBody: false),
      ),
    );
    return _decodeList(res)
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>, meId: meId))
        .toList();
  }

  /// Lightweight Media / Docs / Links index for one conversation.
  Future<List<SharedItem>> listShared(
    int conversationId, {
    int? beforeId,
    int limit = 100,
  }) async {
    final query = <String, String>{'limit': '$limit'};
    if (beforeId != null) query['before_id'] = '$beforeId';
    final res = await _send(
      () => http.get(
        _uri('/api/conversations/$conversationId/shared', query),
        headers: _headers(jsonBody: false),
      ),
    );
    return _decodeList(
      res,
    ).map((e) => SharedItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<ChatMessage> sendText(
    int conversationId,
    String body, {
    String? clientId,
    int? replyToMessageId,
  }) async {
    final res = await _send(
      () => http.post(
        _uri('/api/conversations/$conversationId/messages'),
        headers: _headers(),
        body: jsonEncode({
          'type': 'text',
          'body': body,
          'client_id': ?clientId,
          'reply_to_message_id': ?replyToMessageId,
        }),
      ),
    );
    final data = await _decode(res);
    return ChatMessage.fromJson(data, meId: meId);
  }

  Future<ChatMessage> editMessage(int messageId, String body) async {
    final res = await _send(
      () => http.patch(
        _uri('/api/messages/$messageId'),
        headers: _headers(),
        body: jsonEncode({'body': body}),
      ),
    );
    final data = await _decode(res);
    return ChatMessage.fromJson(data, meId: meId);
  }

  /// Deletes a message. [scope] is `everyone` (tombstone for all) or `me`
  /// (hidden only on this account).
  Future<ChatMessage> deleteMessage(
    int messageId, {
    String scope = 'everyone',
  }) async {
    final res = await _send(
      () => http.delete(
        _uri('/api/messages/$messageId', {'scope': scope}),
        headers: _headers(jsonBody: false),
      ),
    );
    final data = await _decode(res);
    return ChatMessage.fromJson(data, meId: meId);
  }

  /// Sets or replaces your emoji reaction on a message.
  Future<ChatMessage> reactToMessage(int messageId, String emoji) async {
    final res = await _send(
      () => http.put(
        _uri('/api/messages/$messageId/reactions'),
        headers: _headers(),
        body: jsonEncode({'emoji': emoji}),
      ),
    );
    final data = await _decode(res);
    return ChatMessage.fromJson(data, meId: meId);
  }

  /// Removes your reaction from a message.
  Future<ChatMessage> removeReaction(int messageId) async {
    final res = await _send(
      () => http.delete(
        _uri('/api/messages/$messageId/reactions'),
        headers: _headers(jsonBody: false),
      ),
    );
    final data = await _decode(res);
    return ChatMessage.fromJson(data, meId: meId);
  }

  /// Records a call-log entry ("Video call · 21 secs" / "Missed call").
  Future<ChatMessage> postCallLog(
    int conversationId, {
    required String media,
    required String outcome,
    int? durationSecs,
  }) async {
    final res = await _send(
      () => http.post(
        _uri('/api/conversations/$conversationId/call-log'),
        headers: _headers(),
        body: jsonEncode({
          'media': media,
          'outcome': outcome,
          'duration_secs': ?durationSecs,
        }),
      ),
    );
    final data = await _decode(res);
    return ChatMessage.fromJson(data, meId: meId);
  }

  /// Unanswered invites for this user (callee recovery after app open).
  Future<List<Map<String, dynamic>>> fetchPendingCalls() async {
    final res = await _send(
      () => http.get(
        _uri('/api/calls/pending'),
        headers: _headers(jsonBody: false),
      ),
    );
    final data = await _decode(res);
    final rows = data['calls'];
    if (rows is! List) return const [];
    return rows.cast<Map<String, dynamic>>();
  }

  /// REST path for callee ringing acknowledgement when WS is not yet up.
  Future<void> ackCallRinging(String callId) async {
    await _send(
      () => http.post(
        _uri('/api/calls/ringing'),
        headers: _headers(),
        body: jsonEncode({'call_id': callId}),
      ),
    );
  }

  Future<List<ChatMessage>> searchMessages(
    String query, {
    int? conversationId,
    int? senderId,
    String? mediaType,
    DateTime? before,
    DateTime? after,
    int limit = 50,
  }) async {
    final params = <String, String>{'limit': '$limit'};
    if (query.trim().isNotEmpty) params['q'] = query.trim();
    if (conversationId != null) {
      params['conversation_id'] = '$conversationId';
    }
    if (senderId != null) params['sender_id'] = '$senderId';
    if (mediaType != null && mediaType.isNotEmpty) {
      params['media_type'] = mediaType;
    }
    if (before != null) params['before'] = before.toUtc().toIso8601String();
    if (after != null) params['after'] = after.toUtc().toIso8601String();
    final res = await _send(
      () => http.get(
        _uri('/api/messages/search', params),
        headers: _headers(jsonBody: false),
      ),
    );
    return _decodeList(res)
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>, meId: meId))
        .toList();
  }

  Future<List<ChatMessage>> listPins(int conversationId) async {
    final res = await _send(
      () => http.get(
        _uri('/api/conversations/$conversationId/pins'),
        headers: _headers(jsonBody: false),
      ),
    );
    return _decodeList(res)
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>, meId: meId))
        .toList();
  }

  Future<ChatMessage> pinMessage(int messageId) async {
    final res = await _send(
      () => http.put(
        _uri('/api/messages/$messageId/pin'),
        headers: _headers(jsonBody: false),
      ),
    );
    final data = await _decode(res);
    return ChatMessage.fromJson(data, meId: meId);
  }

  Future<void> unpinMessage(int messageId) async {
    await _send(
      () => http.delete(
        _uri('/api/messages/$messageId/pin'),
        headers: _headers(jsonBody: false),
      ),
    );
  }

  Future<List<NudgeRecord>> listNudges(
    int conversationId, {
    String? before,
    String? beforeId,
    int limit = 50,
  }) async {
    final query = <String, String>{
      'limit': '$limit',
      'before': ?before,
      'before_id': ?beforeId,
    };
    final res = await _send(
      () => http.get(
        _uri('/api/conversations/$conversationId/nudges', query),
        headers: _headers(jsonBody: false),
      ),
    );
    return _decodeList(res)
        .map((e) => NudgeRecord.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<ChatMessage>> listStarred({
    int? beforeStarId,
    int limit = 50,
  }) async {
    final query = <String, String>{
      'limit': '$limit',
      if (beforeStarId != null) 'before_star_id': '$beforeStarId',
    };
    final res = await _send(
      () => http.get(
        _uri('/api/messages/starred', query),
        headers: _headers(jsonBody: false),
      ),
    );
    return _decodeList(res)
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>, meId: meId))
        .toList();
  }

  Future<ChatMessage> starMessage(int messageId) async {
    final res = await _send(
      () => http.put(
        _uri('/api/messages/$messageId/star'),
        headers: _headers(jsonBody: false),
      ),
    );
    final data = await _decode(res);
    return ChatMessage.fromJson(data, meId: meId);
  }

  Future<void> unstarMessage(int messageId) async {
    await _send(
      () => http.delete(
        _uri('/api/messages/$messageId/star'),
        headers: _headers(jsonBody: false),
      ),
    );
  }

  /// Receipts are housekeeping: a failure here must never surface to the user.
  Future<void> markRead(int conversationId) async {
    try {
      await _send(
        () => http.post(
          _uri('/api/conversations/$conversationId/read'),
          headers: _headers(jsonBody: false),
        ),
      );
    } on ApiException {
      return;
    }
  }

  Future<void> markDelivered(int messageId) async {
    try {
      await _send(
        () => http.post(
          _uri('/api/messages/$messageId/delivered'),
          headers: _headers(jsonBody: false),
        ),
      );
    } on ApiException {
      return;
    }
  }

  Future<ChatMessage> uploadMedia({
    required int conversationId,
    required File file,
    required String type,
    File? thumbnail,
    int? durationMs,
    String? caption,
    String? clientId,
    int? replyToMessageId,
  }) async {
    final req = http.MultipartRequest(
      'POST',
      _uri('/api/conversations/$conversationId/media'),
    );
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    req.fields['type'] = type;
    if (caption != null && caption.isNotEmpty) req.fields['caption'] = caption;
    if (clientId != null) req.fields['client_id'] = clientId;
    if (replyToMessageId != null) {
      req.fields['reply_to_message_id'] = '$replyToMessageId';
    }
    if (durationMs != null && durationMs > 0) {
      req.fields['duration_ms'] = '$durationMs';
    }
    req.files.add(await http.MultipartFile.fromPath('file', file.path));
    if (thumbnail != null) {
      req.files.add(
        await http.MultipartFile.fromPath(
          'thumbnail',
          thumbnail.path,
          filename: 'preview.jpg',
        ),
      );
    }
    final res = await _send(
      () async => http.Response.fromStream(await req.send()),
      timeout: _uploadTimeout,
    );
    final data = await _decode(res);
    return ChatMessage.fromJson(data, meId: meId);
  }

  Future<File> downloadMedia(int messageId, String filename) async {
    final res = await _send(
      () => http.get(
        _uri('/api/media/$messageId'),
        headers: _headers(jsonBody: false),
      ),
    );
    if (res.statusCode >= 400) {
      // Errors arrive as JSON even though a success is raw file bytes.
      _parse(res);
    }
    final dir = await Directory.systemTemp.createTemp('localchat_');
    final out = File('${dir.path}/$filename');
    await out.writeAsBytes(res.bodyBytes);
    return out;
  }

  String mediaUrl(int messageId) => '$baseUrl/api/media/$messageId';

  String mediaThumbnailUrl(int messageId) =>
      '$baseUrl/api/media/$messageId/thumbnail';

  Future<List<OwnedMedia>> listMyMedia() async {
    final res = await _send(
      () =>
          http.get(_uri('/api/media/mine'), headers: _headers(jsonBody: false)),
    );
    return _decodeList(
      res,
    ).map((row) => OwnedMedia.fromJson(row as Map<String, dynamic>)).toList();
  }

  Future<MediaCleanupResult> deleteMyMedia(Iterable<int> messageIds) async {
    final res = await _send(
      () => http.delete(
        _uri('/api/media/mine'),
        headers: _headers(),
        body: jsonEncode({'message_ids': messageIds.toList()}),
      ),
      timeout: _uploadTimeout,
    );
    return MediaCleanupResult.fromJson(await _decode(res));
  }

  /// Bearer header for authenticated image loads (avatars, inline media).
  Map<String, String> get imageAuthHeaders =>
      token != null ? {'Authorization': 'Bearer $token'} : const {};

  /// URL for a user's profile picture, cache-busted by [version] so a changed
  /// photo is refetched instead of served from the image cache.
  String avatarUrl(int userId, {int? version}) {
    final base = '$baseUrl/api/users/$userId/avatar';
    return version == null ? base : '$base?v=$version';
  }

  /// Uploads the signed-in user's profile picture; returns the updated user.
  Future<ChatUser> uploadAvatar(File file) async {
    final req = http.MultipartRequest('POST', _uri('/api/users/me/avatar'));
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    req.files.add(await http.MultipartFile.fromPath('file', file.path));
    final res = await _send(
      () async => http.Response.fromStream(await req.send()),
      timeout: _uploadTimeout,
    );
    final data = await _decode(res);
    final user = ChatUser.fromJson(data);
    currentUser = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(_userToJson(user)));
    return user;
  }

  /// Removes the signed-in user's profile picture; returns the updated user.
  Future<ChatUser> deleteAvatar() async {
    final res = await _send(
      () => http.delete(
        _uri('/api/users/me/avatar'),
        headers: _headers(jsonBody: false),
      ),
    );
    final data = await _decode(res);
    final user = ChatUser.fromJson(data);
    currentUser = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(_userToJson(user)));
    return user;
  }

  /// URL for a chat's shared wallpaper, cache-busted by [version].
  String wallpaperUrl(int conversationId, {int? version}) {
    final base = '$baseUrl/api/conversations/$conversationId/wallpaper';
    return version == null ? base : '$base?v=$version';
  }

  /// Uploads a shared chat wallpaper; returns the updated conversation.
  Future<Conversation> uploadWallpaper(int conversationId, File file) async {
    final req = http.MultipartRequest(
      'PUT',
      _uri('/api/conversations/$conversationId/wallpaper'),
    );
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    req.files.add(await http.MultipartFile.fromPath('file', file.path));
    final res = await _send(
      () async => http.Response.fromStream(await req.send()),
      timeout: _uploadTimeout,
    );
    final data = await _decode(res);
    return Conversation.fromJson(data);
  }

  Future<Conversation> setWallpaperDim(int conversationId, double dim) async {
    final res = await _send(
      () => http.patch(
        _uri('/api/conversations/$conversationId/wallpaper/dim'),
        headers: _headers(),
        body: jsonEncode({'dim': dim}),
      ),
    );
    final data = await _decode(res);
    return Conversation.fromJson(data);
  }

  Future<Conversation> deleteWallpaper(int conversationId) async {
    final res = await _send(
      () => http.delete(
        _uri('/api/conversations/$conversationId/wallpaper'),
        headers: _headers(jsonBody: false),
      ),
    );
    final data = await _decode(res);
    return Conversation.fromJson(data);
  }

  /// Sets the disappearing-message timer; null turns it off.
  Future<Conversation> setDisappearing(int conversationId, int? seconds) async {
    final res = await _send(
      () => http.patch(
        _uri('/api/conversations/$conversationId/disappearing'),
        headers: _headers(),
        body: jsonEncode({'disappear_after_seconds': seconds}),
      ),
    );
    final data = await _decode(res);
    return Conversation.fromJson(data);
  }

  /// Sets a DM's anniversary date as `YYYY-MM-DD`; null clears it.
  Future<Conversation> setAnniversary(
    int conversationId,
    String? isoDate,
  ) async {
    final res = await _send(
      () => http.patch(
        _uri('/api/conversations/$conversationId/anniversary'),
        headers: _headers(),
        body: jsonEncode({'anniversary_on': isoDate}),
      ),
    );
    final data = await _decode(res);
    return Conversation.fromJson(data);
  }

  /// Updates the signed-in user's private mood; null clears it.
  Future<ChatUser> setMood(String? mood) async {
    final res = await _send(
      () => http.patch(
        _uri('/api/users/me/mood'),
        headers: _headers(),
        body: jsonEncode({'mood': mood}),
      ),
    );
    final data = await _decode(res);
    final user = ChatUser.fromJson(data);
    currentUser = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(_userToJson(user)));
    return user;
  }

  /// Updates the signed-in user's server-visible display name.
  Future<ChatUser> setDisplayName(String displayName) async {
    final res = await _send(
      () => http.patch(
        _uri('/api/users/me/display-name'),
        headers: _headers(),
        body: jsonEncode({'display_name': displayName.trim()}),
      ),
    );
    final data = await _decode(res);
    final user = ChatUser.fromJson(data);
    currentUser = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(_userToJson(user)));
    return user;
  }

  String? get wsUrl {
    if (baseUrl == null || token == null) return null;
    final httpUri = Uri.parse(baseUrl!);
    final scheme = httpUri.scheme == 'https' ? 'wss' : 'ws';
    return Uri(
      scheme: scheme,
      host: httpUri.host,
      port: httpUri.hasPort ? httpUri.port : null,
      path: '/ws',
      queryParameters: {'token': token},
    ).toString();
  }
}
