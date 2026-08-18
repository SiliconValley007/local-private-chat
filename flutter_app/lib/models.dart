import 'time_format.dart';

class ChatUser {
  ChatUser({
    required this.id,
    required this.username,
    required this.displayName,
    this.lastSeenAt,
    this.isOnline = false,
    this.hasAvatar = false,
    this.avatarVersion,
    this.mood,
  });

  final int id;
  final String username;
  final String displayName;
  final DateTime? lastSeenAt;
  final bool isOnline;

  /// The server holds a profile picture for this user.
  final bool hasAvatar;

  /// Cache-busting token that changes whenever the picture changes.
  final int? avatarVersion;

  /// A short private status a person shows only to their DM partners.
  final String? mood;

  factory ChatUser.fromJson(Map<String, dynamic> json) {
    return ChatUser(
      id: json['id'] as int,
      username: json['username'] as String,
      displayName: json['display_name'] as String,
      lastSeenAt: tryParseServerTime(json['last_seen_at'] as String?),
      isOnline: json['is_online'] as bool? ?? false,
      hasAvatar: json['has_avatar'] as bool? ?? false,
      avatarVersion: json['avatar_version'] as int?,
      mood: (json['mood'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['mood'] as String).trim(),
    );
  }

  ChatUser copyWith({
    bool? isOnline,
    DateTime? lastSeenAt,
    bool? hasAvatar,
    int? avatarVersion,
    String? mood,
    String? displayName,
    bool clearAvatar = false,
    bool clearMood = false,
  }) {
    return ChatUser(
      id: id,
      username: username,
      displayName: displayName ?? this.displayName,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      isOnline: isOnline ?? this.isOnline,
      hasAvatar: clearAvatar ? false : (hasAvatar ?? this.hasAvatar),
      avatarVersion: clearAvatar ? null : (avatarVersion ?? this.avatarVersion),
      mood: clearMood ? null : (mood ?? this.mood),
    );
  }
}

/// One emoji's tally on a message: how many reacted and whether you did.
class ReactionAgg {
  const ReactionAgg({
    required this.emoji,
    required this.count,
    required this.reactedByMe,
    this.userIds = const [],
  });

  final String emoji;
  final int count;
  final bool reactedByMe;
  final List<int> userIds;

  factory ReactionAgg.fromJson(Map<String, dynamic> json, {int? meId}) {
    final ids = (json['user_ids'] as List<dynamic>? ?? [])
        .map((e) => e as int)
        .toList();
    return ReactionAgg(
      emoji: json['emoji'] as String,
      count: json['count'] as int? ?? ids.length,
      // The broadcast payload computes reacted_by_me from the reactor's own
      // view, so recompute it from the id list against this phone's user.
      reactedByMe: meId != null
          ? ids.contains(meId)
          : (json['reacted_by_me'] as bool? ?? false),
      userIds: ids,
    );
  }
}

class Receipt {
  Receipt({required this.userId, this.deliveredAt, this.readAt});

  final int userId;
  final DateTime? deliveredAt;
  final DateTime? readAt;

  factory Receipt.fromJson(Map<String, dynamic> json) {
    return Receipt(
      userId: json['user_id'] as int,
      deliveredAt: tryParseServerTime(json['delivered_at'] as String?),
      readAt: tryParseServerTime(json['read_at'] as String?),
    );
  }

  Receipt copyWith({DateTime? deliveredAt, DateTime? readAt}) {
    return Receipt(
      userId: userId,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      readAt: readAt ?? this.readAt,
    );
  }
}

/// The part of a quoted message needed to draw a reply header.
///
/// Sent inline with every reply so the quote still renders when the original is
/// older than the history currently loaded on this phone.
class QuotedMessage {
  const QuotedMessage({
    required this.id,
    required this.senderId,
    required this.type,
    this.body,
    this.mediaName,
    this.deleted = false,
  });

  final int id;
  final int senderId;
  final String type;
  final String? body;
  final String? mediaName;
  final bool deleted;

