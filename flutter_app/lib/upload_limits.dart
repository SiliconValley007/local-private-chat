/// What the server will accept as a single attachment, and how a send in
/// progress is described while it happens.
///
/// A phone camera makes files the app used to accept blindly: two minutes of HD
/// video is a few hundred megabytes. Sending one asked the network for minutes
/// of work with nothing on screen, and could still end in a refusal the user
/// never saw. Both halves of that are decided here so both are testable.
library;

/// Server-declared ceiling for one attachment.
class UploadLimits {
  const UploadLimits({
    required this.maxMediaBytes,
    this.maxDoodleBytes = 2 * 1024 * 1024,
    this.freeBytes = 0,
    this.diskBound = false,
  });

  factory UploadLimits.fromJson(Map<String, dynamic> json) => UploadLimits(
    maxMediaBytes: (json['max_media_bytes'] as num?)?.toInt() ?? 0,
    maxDoodleBytes:
        (json['max_doodle_bytes'] as num?)?.toInt() ?? 2 * 1024 * 1024,
    freeBytes: (json['free_bytes'] as num?)?.toInt() ?? 0,
    diskBound: json['disk_bound'] == true,
  );

  /// Largest attachment the server will take now — the configured cap, or the
  /// space actually left if that is lower.
  final int maxMediaBytes;
  final int maxDoodleBytes;
  final int freeBytes;

  /// True when free space, not policy, is what caps [maxMediaBytes].
  final bool diskBound;

  bool allows(int bytes) => maxMediaBytes <= 0 || bytes <= maxMediaBytes;
}

/// Human size, matching the units used on attachment tiles.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final rounded = size >= 10 || unit == 0
      ? size.toStringAsFixed(0)
      : size.toStringAsFixed(1);
  return '$rounded ${units[unit]}';
}

/// Why a file cannot be sent, or null when it can.
///
/// Names the file's own size as well as the limit: "too large" without a number
/// leaves the user guessing which of their videos might fit.
String? tooLargeMessage({
  required int fileBytes,
  required UploadLimits limits,
  required bool isVideo,
}) {
  if (limits.allows(fileBytes)) return null;
  final what = isVideo ? 'That video' : 'That file';
  final size = formatBytes(fileBytes);
  final cap = formatBytes(limits.maxMediaBytes);
  if (limits.diskBound) {
    return '$what is $size, and the server only has room for $cap right now. '
        'Free some space on the server, or send a shorter clip.';
  }
  return '$what is $size. This server accepts attachments up to $cap. '
      'Send a shorter clip, or raise the limit on the server.';
}

/// Caption for the composer's progress bar.
///
/// Byte progress for a single file, because "Sending 1 of 1…" tells someone
/// waiting on a 322 MB video nothing at all. Counts for a batch, where the
/// per-file bytes matter less than how many are left.
String uploadProgressLabel({
  required int filesDone,
  required int filesTotal,
  required int bytesSent,
  required int bytesTotal,
  bool waiting = false,
}) {
  if (waiting) {
    return 'Paused — waiting for the connection…';
  }
  if (filesTotal > 1) {
    final current = filesDone + 1 > filesTotal ? filesTotal : filesDone + 1;
    return 'Sending $current of $filesTotal…';
  }
  if (bytesTotal <= 0) return 'Sending…';
  final percent = ((bytesSent / bytesTotal) * 100).clamp(0, 100).round();
  return 'Sending ${formatBytes(bytesSent)} of ${formatBytes(bytesTotal)} '
      '($percent%)';
}

/// Fraction for the progress indicator, or null while it is unknown (which
/// leaves the spinner indeterminate rather than pinned at zero).
double? uploadProgressValue({
  required int filesDone,
  required int filesTotal,
  required int bytesSent,
  required int bytesTotal,
}) {
  if (filesTotal > 1) return filesDone / filesTotal;
  if (bytesTotal <= 0 || bytesSent <= 0) return null;
  return (bytesSent / bytesTotal).clamp(0.0, 1.0);
}
