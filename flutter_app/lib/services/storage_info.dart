import '../api_client.dart';

/// A snapshot of the server volume that stores the database and attachments.
class StorageInfo {
  const StorageInfo({required this.freeBytes, required this.totalBytes});

  factory StorageInfo.fromJson(Map<String, dynamic> json) => StorageInfo(
    freeBytes: (json['free_bytes'] as num?)?.toInt() ?? 0,
    totalBytes: (json['total_bytes'] as num?)?.toInt() ?? 0,
  );

  /// Space still available on the server's media volume.
  final int freeBytes;

  /// Total size of that server volume, or 0 when it could not be reported.
  final int totalBytes;

  bool get known => totalBytes > 0;

  int get usedBytes => totalBytes - freeBytes;

  /// Fraction of the server volume in use, for the bar in the share sheet.
  double get usedFraction {
    if (totalBytes <= 0) return 0;
    return (usedBytes / totalBytes).clamp(0.0, 1.0);
  }

  /// Warn below 1 GiB or 10%, whichever is reached first.
  bool get low =>
      known &&
      (freeBytes < 1024 * 1024 * 1024 || freeBytes / totalBytes < 0.10);

  /// At this point uploads and even database writes may begin failing.
  bool get critical =>
      known && (freeBytes < 256 * 1024 * 1024 || freeBytes / totalBytes < 0.02);
}

/// Reads free/total space from the authenticated Local Chat server.
Future<StorageInfo> readStorageInfo(ApiClient api) async =>
    StorageInfo.fromJson(await api.fetchServerStorage());