  factory QuotedMessage.fromJson(Map<String, dynamic> json) => QuotedMessage(
    id: json['id'] as int,
    senderId: json['sender_id'] as int,
    type: json['type'] as String,
    body: json['body'] as String?,
    mediaName: json['media_name'] as String?,
    deleted: json['deleted'] as bool? ?? false,
  );

  factory QuotedMessage.fromMessage(ChatMessage message) => QuotedMessage(
    id: message.id,
    senderId: message.senderId,
    type: message.type,
    body: message.body,
    mediaName: message.mediaName,
    deleted: message.deletedAt != null,
  );
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.type,
    this.body,
    this.mediaName,
    this.mediaSize,
    this.mediaMime,
    this.mediaDurationMs,
    this.clientId,
    required this.createdAt,
    this.editedAt,
    this.deletedAt,
    this.expiresAt,
    this.replyTo,
    this.receipts = const [],
    this.reactions = const [],
    this.pending = false,
    this.starId,
    this.serverReceiptLevel,
  });

  final int id;
  final int conversationId;
  final int senderId;
  final String type;
  final String? body;
  final String? mediaName;
  final int? mediaSize;
  final String? mediaMime;

  /// Video length in milliseconds, when known (videos only).
  final int? mediaDurationMs;
  final String? clientId;
  final DateTime createdAt;
  final DateTime? editedAt;
  final DateTime? deletedAt;

  /// When a disappearing message will vanish, or null if it stays.
  final DateTime? expiresAt;

  /// The message this one replies to, or null for a normal message.
  final QuotedMessage? replyTo;
  final List<Receipt> receipts;

  /// Emoji tallies on this message, one entry per distinct emoji.
  final List<ReactionAgg> reactions;
  final bool pending;

  /// Present on starred-list responses for pagination.
  final int? starId;

  /// Inbox preview only: server-computed ticks for the viewer's latest message.
  final int? serverReceiptLevel;

  bool get isDeleted => deletedAt != null;

  /// True for a call-log entry ("Video call · 21 secs" / "Missed call").
  bool get isCallLog => type == 'call';

  static List<ReactionAgg> _reactionsFrom(dynamic raw, {int? meId}) {
    final list = raw as List<dynamic>? ?? const [];
    return list
        .map((e) => ReactionAgg.fromJson(e as Map<String, dynamic>, meId: meId))
        .toList();
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json, {int? meId}) {
    final receiptsJson = json['receipts'] as List<dynamic>? ?? [];
    final reply = json['reply_to'] as Map<String, dynamic>?;
    return ChatMessage(
      id: json['id'] as int,
      conversationId: json['conversation_id'] as int,
      senderId: json['sender_id'] as int,
      type: json['type'] as String,
      body: json['body'] as String?,
      mediaName: json['media_name'] as String?,
      mediaSize: json['media_size'] as int?,
      mediaMime: json['media_mime'] as String?,
      mediaDurationMs: json['media_duration_ms'] as int?,
      clientId: json['client_id'] as String?,
      createdAt: parseServerTime(json['created_at'] as String),
      editedAt: tryParseServerTime(json['edited_at'] as String?),
      deletedAt: tryParseServerTime(json['deleted_at'] as String?),
      expiresAt: tryParseServerTime(json['expires_at'] as String?),
      replyTo: reply == null ? null : QuotedMessage.fromJson(reply),
      receipts: receiptsJson
          .map((e) => Receipt.fromJson(e as Map<String, dynamic>))
          .toList(),
      reactions: _reactionsFrom(json['reactions'], meId: meId),
      starId: json['star_id'] as int?,
      serverReceiptLevel: json['receipt_level'] as int?,
    );
  }

  ChatMessage copyWith({
    int? id,
    String? body,
    String? type,
    String? mediaName,
    int? mediaSize,
    String? mediaMime,
    int? mediaDurationMs,
    DateTime? editedAt,
    DateTime? deletedAt,
    DateTime? expiresAt,
    QuotedMessage? replyTo,
    List<Receipt>? receipts,
    List<ReactionAgg>? reactions,
    bool? pending,
    int? starId,
    bool clearEditedAt = false,
    bool clearDeletedAt = false,
    int? serverReceiptLevel,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      conversationId: conversationId,
      senderId: senderId,
      type: type ?? this.type,
      body: body ?? this.body,
      mediaName: mediaName ?? this.mediaName,
      mediaSize: mediaSize ?? this.mediaSize,
      mediaMime: mediaMime ?? this.mediaMime,
      mediaDurationMs: mediaDurationMs ?? this.mediaDurationMs,
      clientId: clientId,
      createdAt: createdAt,
      editedAt: clearEditedAt ? null : (editedAt ?? this.editedAt),
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      expiresAt: expiresAt ?? this.expiresAt,
      replyTo: replyTo ?? this.replyTo,
      receipts: receipts ?? this.receipts,
      reactions: reactions ?? this.reactions,
      pending: pending ?? this.pending,
      starId: starId ?? this.starId,
      serverReceiptLevel: serverReceiptLevel ?? this.serverReceiptLevel,
    );
  }

  /// Whether this phone's user may still edit this text message.
  ///
  /// WhatsApp-class trustworthiness: editing is only allowed for 15 minutes
  /// after sending. After that the option disappears so old text can't be
  /// quietly rewritten.
  static const editWindow = Duration(minutes: 15);

  bool canEdit(int? meId) {
    if (meId == null || senderId != meId) return false;
    if (type != 'text' || isDeleted) return false;
    return DateTime.now().difference(createdAt) < editWindow;
  }

  /// WhatsApp-like ticks for the sender: 0 sent, 1 delivered, 2 read.
  int receiptLevel() {
    if (receipts.isEmpty) return 0;
    if (receipts.every((r) => r.readAt != null)) return 2;
    if (receipts.every((r) => r.deliveredAt != null)) return 1;
    if (receipts.any((r) => r.deliveredAt != null)) return 1;
    return 0;
  }
}

