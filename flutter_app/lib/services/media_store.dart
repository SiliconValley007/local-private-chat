import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api_client.dart';
import '../errors.dart';
import '../models.dart';

/// Result of asking the user to save an attachment somewhere on the phone.
enum SaveOutcome { saved, cancelled }

/// Thrown when a download is stopped on purpose, so the UI can stay quiet
/// instead of showing a scary network error.
class DownloadCancelled implements Exception {
  const DownloadCancelled();

  @override
  String toString() => 'Download cancelled';
}

/// Downloads chat attachments once, keeps them on the phone, and hands them to
/// the gallery/file apps when asked.
///
/// Attachments live behind an authenticated endpoint, so nothing can be fetched
/// by a plain URL; every request here carries the session token.
class MediaStore {
  MediaStore(this._api);

  final ApiClient _api;

  /// Downloads already running, keyed by message id, so a rebuild storm can't
  /// start the same download several times.
  final Map<int, Future<File>> _inFlight = {};

  /// The live HTTP client per in-flight download, so a download can be
  /// cancelled by closing its socket without disturbing other transfers.
  final Map<int, http.Client> _clients = {};

  Directory? _cacheDir;

  Future<Directory> _dir() async {
    final existing = _cacheDir;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/attachments');
    if (!await dir.exists()) await dir.create(recursive: true);
    _cacheDir = dir;
    return dir;
  }

  static String _safeName(ChatMessage msg) {
    final raw = (msg.mediaName ?? '').trim();
    final name = raw.isEmpty ? 'attachment_${msg.id}' : raw;
    return name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }

  Future<File> _target(ChatMessage msg) async {
    final dir = await _dir();
    return File('${dir.path}/${msg.id}_${_safeName(msg)}');
  }

  /// The already-downloaded file, or null when it still has to be fetched.
  Future<File?> cached(ChatMessage msg) async {
    final file = await _target(msg);
    if (!await file.exists()) return null;
    final expected = msg.mediaSize;
    if (expected != null && expected > 0 && await file.length() != expected) {
      return null; // Partial or stale download; fetch it again.
    }
    return file;
  }

  /// Downloads the attachment if needed and returns the local copy.
  Future<File> ensureLocal(
    ChatMessage msg, {
    void Function(double progress)? onProgress,
  }) {
    final running = _inFlight[msg.id];
    if (running != null) return running;
    final future = _fetch(msg, onProgress).whenComplete(() {
      _inFlight.remove(msg.id);
      _clients.remove(msg.id);
    });
    _inFlight[msg.id] = future;
    return future;
  }

  /// Stops an in-flight download for [messageId]. The pending `ensureLocal`
  /// future completes with an error, which callers surface as "cancelled".
  void cancelDownload(int messageId) {
    final client = _clients.remove(messageId);
    client?.close();
  }

  Future<File> _fetch(
    ChatMessage msg,
    void Function(double progress)? onProgress,
  ) async {
    final existing = await cached(msg);
    if (existing != null) return existing;

    final client = http.Client();
    _clients[msg.id] = client;
    try {
      final request = http.Request('GET', Uri.parse(_api.mediaUrl(msg.id)));
      request.headers['Authorization'] = 'Bearer ${_api.token}';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 404) {
        throw ApiException(
          'This attachment is no longer on the server.',
          statusCode: 404,
        );
      }
      if (response.statusCode >= 400) {
        throw ApiException(
          statusMessageFor(response.statusCode),
          statusCode: response.statusCode,
        );
      }

      final total = response.contentLength ?? msg.mediaSize ?? 0;
      // Written to a temporary name first so a failed download never leaves a
      // half-file that later looks like a valid cache hit.
      final file = await _target(msg);
      final partial = File('${file.path}.part');
      // Streamed straight to disk rather than gathered in memory: a video can
      // be hundreds of megabytes, and holding one whole would kill the app.
      final sink = partial.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call((received / total).clamp(0.0, 1.0));
        }
        await sink.flush();
      } on http.ClientException {
        // A closed socket here is almost always a user cancellation; the
        // half-written .part file is removed below so it never poses as cache.
        await sink.close();
        await partial.delete().catchError((_) => partial);
        throw const DownloadCancelled();
      } finally {
        await sink.close();
      }

      if (await file.exists()) await file.delete();
      await partial.rename(file.path);
      onProgress?.call(1);
      return file;
    } finally {
      client.close();
    }
  }

  /// How many bytes the downloaded attachments take up on this phone.
  Future<int> cacheSize() async {
    try {
      final dir = await _dir();
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {
            // Vanished mid-scan; it contributes nothing either way.
          }
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Deletes every downloaded attachment and reports how much that freed.
  ///
  /// Nothing is lost: the originals stay on the chat server, so anything opened
  /// again is simply fetched once more.
  Future<int> clearCache() async {
    var freed = 0;
    try {
      final dir = await _dir();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        try {
          freed += await entity.length();
          await entity.delete();
        } catch (_) {
          // Locked or already gone; keep clearing the rest.
        }
      }
    } catch (_) {
      // Nothing cached yet.
    }
    return freed;
  }

  /// Removes local copies belonging to one server message.
  Future<void> evict(int messageId) async {
    _inFlight.remove(messageId);
    try {
      final dir = await _dir();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('${messageId}_')) continue;
        try {
          await entity.delete();
        } catch (_) {
          // Already gone or temporarily locked.
        }
      }
    } catch (_) {
      // Cache may not exist yet.
    }
  }

  /// Opens the attachment in whatever app the phone uses for that file type.
  Future<void> openExternally(ChatMessage msg) async {
    final file = await ensureLocal(msg);
    final result = await OpenFilex.open(file.path);
    if (result.type != ResultType.done) {
      throw ApiException(
        result.type == ResultType.noAppToOpen
            ? "No app on this phone can open ${_safeName(msg)}."
            : "That file couldn't be opened.",
      );
    }
  }

  /// Lets the user pick a folder and writes the file there, WhatsApp-style
  /// "save to phone". Uses the system save dialog, so no storage permission
  /// prompt is needed on any Android version.
  Future<SaveOutcome> saveToDevice(
    ChatMessage msg, {
    void Function(double progress)? onProgress,
  }) async {
    final file = await ensureLocal(msg, onProgress: onProgress);
    final bytes = await file.readAsBytes();
    final path = await FilePicker.platform.saveFile(
      fileName: _safeName(msg),
      bytes: bytes,
    );
    return path == null ? SaveOutcome.cancelled : SaveOutcome.saved;
  }

  Future<void> share(ChatMessage msg) async {
    final file = await ensureLocal(msg);
    await Share.shareXFiles([
      XFile(file.path, mimeType: msg.mediaMime, name: _safeName(msg)),
    ]);
  }
}
