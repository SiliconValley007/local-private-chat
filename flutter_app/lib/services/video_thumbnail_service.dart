import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('local_chat/video_thumbnail');

/// A generated preview frame and the clip's duration. Either field may be null
/// when the device codec could not produce it; the caller then degrades to a
/// plain tile without a thumbnail or duration badge.
class VideoPreview {
  const VideoPreview({this.file, this.durationMs});

  final File? file;
  final int? durationMs;
}

/// Uses Android's built-in media decoder, avoiding an ffmpeg/server dependency.
class VideoThumbnailService {
  static Future<VideoPreview> create(String videoPath) async {
    if (!Platform.isAndroid) return const VideoPreview();
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('create', {
        'path': videoPath,
        'maxWidth': 480,
        'quality': 72,
      });
      if (result == null) return const VideoPreview();
      final path = result['path'] as String?;
      final durationMs = (result['durationMs'] as num?)?.toInt();
      return VideoPreview(
        file: path == null || path.isEmpty ? null : File(path),
        durationMs: durationMs,
      );
    } on PlatformException {
      return const VideoPreview();
    } on MissingPluginException {
      return const VideoPreview();
    }
  }

  /// Creates the small upload-time photo preview used by transcript bubbles.
  ///
  /// The original is still uploaded for full-screen zoom and downloads.
  static Future<VideoPreview> createImage(String imagePath) async {
    if (!Platform.isAndroid) return const VideoPreview();
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'createImage',
        {'path': imagePath, 'maxWidth': 720, 'quality': 78},
      );
      final path = result?['path'] as String?;
      return VideoPreview(
        file: path == null || path.isEmpty ? null : File(path),
      );
    } on PlatformException {
      return const VideoPreview();
    } on MissingPluginException {
      return const VideoPreview();
    }
  }
}