/// One row in the WhatsApp-style Media / Docs / Links gallery.
class SharedItem {
  SharedItem({
    required this.messageId,
    required this.kind,
    required this.type,
    required this.createdAt,
    required this.senderId,
    this.mediaName,
    this.mediaSize,
    this.mediaMime,
    this.mediaDurationMs,
    this.body,
    this.url,
  });

  final int messageId;

  /// `media` | `docs` | `links`
  final String kind;
  final String type;
  final String? mediaName;
  final int? mediaSize;
  final String? mediaMime;

  /// Video length in milliseconds, when known (videos only).
  final int? mediaDurationMs;
  final String? body;
  final String? url;
  final DateTime createdAt;
  final int senderId;

  factory SharedItem.fromJson(Map<String, dynamic> json) => SharedItem(
    messageId: json['message_id'] as int,
    kind: json['kind'] as String,
    type: json['type'] as String,
    mediaName: json['media_name'] as String?,
    mediaSize: json['media_size'] as int?,
    mediaMime: json['media_mime'] as String?,
    mediaDurationMs: json['media_duration_ms'] as int?,
    body: json['body'] as String?,
    url: json['url'] as String?,
    createdAt: parseServerTime(json['created_at'] as String),
    senderId: json['sender_id'] as int,
  );
}

class OwnedMedia {
  const OwnedMedia({
    required this.messageId,
    required this.conversationId,
    required this.conversationTitle,
    required this.type,
    required this.mediaSize,
    required this.createdAt,
    this.mediaName,
    this.mediaMime,
  });

  final int messageId;
  final int conversationId;
  final String conversationTitle;
  final String type;
  final String? mediaName;
  final int mediaSize;
  final String? mediaMime;
  final DateTime createdAt;

  factory OwnedMedia.fromJson(Map<String, dynamic> json) => OwnedMedia(
    messageId: json['message_id'] as int,
    conversationId: json['conversation_id'] as int,
    conversationTitle: json['conversation_title'] as String,
    type: json['type'] as String,
    mediaName: json['media_name'] as String?,
    mediaSize: json['media_size'] as int? ?? 0,
    mediaMime: json['media_mime'] as String?,
    createdAt: parseServerTime(json['created_at'] as String),
  );
}

