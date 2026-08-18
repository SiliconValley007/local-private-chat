import 'package:intl/intl.dart';

import '../models.dart';

/// Build a plain-text transcript of one conversation for sharing or saving.
String formatChatAsText({
  required Conversation conversation,
  required List<ChatMessage> messages,
  required String Function(int senderId) nameFor,
  required String chatTitle,
}) {
  final clock = DateFormat.yMd().add_jm();
  final buffer = StringBuffer();
  buffer.writeln('Local Chat export');
  buffer.writeln('Chat: $chatTitle');
  buffer.writeln('Type: ${conversation.type}');
  buffer.writeln('Exported: ${DateTime.now().toLocal().toIso8601String()}');
  buffer.writeln('---');
  for (final m in messages) {
    final when = clock.format(m.createdAt.toLocal());
    final who = nameFor(m.senderId);
    if (m.deletedAt != null) {
      buffer.writeln('[$when] $who: This message was deleted');
      continue;
    }
    final body = switch (m.type) {
      'image' =>
        m.body?.trim().isNotEmpty == true ? 'Photo · ${m.body}' : 'Photo',
      'voice' => 'Voice message',
      'doodle' => 'Drawing',
      'file' =>
        m.mediaName?.isNotEmpty == true ? 'File · ${m.mediaName}' : 'File',
      _ => m.body ?? '',
    };
    final edited = m.editedAt != null ? ' (edited)' : '';
    buffer.writeln('[$when] $who: $body$edited');
  }
  return buffer.toString();
}
