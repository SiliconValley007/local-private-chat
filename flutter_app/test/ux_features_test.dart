import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/models.dart';
import 'package:local_chat/services/conversation_prefs_store.dart';
import 'package:local_chat/services/export_service.dart';
import 'package:local_chat/widgets/linkified_text.dart';
import 'package:local_chat/app_state.dart';

void main() {
  group('conversation prefs', () {
    test('round-trip json', () {
      const prefs = ConversationPrefs(pinned: true, muted: true);
      final again = ConversationPrefs.fromJson(prefs.toJson());
      expect(again.pinned, isTrue);
      expect(again.muted, isTrue);
    });
  });

  group('deleted / edited messages', () {
    test('fromJson reads edited_at and deleted_at', () {
      final msg = ChatMessage.fromJson({
        'id': 1,
        'conversation_id': 1,
        'sender_id': 1,
        'type': 'text',
        'body': 'This message was deleted',
        'created_at': '2026-01-01T00:00:00Z',
        'edited_at': null,
        'deleted_at': '2026-01-01T01:00:00Z',
      });
      expect(msg.isDeleted, isTrue);
      expect(AppState.messagePreview(msg), 'This message was deleted');
    });

    test('preview for normal text', () {
      final msg = ChatMessage(
        id: 1,
        conversationId: 1,
        senderId: 1,
        type: 'text',
        body: 'hello',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      expect(AppState.messagePreview(msg), 'hello');
    });
  });

  group('linkify', () {
    test('detects urls', () {
      expect(containsUrl('see https://example.com/path'), isTrue);
      expect(containsUrl('no links here'), isFalse);
    });
  });

  group('export', () {
    test('formats a short transcript', () {
      final conv = Conversation(
        id: 1,
        type: 'dm',
        title: null,
        peer: ChatUser(id: 2, username: 'bob', displayName: 'Bob'),
        lastMessage: null,
        unreadCount: 0,
        updatedAt: DateTime.utc(2026, 1, 1),
        members: const [],
      );
      final text = formatChatAsText(
        conversation: conv,
        messages: [
          ChatMessage(
            id: 1,
            conversationId: 1,
            senderId: 1,
            type: 'text',
            body: 'hi',
            createdAt: DateTime.utc(2026, 1, 1, 12),
          ),
          ChatMessage(
            id: 2,
            conversationId: 1,
            senderId: 1,
            type: 'text',
            body: null,
            createdAt: DateTime.utc(2026, 1, 1, 13),
            deletedAt: DateTime.utc(2026, 1, 1, 14),
          ),
        ],
        nameFor: (id) => id == 1 ? 'Alice' : 'Bob',
        chatTitle: 'Bob',
      );
      expect(text, contains('Alice: hi'));
      expect(text, contains('This message was deleted'));
      expect(text, contains('Chat: Bob'));
    });
  });
}
