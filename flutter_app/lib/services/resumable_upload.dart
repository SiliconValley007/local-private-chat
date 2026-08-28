import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../models.dart';

/// How much of an attachment the server holds, and how to send the rest.
class UploadHandle {
  const UploadHandle({
    required this.uploadId,
    required this.offset,
    required this.size,
    required this.chunkBytes,
    required this.complete,
  });

  final String uploadId;
  final int offset;
  final int size;
  final int chunkBytes;
  final bool complete;

  factory UploadHandle.fromJson(Map<String, dynamic> json) {
    final size = (json['size'] as num?)?.toInt() ?? 0;
    final offset = (json['offset'] as num?)?.toInt() ?? 0;
    return UploadHandle(
      uploadId: (json['upload_id'] ?? '').toString(),
      offset: offset,
      size: size,
      // A server that forgets to say falls back to a chunk small enough to be
      // cheap to lose and large enough not to be all overhead.
      chunkBytes: (json['chunk_bytes'] as num?)?.toInt() ?? 1024 * 1024,
      complete: json['complete'] as bool? ?? (size > 0 && offset >= size),
    );
  }

  /// Bytes still to send.
  int get remaining => size - offset < 0 ? 0 : size - offset;

  UploadHandle at(int newOffset) => UploadHandle(
    uploadId: uploadId,
    offset: newOffset,
    size: size,
    chunkBytes: chunkBytes,
    complete: size > 0 && newOffset >= size,
  );
}

/// The server holds a different amount than the sender thought.
class UploadOffsetMismatch implements Exception {
  UploadOffsetMismatch(this.serverOffset);

  final int serverOffset;

  @override
  String toString() => 'Upload is at $serverOffset bytes on the server';
}

/// The user asked for the send to stop.
class UploadCancelled implements Exception {
  const UploadCancelled();

  @override
  String toString() => 'Upload cancelled';
}

/// The requests a resumable send needs, kept separate from how they travel so
/// the retry and resume behaviour can be tested without a server.
abstract class ResumableUploadTransport {
  Future<UploadHandle> beginUpload({
    required int conversationId,
    required String filename,
    required int size,
    required String type,
    String? mime,
    int? durationMs,
  });

  Future<UploadHandle> uploadProgress(String uploadId);

  Future<UploadHandle> appendUploadChunk({
    required String uploadId,
    required int offset,
    required List<int> bytes,
  });

  Future<ChatMessage> finishUpload({
    required String uploadId,
    File? thumbnail,
    String? caption,
    String? clientId,
    int? replyToMessageId,
  });

  Future<void> abandonUpload(String uploadId);
}

/// Bytes in the next piece: whatever is left, up to the server's chunk size.
int nextChunkLength({
  required int offset,
  required int total,
  required int chunkBytes,
}) {
  if (chunkBytes <= 0) return math.max(0, total - offset);
  return math.max(0, math.min(chunkBytes, total - offset));
}

/// Wait before trying a piece again, growing with each failure and then capped.
///
/// The failures this exists for are a tunnel coming back up and a phone changing
/// network, both of which resolve in seconds; waiting minutes would strand an
/// upload that could have continued.
Duration retryPause(int attempt, {Duration base = const Duration(seconds: 2)}) {
  final grown = base * math.pow(2, math.max(0, attempt - 1)).toDouble();
  const ceiling = Duration(seconds: 30);
  return grown > ceiling ? ceiling : grown;
}

/// Attachments at least this large are sent in resumable pieces.
///
/// Below it the single request is the better trade: one round trip, no session to
/// clean up, and little to lose if it fails. Above it, an interruption that costs
/// the whole transfer is the difference between a file that arrives and one that
/// never does.
const int resumableUploadThresholdBytes = 8 * 1024 * 1024;

bool shouldSendResumably(int sizeBytes, {int threshold = resumableUploadThresholdBytes}) =>
    sizeBytes >= threshold;

const Map<String, String> _mimeByExtension = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  '3gp': 'video/3gpp',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'mp3': 'audio/mpeg',
  'ogg': 'audio/ogg',
  'opus': 'audio/opus',
  'wav': 'audio/wav',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'zip': 'application/zip',
};

