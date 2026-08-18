import 'dart:io';

import 'package:flutter/services.dart';

/// One attachment handed over by another app's share sheet.
class SharedFile {
  const SharedFile({required this.path, this.name, this.mime});

  final String path;
  final String? name;
  final String? mime;

  File get file => File(path);

  /// Whether this travels as a photo, a clip, or a plain document.
  ///
  /// The mime type the sending app declared wins, because a file copied out of a
  /// content provider often arrives with a useless or missing extension.
  String get attachmentType {
    final type = mime?.toLowerCase() ?? '';
    if (type.startsWith('image/')) return 'image';
    if (type.startsWith('video/')) return 'video';
    return 'file';
  }
}

/// Text and/or files another app asked Local Chat to send.
class IncomingShare {
  const IncomingShare({this.text, this.subject, this.files = const []});

  final String? text;

  /// Mail-style title some apps add alongside the text; kept so a shared page
  /// arrives as "Title\nlink" rather than a bare URL.
  final String? subject;
  final List<SharedFile> files;

  bool get isEmpty => (text?.trim().isEmpty ?? true) && files.isEmpty;

  /// The message body to send with this share.
  String get composedText {
    final body = text?.trim() ?? '';
    final title = subject?.trim() ?? '';
    if (title.isEmpty || title == body) return body;
    if (body.isEmpty) return title;
    // A subject that already opens the text (common when apps share an article)
    // would read twice over.
    if (body.startsWith(title)) return body;
    return '$title\n$body';
  }

  static IncomingShare? fromMap(Map<Object?, Object?> map) {
    final files = <SharedFile>[];
    final raw = map['files'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map) continue;
        final path = entry['path'];
        if (path is! String || path.isEmpty) continue;
        files.add(
          SharedFile(
            path: path,
            name: entry['name'] as String?,
            mime: entry['mime'] as String?,
          ),
        );
      }
    }
    final share = IncomingShare(
      text: map['text'] as String?,
      subject: map['subject'] as String?,
      files: files,
    );
    return share.isEmpty ? null : share;
  }
}

/// Bridges Android's share sheet and `localchat://` links into the app.
///
/// Two directions are needed: a cold start from the share sheet has the payload
/// waiting before Dart exists (pulled with `getInitial`), while a share into an
/// already-running app is pushed as `onIntent`.
class IncomingShareService {
  IncomingShareService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'local_chat/incoming';

  final MethodChannel _channel;

  void Function(IncomingShare share)? onShare;
  void Function(Uri uri)? onLink;

  /// Starts listening and drains anything that arrived before now.
  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onIntent') {
        final args = call.arguments;
        if (args is Map) handle(args);
      }
      return null;
    });
    try {
      final initial = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getInitial',
      );
      if (initial != null) handle(initial);
    } on MissingPluginException {
      // Not Android (or a test host): nothing shares into this build.
    } catch (_) {
      // A share we cannot read must never stop the app from starting.
    }
  }

  /// Routes one payload from the platform. Public so tests can drive it without
  /// a live channel.
  void handle(Map<Object?, Object?> payload) {
    switch (payload['kind']) {
      case 'share':
        final share = IncomingShare.fromMap(payload);
        if (share != null) onShare?.call(share);
      case 'link':
        final raw = payload['uri'];
        if (raw is! String) return;
        final uri = Uri.tryParse(raw);
        if (uri != null) onLink?.call(uri);
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}
