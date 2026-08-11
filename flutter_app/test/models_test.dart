import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/models.dart';
import 'package:local_chat/services/theme_store.dart';
import 'package:local_chat/widgets/quoted_message.dart';
import 'package:flutter/material.dart';

void main() {
  test('ChatUser.fromJson parses fields', () {
    final user = ChatUser.fromJson({
      'id': 1,
      'username': 'alice',
      'display_name': 'Alice',
      'last_seen_at': null,
      'is_online': true,
    });
    expect(user.id, 1);
    expect(user.username, 'alice');
    expect(user.displayName, 'Alice');
    expect(user.isOnline, isTrue);
  });

  test('ChatMessage receiptLevel delivered and read', () {
    final sent = ChatMessage(
      id: 1,
      conversationId: 1,
      senderId: 1,
      type: 'text',
      body: 'hi',
      createdAt: DateTime.utc(2026, 1, 1),
      receipts: [Receipt(userId: 2)],
    );
    expect(sent.receiptLevel(), 0);

    final delivered = sent.copyWith(
      receipts: [Receipt(userId: 2, deliveredAt: DateTime.utc(2026, 1, 1, 0, 1))],
    );
    expect(delivered.receiptLevel(), 1);

    final read = sent.copyWith(
      receipts: [
        Receipt(
          userId: 2,
          deliveredAt: DateTime.utc(2026, 1, 1, 0, 1),
          readAt: DateTime.utc(2026, 1, 1, 0, 2),
        ),
      ],
    );
    expect(read.receiptLevel(), 2);
  });

  test('Conversation.fromJson dm title via peer', () {
    final conv = Conversation.fromJson({
      'id': 9,
      'type': 'dm',
      'title': null,
      'peer': {
        'id': 2,
        'username': 'bob',
        'display_name': 'Bob',
        'is_online': false,
      },
      'last_message': {
        'id': 3,
        'type': 'text',
        'body': 'hello',
        'sender_id': 1,
        'created_at': '2026-01-01T00:00:00Z',
      },
      'unread_count': 1,
      'updated_at': '2026-01-01T00:00:00Z',
      'members': [],
    });
    expect(conv.displayTitle, 'Bob');
    expect(conv.lastMessage?.body, 'hello');
    expect(conv.unreadCount, 1);
  });

  group('reply / quoting', () {
    test('ChatMessage.fromJson parses the quoted message', () {
      final msg = ChatMessage.fromJson({
        'id': 5,
        'conversation_id': 1,
        'sender_id': 2,
        'type': 'text',
        'body': 'On my way',
        'created_at': '2026-01-01T00:00:00Z',
        'reply_to': {
          'id': 4,
          'sender_id': 1,
          'type': 'text',
          'body': 'Where are you?',
        },
      });
      expect(msg.replyTo, isNotNull);
      expect(msg.replyTo!.id, 4);
      expect(msg.replyTo!.senderId, 1);
      expect(msg.replyTo!.body, 'Where are you?');
    });

    test('a message with no reply_to has a null quote', () {
      final msg = ChatMessage.fromJson({
        'id': 6,
        'conversation_id': 1,
        'sender_id': 2,
        'type': 'text',
        'body': 'plain',
        'created_at': '2026-01-01T00:00:00Z',
      });
      expect(msg.replyTo, isNull);
    });

    test('quotedSummary reads media types as words', () {
      expect(
        quotedSummary(
          const QuotedMessage(id: 1, senderId: 1, type: 'image'),
        ),
        'Photo',
      );
      expect(
        quotedSummary(
          const QuotedMessage(
            id: 1,
            senderId: 1,
            type: 'image',
            body: 'beach',
          ),
        ),
        'Photo · beach',
      );
      expect(
        quotedSummary(
          const QuotedMessage(id: 1, senderId: 1, type: 'voice'),
        ),
        'Voice message',
      );
      expect(
        quotedSummary(
          const QuotedMessage(
            id: 1,
            senderId: 1,
            type: 'file',
            mediaName: 'invoice.pdf',
          ),
        ),
        'invoice.pdf',
      );
      expect(
        quotedSummary(
          const QuotedMessage(id: 1, senderId: 1, type: 'text', body: 'hi'),
        ),
        'hi',
      );
    });
  });

  group('theme preference', () {
    test('encode and decode round-trip every mode', () {
      for (final mode in ThemeMode.values) {
        expect(ThemeStore.decode(ThemeStore.encode(mode)), mode);
      }
    });

    test('unknown or missing values fall back to system', () {
      expect(ThemeStore.decode(null), ThemeMode.system);
      expect(ThemeStore.decode('nonsense'), ThemeMode.system);
    });
  });
}
