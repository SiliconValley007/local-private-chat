import 'package:shared_preferences/shared_preferences.dart';

import 'tailscale_assist.dart';

/// How Local Chat is allowed to drive the separate Tailscale app.
///
/// Both switches live on this phone only and default to on: the app is useless
/// without the tunnel, and someone who opened Local Chat almost always wants it.
class TailscalePrefs {
  const TailscalePrefs({
    this.autoConnect = true,
    this.autoDisconnectOnExit = true,
  });

  /// Ask Tailscale to connect when the app opens or resumes.
  final bool autoConnect;

  /// Ask Tailscale to disconnect when Local Chat is closed for good — but only
  /// when Local Chat is what turned it on, so other apps keep their tunnel.
  final bool autoDisconnectOnExit;

  TailscalePrefs copyWith({bool? autoConnect, bool? autoDisconnectOnExit}) =>
      TailscalePrefs(
        autoConnect: autoConnect ?? this.autoConnect,
        autoDisconnectOnExit: autoDisconnectOnExit ?? this.autoDisconnectOnExit,
      );
}

class TailscalePrefsStore {
  static const _autoConnectKey = 'tailscale_auto_connect_v1';
  static const _autoDisconnectKey = 'tailscale_auto_disconnect_v1';
  static const _startedByAppKey = 'tailscale_started_by_app_v1';
  static const _phaseKey = 'tailscale_ownership_phase_v2';

  static Future<TailscalePrefs> load() async {
    final prefs = await SharedPreferences.getInstance();
    return TailscalePrefs(
      autoConnect: prefs.getBool(_autoConnectKey) ?? true,
      autoDisconnectOnExit: prefs.getBool(_autoDisconnectKey) ?? true,
    );
  }

  static Future<void> save(TailscalePrefs value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoConnectKey, value.autoConnect);
    await prefs.setBool(_autoDisconnectKey, value.autoDisconnectOnExit);
  }

  /// Dart-side mirror of native ownership. Android native prefs win on conflict.
  static Future<TailscaleOwnershipPhase> loadPhase() async {
    final prefs = await SharedPreferences.getInstance();
    final wire = prefs.getString(_phaseKey);
    if (wire != null) return TailscaleOwnershipPhase.fromWire(wire);
    return (prefs.getBool(_startedByAppKey) ?? false)
        ? TailscaleOwnershipPhase.owned
        : TailscaleOwnershipPhase.unowned;
  }

  static Future<void> savePhase(TailscaleOwnershipPhase phase) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_phaseKey, phase.wire);
    await prefs.setBool(_startedByAppKey, phase.isOwned);
  }

  @Deprecated('Use loadPhase(); native prefs are authoritative on Android.')
  static Future<bool> loadStartedByApp() async {
    final phase = await loadPhase();
    return phase.isOwned;
  }

  @Deprecated('Use savePhase(); native prefs are authoritative on Android.')
  static Future<void> saveStartedByApp(bool value) async {
    await savePhase(
      value ? TailscaleOwnershipPhase.owned : TailscaleOwnershipPhase.unowned,
    );
  }
}
