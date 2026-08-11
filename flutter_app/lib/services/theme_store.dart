import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the appearance the user picked.
///
/// Stored in `SharedPreferences`, so the choice survives restarts and app
/// updates and is only forgotten when the app is uninstalled. The default is
/// [ThemeMode.system], which follows the phone's light/dark setting.
class ThemeStore {
  static const _key = 'theme_mode_v1';

  static Future<ThemeMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    return decode(prefs.getString(_key));
  }

  static Future<void> save(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, encode(mode));
  }

  static String encode(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  };

  /// Unknown or missing values fall back to following the system.
  static ThemeMode decode(String? raw) => switch (raw) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String labelFor(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
    ThemeMode.system => 'Same as system',
  };
}
