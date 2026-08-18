import 'call_log.dart';
import 'e2e_text.dart';
import 'models.dart';

/// One-line summary shared by inbox, starred, search, quotes, and notifications.
String formatMessagePreview({
  required String type,
  String? body,
  String? mediaName,
  bool isDeleted = false,
  String emptyTextFallback = 'New message',
  int? viewerUserId,
  String? endedByName,
}) {
  if (isDeleted) return 'This message was deleted';
  // A body that is still sealed has no summary to give, and printing the token
  // turns a starred row or an inbox subtitle into a line of base64.
  final sealed = isE2eCipherText(body);
  switch (type) {
    case 'image':
      final caption = sealed ? '' : body?.trim() ?? '';
      return caption.isEmpty ? 'Photo' : 'Photo · $caption';
    case 'video':
      final caption = sealed ? '' : body?.trim() ?? '';
      return caption.isEmpty ? 'Video' : 'Video · $caption';
    case 'doodle':
      return 'Drawing';
    case 'voice':
      return 'Voice message';
    case 'file':
      final name = mediaName?.trim() ?? '';
      return name.isEmpty ? 'File' : name;
    case 'call':
      return formatCallLogPreview(
        parseCallLogBody(body),
        viewerUserId: viewerUserId,
        endedByName: endedByName,
      );
    default:
      if (sealed) return encryptedPreview;
      final text = body?.trim() ?? '';
      return text.isEmpty ? emptyTextFallback : text;
  }
}

/// Preview for a full [ChatMessage].
String chatMessagePreview(
  ChatMessage msg, {
  int? viewerUserId,
  String? endedByName,
}) => formatMessagePreview(
  type: msg.type,
  body: msg.body,
  mediaName: msg.mediaName,
  isDeleted: msg.isDeleted,
  viewerUserId: viewerUserId,
  endedByName: endedByName,
);

/// Preview for a quoted snippet inside a reply bubble.
String quotedMessagePreview(QuotedMessage quote) => formatMessagePreview(
  type: quote.type,
  body: quote.body,
  mediaName: quote.mediaName,
  emptyTextFallback: 'Message',
);
