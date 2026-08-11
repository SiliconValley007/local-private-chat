import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/app_state.dart';
import 'package:local_chat/models.dart';
import 'package:local_chat/services/connectivity_service.dart';
import 'package:local_chat/widgets/attachments.dart';
import 'package:local_chat/widgets/avatar.dart';

ChatMessage _message({
  required String type,
  String? body,
  String? mediaName,
  int? mediaSize,
  String? mediaMime,
}) {
  return ChatMessage(
    id: 1,
    conversationId: 1,
    senderId: 2,
    type: type,
    body: body,
    mediaName: mediaName,
    mediaSize: mediaSize,
    mediaMime: mediaMime,
    createdAt: DateTime.utc(2026, 8, 11, 10),
  );
}

void main() {
  group('Tailscale address detection', () {
    test('accepts the whole 100.64.0.0/10 range', () {
      expect(ConnectivityService.isTailscaleAddress('100.71.32.92'), isTrue);
      expect(ConnectivityService.isTailscaleAddress('100.64.0.1'), isTrue);
      expect(ConnectivityService.isTailscaleAddress('100.127.255.254'), isTrue);
    });

    test('rejects public and LAN addresses that merely start with 100', () {
      expect(ConnectivityService.isTailscaleAddress('100.63.0.1'), isFalse);
      expect(ConnectivityService.isTailscaleAddress('100.128.0.1'), isFalse);
      expect(ConnectivityService.isTailscaleAddress('192.168.1.10'), isFalse);
      expect(ConnectivityService.isTailscaleAddress('not-an-ip'), isFalse);
    });
  });

  group('message previews', () {
    test('media types read as words, not raw type names', () {
      expect(AppState.messagePreview(_message(type: 'voice')), 'Voice message');
      expect(AppState.messagePreview(_message(type: 'image')), 'Photo');
      expect(
        AppState.messagePreview(_message(type: 'image', body: 'at the beach')),
        'Photo · at the beach',
      );
      expect(
        AppState.messagePreview(
          _message(type: 'file', mediaName: 'invoice.pdf'),
        ),
        'invoice.pdf',
      );
    });

    test('text falls back to a label when the body is empty', () {
      expect(AppState.messagePreview(_message(type: 'text')), 'New message');
      expect(AppState.messagePreview(_message(type: 'text', body: 'hi')), 'hi');
    });
  });

  group('attachment labels', () {
    test('file size is human readable', () {
      expect(formatFileSize(null), '');
      expect(formatFileSize(0), '');
      expect(formatFileSize(900), '900 B');
      expect(formatFileSize(2048), '2.0 KB');
      expect(formatFileSize(15 * 1024 * 1024), '15 MB');
    });

    test('extension comes from the file name', () {
      expect(fileExtensionOf(_message(type: 'file', mediaName: 'a.PdF')), 'PDF');
      expect(fileExtensionOf(_message(type: 'file', mediaName: 'noext')), '');
    });

    test('badge follows the mime type when the name has no extension', () {
      final badge = fileBadge(
        _message(type: 'file', mediaName: 'scan', mediaMime: 'image/png'),
      );
      expect(badge.icon.codePoint, isNot(0));
      expect(badge.color.a, 1.0);
    });

    test('clip duration formats as m:ss', () {
      expect(formatClipDuration(null), '--:--');
      expect(formatClipDuration(const Duration(seconds: 8)), '0:08');
      expect(formatClipDuration(const Duration(seconds: 125)), '2:05');
    });
  });

  group('avatars', () {
    test('initials use first and last word', () {
      expect(initialsFor('Debjeet Das'), 'DD');
      expect(initialsFor('faye'), 'F');
      expect(initialsFor('   '), '?');
    });

    test('the same person always gets the same colours', () {
      expect(avatarPalette(7), avatarPalette(7));
    });
  });
}