/// The file name to show while it is being sent, short enough for a notification.
String uploadLabelFor(String path) {
  final cut = math.max(path.lastIndexOf('/'), path.lastIndexOf(r'\'));
  final name = (cut < 0 ? path : path.substring(cut + 1)).trim();
  if (name.isEmpty) return 'attachment';
  if (name.length <= 32) return name;
  // Keep the extension: "holiday…mp4" still says what kind of thing it is.
  final dot = name.lastIndexOf('.');
  if (dot > 0 && name.length - dot <= 6) {
    return '${name.substring(0, 26)}…${name.substring(dot)}';
  }
  return '${name.substring(0, 31)}…';
}

/// A content type for a file the sender only knows by name.
///
/// The single-request upload gets this from the multipart encoder; a resumable
/// one has no encoder to ask, and a video stored as `application/octet-stream`
/// will not play inline on the other side.
String mimeTypeForUpload(String path, String type) {
  final dot = path.lastIndexOf('.');
  if (dot >= 0 && dot < path.length - 1) {
    final known = _mimeByExtension[path.substring(dot + 1).toLowerCase()];
    if (known != null) return known;
  }
  switch (type) {
    case 'image':
      return 'image/jpeg';
    case 'video':
      return 'video/mp4';
    case 'voice':
      return 'audio/mp4';
    case 'doodle':
      return 'image/png';
    default:
      return 'application/octet-stream';
  }
}

/// Sends one attachment in pieces, continuing from wherever it stopped.
class ResumableUpload {
  ResumableUpload({
    required this.transport,
    this.maxAttemptsPerChunk = 5,
    this.onProgress,
    this.isCancelled,
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? Future<void>.delayed;

  final ResumableUploadTransport transport;

  /// Consecutive failures on the same piece before the send gives up.
  final int maxAttemptsPerChunk;

  final void Function(int sent, int total)? onProgress;

  /// Polled between pieces so a cancel takes effect without killing the app.
  final bool Function()? isCancelled;

  final Future<void> Function(Duration) _sleep;

  Future<ChatMessage> send({
    required int conversationId,
    required File file,
    required String type,
    String? mime,
    int? durationMs,
    File? thumbnail,
    String? caption,
    String? clientId,
    int? replyToMessageId,
    String? resumeUploadId,
    void Function(String uploadId)? onSessionOpened,
  }) async {
    final total = await file.length();
    var handle = resumeUploadId == null
        ? await transport.beginUpload(
            conversationId: conversationId,
            filename: _basename(file.path),
            size: total,
            type: type,
            mime: mime,
            durationMs: durationMs,
          )
        : await transport.uploadProgress(resumeUploadId);
    onSessionOpened?.call(handle.uploadId);
    onProgress?.call(handle.offset, total);

    final source = await file.open();
    try {
      while (true) {
        await _sendRemaining(handle: handle, source: source, total: total, update: (h) => handle = h);
        try {
          return await transport.finishUpload(
            uploadId: handle.uploadId,
            thumbnail: thumbnail,
            caption: caption,
            clientId: clientId,
            replyToMessageId: replyToMessageId,
          );
        } on UploadOffsetMismatch catch (e) {
          // The server has less than we thought; send the difference and retry.
          handle = handle.at(e.serverOffset);
          onProgress?.call(handle.offset, total);
        }
      }
    } finally {
      await source.close();
    }
  }

  Future<void> _sendRemaining({
    required UploadHandle handle,
    required RandomAccessFile source,
    required int total,
    required void Function(UploadHandle) update,
  }) async {
    var current = handle;
    var failures = 0;
    while (current.offset < total) {
      if (isCancelled?.call() ?? false) {
        await _abandonQuietly(current.uploadId);
        throw const UploadCancelled();
      }
      final length = nextChunkLength(
        offset: current.offset,
        total: total,
        chunkBytes: current.chunkBytes,
      );
      await source.setPosition(current.offset);
      final bytes = await source.read(length);
      try {
        current = await transport.appendUploadChunk(
          uploadId: current.uploadId,
          offset: current.offset,
          bytes: bytes,
        );
        failures = 0;
        update(current);
        onProgress?.call(current.offset, total);
      } on UploadOffsetMismatch catch (e) {
        // Believe the server: this is the piece whose reply was lost, or one the
        // server never received. Either way it says exactly where to carry on.
        current = current.at(e.serverOffset);
        failures = 0;
        update(current);
        onProgress?.call(current.offset, total);
      } on UploadCancelled {
        rethrow;
      } catch (_) {
        failures++;
        if (failures >= maxAttemptsPerChunk) rethrow;
        await _sleep(retryPause(failures));
        if (isCancelled?.call() ?? false) {
          await _abandonQuietly(current.uploadId);
          throw const UploadCancelled();
        }
        // The piece may have landed even though the reply did not arrive, so ask
        // rather than assume, and never send the same bytes twice.
        try {
          current = await transport.uploadProgress(current.uploadId);
          update(current);
          onProgress?.call(current.offset, total);
        } catch (_) {
          // Still unreachable; the next attempt will ask again.
        }
      }
    }
    update(current);
  }

  Future<void> _abandonQuietly(String uploadId) async {
    try {
      await transport.abandonUpload(uploadId);
    } catch (_) {
      // A cancelled upload the server never hears about expires on its own.
    }
  }

  String _basename(String path) {
    final cut = math.max(path.lastIndexOf('/'), path.lastIndexOf(r'\'));
    final name = cut < 0 ? path : path.substring(cut + 1);
    return name.isEmpty ? 'file' : name;
  }
}
