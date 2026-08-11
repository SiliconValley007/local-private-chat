import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
    });
    _inFlight[msg.id] = future;
    return future;
  }

  Future<File> _fetch(
    ChatMessage msg,
    void Function(double progress)? onProgress,
  ) async {
    final existing = await cached(msg);
    if (existing != null) return existing;

    final client = http.Client();
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
      final chunks = <int>[];
      var received = 0;
      await for (final chunk in response.stream) {
        chunks.addAll(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call((received / total).clamp(0.0, 1.0));
      }

      // Written to a temporary name first so a failed download never leaves a
      // half-file that later looks like a valid cache hit.
      final file = await _target(msg);
      final partial = File('${file.path}.part');
      await partial.writeAsBytes(Uint8List.fromList(chunks), flush: true);
      if (await file.exists()) await file.delete();
      await partial.rename(file.path);
      onProgress?.call(1);
      return file;
    } finally {
      client.close();
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
  Future<SaveOutcome> saveToDevice(ChatMessage msg) async {
    final file = await ensureLocal(msg);
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
