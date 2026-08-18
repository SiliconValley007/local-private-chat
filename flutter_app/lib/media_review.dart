import 'dart:io';

/// Outcome of the WhatsApp-style review step before media is uploaded.
class MediaReviewResult {
  const MediaReviewResult({required this.files, this.caption});

  final List<File> files;

  /// Trimmed caption; applied only to the first attachment in a batch upload.
  final String? caption;
}

/// Which attachment index, if any, should carry [caption] in a batch upload.
///
/// WhatsApp attaches one caption to the first photo in an album; the rest are
/// sent without body text.
String? captionForBatchIndex({required int index, String? caption}) {
  if (index != 0) return null;
  final trimmed = caption?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

/// How an external share should be sent after review.
///
/// Pure logic so share-target behaviour is testable without navigation.
class ShareMediaSendPlan {
  const ShareMediaSendPlan({
    required this.files,
    this.caption,
    this.separateText,
  });

  final List<File> files;

  /// Caption for the first uploaded media message, if any.
  final String? caption;

  /// Plain text to send as its own message after media (only when there is no
  /// media to attach it to).
  final String? separateText;
}

ShareMediaSendPlan planShareMediaSend({
  required List<File> files,
  required String composedText,
}) {
  final text = composedText.trim();
  if (files.isEmpty) {
    return ShareMediaSendPlan(
      files: const [],
      separateText: text.isEmpty ? null : text,
    );
  }
  return ShareMediaSendPlan(files: files, caption: text.isEmpty ? null : text);
}

/// Normalises a caption from the review composer.
String? normalizeMediaCaption(String? raw) {
  final trimmed = raw?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}
