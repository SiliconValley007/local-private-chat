import 'time_format.dart';

class ChatUser {
  ChatUser({
    required this.id,
    required this.username,
    required this.displayName,
    this.lastSeenAt,
    this.isOnline = false,
  });

  final int id;
  final String username;
  final String displayName;
  final DateTime? lastSeenAt;
  final bool isOnline;

  factory ChatUser.fromJson(Map<String, dynamic> json) {
    return ChatUser(
      id: json['id'] as int,
      username: json['username'] as String,
      displayName: json['display_name'] as String,
      lastSeenAt: tryParseServerTime(json['last_seen_at'] as String?),
      isOnline: json['is_online'] as bool? ?? false,
    );
  }

  ChatUser copyWith({bool? isOnline, DateTime? lastSeenAt}) {
    return ChatUser(
      id: id,
      username: username,
      displayName: displayName,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      isOnline: isOnline ?? this.isOnline,
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
  });

  final int id;
  final int senderId;
  final String type;
  final String? body;
  final String? mediaName;

  factory QuotedMessage.fromJson(Map<String, dynamic> json) => QuotedMessage(
    id: json['id'] as int,
    senderId: json['sender_id'] as int,
    type: json['type'] as String,
    body: json['body'] as String?,
    mediaName: json['media_name'] as String?,
  );

  factory QuotedMessage.fromMessage(ChatMessage message) => QuotedMessage(
    id: message.id,
    senderId: message.senderId,
    type: message.type,
    body: message.body,
    mediaName: message.mediaName,
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
    this.clientId,
    required this.createdAt,
    this.replyTo,
    this.receipts = const [],
    this.pending = false,
  });

  final int id;
  final int conversationId;
  final int senderId;
  final String type;
  final String? body;
  final String? mediaName;
  final int? mediaSize;
  final String? mediaMime;
  final String? clientId;
  final DateTime createdAt;

  /// The message this one replies to, or null for a normal message.
  final QuotedMessage? replyTo;
  final List<Receipt> receipts;
  final bool pending;

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
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
      clientId: json['client_id'] as String?,
      createdAt: parseServerTime(json['created_at'] as String),
      replyTo: reply == null ? null : QuotedMessage.fromJson(reply),
      receipts: receiptsJson
          .map((e) => Receipt.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  ChatMessage copyWith({int? id, List<Receipt>? receipts, bool? pending}) {
    return ChatMessage(
      id: id ?? this.id,
      conversationId: conversationId,
      senderId: senderId,
      type: type,
      body: body,
      mediaName: mediaName,
      mediaSize: mediaSize,
      mediaMime: mediaMime,
      clientId: clientId,
      createdAt: createdAt,
      replyTo: replyTo,
      receipts: receipts ?? this.receipts,
      pending: pending ?? this.pending,
    );
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

class ConversationMember {
  ConversationMember({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.role,
    this.isOnline = false,
  });

  final int userId;
  final String username;
  final String displayName;
  final String role;
  final bool isOnline;

  factory ConversationMember.fromJson(Map<String, dynamic> json) {
    return ConversationMember(
      userId: json['user_id'] as int,
      username: json['username'] as String,
      displayName: json['display_name'] as String,
      role: json['role'] as String,
      isOnline: json['is_online'] as bool? ?? false,
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
  });

  final int id;
  final String type;
  final String? title;
  final ChatUser? peer;
  final ChatMessage? lastMessage;
  final int unreadCount;
  final DateTime updatedAt;
  final List<ConversationMember> members;

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
    );
  }
}