class MediaCleanupResult {
  const MediaCleanupResult({
    required this.deleted,
    required this.reclaimedBytes,
  });

  final int deleted;
  final int reclaimedBytes;

  factory MediaCleanupResult.fromJson(Map<String, dynamic> json) =>
      MediaCleanupResult(
        deleted: json['deleted'] as int? ?? 0,
        reclaimedBytes: json['reclaimed_bytes'] as int? ?? 0,
      );
}

class ConversationMember {
  ConversationMember({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.role,
    this.isOnline = false,
    this.hasAvatar = false,
    this.avatarVersion,
  });

  final int userId;
  final String username;
  final String displayName;
  final String role;
  final bool isOnline;
  final bool hasAvatar;
  final int? avatarVersion;

  factory ConversationMember.fromJson(Map<String, dynamic> json) {
    return ConversationMember(
      userId: json['user_id'] as int,
      username: json['username'] as String,
      displayName: json['display_name'] as String,
      role: json['role'] as String,
      isOnline: json['is_online'] as bool? ?? false,
      hasAvatar: json['has_avatar'] as bool? ?? false,
      avatarVersion: json['avatar_version'] as int?,
    );
  }
}

class Conversation {
  Conversation({
    required this.id,
    required this.type,
    this.title,
    this.peer,
    this.lastMessage,
    this.unreadCount = 0,
    required this.updatedAt,
    this.members = const [],
    this.wallpaperVersion,
    this.wallpaperDim,
    this.hasWallpaper = false,
    this.disappearAfterSeconds,
    this.anniversaryOn,
    this.streakDays = 0,
  });

  final int id;
  final String type;
  final String? title;
  final ChatUser? peer;
  final ChatMessage? lastMessage;
  final int unreadCount;
  final DateTime updatedAt;
  final List<ConversationMember> members;

  /// Server-synced wallpaper shared by everyone in the chat. The version is a
  /// cache-busting token that changes whenever a member sets a new image.
  final int? wallpaperVersion;
  final double? wallpaperDim;
  final bool hasWallpaper;

  /// Disappearing-message timer in seconds, or null when off.
  final int? disappearAfterSeconds;

  /// A DM's anniversary date as `YYYY-MM-DD`, or null when unset.
  final String? anniversaryOn;

  /// Consecutive days both people messaged (DMs only).
  final int streakDays;

  String get displayTitle {
    if (type == 'dm') return peer?.displayName ?? title ?? 'Chat';
    return title ?? 'Group';
  }

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final last = json['last_message'] as Map<String, dynamic>?;
    ChatMessage? lastMessage;
    if (last != null) {
      lastMessage = ChatMessage(
        id: last['id'] as int,
        conversationId: json['id'] as int,
        senderId: last['sender_id'] as int,
        type: last['type'] as String,
        body: last['body'] as String?,
        mediaName: last['media_name'] as String?,
        createdAt: parseServerTime(last['created_at'] as String),
        serverReceiptLevel: last['receipt_level'] as int?,
      );
    }
    final membersJson = json['members'] as List<dynamic>? ?? [];
    return Conversation(
      id: json['id'] as int,
      type: json['type'] as String,
      title: json['title'] as String?,
      peer: json['peer'] != null
          ? ChatUser.fromJson(json['peer'] as Map<String, dynamic>)
          : null,
      lastMessage: lastMessage,
      unreadCount: json['unread_count'] as int? ?? 0,
      updatedAt: parseServerTime(json['updated_at'] as String),
      members: membersJson
          .map((e) => ConversationMember.fromJson(e as Map<String, dynamic>))
          .toList(),
      wallpaperVersion: json['wallpaper_version'] as int?,
      wallpaperDim: (json['wallpaper_dim'] as num?)?.toDouble(),
      hasWallpaper: json['has_wallpaper'] as bool? ?? false,
      disappearAfterSeconds: json['disappear_after_seconds'] as int?,
      anniversaryOn: json['anniversary_on'] as String?,
      streakDays: json['streak_days'] as int? ?? 0,
    );
  }
}
