import 'package:shared_preferences/shared_preferences.dart';

/// Local-only media behaviour prefs (never leave the phone).
class MediaPrefs {
  const MediaPrefs({this.wifiOnlyVideoDownload = false});

  final bool wifiOnlyVideoDownload;

  MediaPrefs copyWith({bool? wifiOnlyVideoDownload}) => MediaPrefs(
    wifiOnlyVideoDownload: wifiOnlyVideoDownload ?? this.wifiOnlyVideoDownload,
  );

  Map<String, dynamic> toJson() => {'wifi_only_video': wifiOnlyVideoDownload};

  factory MediaPrefs.fromJson(Map<String, dynamic> json) => MediaPrefs(
    wifiOnlyVideoDownload: json['wifi_only_video'] as bool? ?? false,
  );
}

class MediaPrefsStore {
  static const _key = 'media_prefs_v1';

  static Future<MediaPrefs> load() async {
    final prefs = await SharedPreferences.getInstance();
    final wifi = prefs.getBool(_key);
    if (wifi == null) return const MediaPrefs();
    return MediaPrefs(wifiOnlyVideoDownload: wifi);
  }

  static Future<void> save(MediaPrefs value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value.wifiOnlyVideoDownload);
  }
}
