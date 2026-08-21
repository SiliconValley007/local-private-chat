import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How long the app may sit in the background before asking for the PIN again.
enum AppLockTimeout { immediately, oneMinute, fiveMinutes }

enum AppLockPreferredAuth { pin, biometric }

Duration appLockTimeoutDuration(AppLockTimeout timeout) => switch (timeout) {
  AppLockTimeout.immediately => Duration.zero,
  AppLockTimeout.oneMinute => const Duration(minutes: 1),
  AppLockTimeout.fiveMinutes => const Duration(minutes: 5),
};

String appLockTimeoutLabel(AppLockTimeout timeout) => switch (timeout) {
  AppLockTimeout.immediately => 'Immediately',
  AppLockTimeout.oneMinute => 'After 1 minute',
  AppLockTimeout.fiveMinutes => 'After 5 minutes',
};

String appLockPreferredAuthLabel(AppLockPreferredAuth auth) => switch (auth) {
  AppLockPreferredAuth.pin => 'PIN',
  AppLockPreferredAuth.biometric => 'Fingerprint or face',
};

/// How long a successful unlock may ignore the following `resumed` event.
///
/// Android's biometric sheet backgrounds Flutter. The success callback is
/// followed immediately by `resumed`, which must not re-arm the lock.
const Duration appLockUnlockGrace = Duration(seconds: 2);

/// Whether a resume should show the lock, given when the app last left.
bool appLockShouldEngage({
  required bool enabled,
  required bool hasPin,
  required DateTime now,
  DateTime? backgroundedAt,
  AppLockTimeout timeout = AppLockTimeout.immediately,
  bool callInProgress = false,
}) {
  if (!enabled || !hasPin) return false;
  // A live call must not be covered by a PIN sheet — the hang-up buttons
  // would vanish, and the other person would hear silence.
  if (callInProgress) return false;
  // Cold start is armed explicitly before the first frame. A resume with no
  // recorded background transition is focus/lifecycle churn, not app leave.
  if (backgroundedAt == null) return false;
  return !now.difference(backgroundedAt).isNegative &&
      now.difference(backgroundedAt) >= appLockTimeoutDuration(timeout);
}

/// The system biometric overlay is not the user leaving the app.
bool appLockShouldIgnoreBackground({required bool biometricPromptActive}) =>
    biometricPromptActive;

/// Skip re-locking when resume arrives right after a successful unlock.
bool appLockSkipEngageAfterUnlock({
  required DateTime now,
  DateTime? unlockedAt,
  Duration grace = appLockUnlockGrace,
}) {
  if (unlockedAt == null) return false;
  final elapsed = now.difference(unlockedAt);
  return !elapsed.isNegative && elapsed < grace;
}

class AppLockSettings {
  const AppLockSettings({
    this.enabled = false,
    this.hasPin = false,
    this.timeout = AppLockTimeout.immediately,
    this.hideNotificationBody = true,
    this.biometricsEnabled = true,
    // Matches [biometricsEnabled] above: where a finger can unlock the app, it
    // is what the lock screen offers first.
    this.preferredAuth = AppLockPreferredAuth.biometric,
  });

  final bool enabled;
  final bool hasPin;
  final AppLockTimeout timeout;
  final bool hideNotificationBody;
  final bool biometricsEnabled;
  final AppLockPreferredAuth preferredAuth;

  /// Whether the lock can actually challenge someone right now.
  ///
  /// Screens must show this rather than [enabled]: a preference saying "on"
  /// with no PIN behind it is a half-finished setup, not a live lock.
  bool get armed => enabled && hasPin;

  AppLockSettings copyWith({
    bool? enabled,
    bool? hasPin,
    AppLockTimeout? timeout,
    bool? hideNotificationBody,
    bool? biometricsEnabled,
    AppLockPreferredAuth? preferredAuth,
  }) {
    return AppLockSettings(
      enabled: enabled ?? this.enabled,
      hasPin: hasPin ?? this.hasPin,
      timeout: timeout ?? this.timeout,
      hideNotificationBody: hideNotificationBody ?? this.hideNotificationBody,
      biometricsEnabled: biometricsEnabled ?? this.biometricsEnabled,
      preferredAuth: preferredAuth ?? this.preferredAuth,
    );
  }
}

/// Device-local PIN and lock preferences. The PIN never leaves this phone.
///
/// The verifier is a salted PBKDF2 digest kept in shared preferences, so the
/// PIN itself is never stored, cheap PIN guessing is deliberately slowed down,
/// and the lock survives every process death and app update. An earlier build
/// kept the PIN only in the platform keystore;
/// when that read came back empty on a cold start the lock quietly disarmed
/// itself, so any keystore value found here is now migrated once and the
/// keystore is never on the path that decides whether the lock is armed.
class AppLockStore {
  AppLockStore({FlutterSecureStorage? secure})
    : _secure = secure ?? const FlutterSecureStorage();

  static const _enabledKey = 'app_lock_enabled_v1';
  static const _timeoutKey = 'app_lock_timeout_v1';
  static const _hideKey = 'app_lock_hide_notice_v1';
  static const _bioKey = 'app_lock_biometrics_v1';
  static const _preferredAuthKey = 'app_lock_preferred_auth_v2';
  // v1 defaulted to PIN in memory and was then written out by any unrelated
  // settings save, so a stored "pin" there recorded a default rather than a
  // decision. Those values are dropped instead of migrated, which is what makes
  // fingerprint the first thing an existing install is offered.
  static const _legacyPreferredAuthKey = 'app_lock_preferred_auth_v1';
  static const _legacyPinKey = 'app_lock_pin_v1';
  static const _saltKey = 'app_lock_salt_v2';
  static const _digestKey = 'app_lock_digest_v2';

  final FlutterSecureStorage _secure;

  Future<AppLockSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateLegacyPin(prefs);
    await prefs.remove(_legacyPreferredAuthKey);
    return AppLockSettings(
      enabled: prefs.getBool(_enabledKey) ?? false,
      hasPin: _storedDigest(prefs) != null,
      timeout: _decodeTimeout(prefs.getString(_timeoutKey)),
      hideNotificationBody: prefs.getBool(_hideKey) ?? true,
      biometricsEnabled: prefs.getBool(_bioKey) ?? true,
      preferredAuth: appLockPreferredAuthOrDefault(
        prefs.getString(_preferredAuthKey),
        biometricsEnabled: prefs.getBool(_bioKey) ?? true,
      ),
    );
  }

  Future<void> saveSettings(AppLockSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, settings.enabled);
    await prefs.setString(_timeoutKey, _encodeTimeout(settings.timeout));
    await prefs.setBool(_hideKey, settings.hideNotificationBody);
    await prefs.setBool(_bioKey, settings.biometricsEnabled);
    await prefs.setString(
      _preferredAuthKey,
      _encodePreferredAuth(settings.preferredAuth),
    );
  }

  /// Stores the verifier for [pin], and reports whether it can be read back.
  ///
  /// Setup must not claim success it cannot honour, so the digest is read again
  /// before the caller is allowed to arm the lock.
  Future<bool> setPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final salt = _newSalt();
    await prefs.setString(_saltKey, salt);
    await prefs.setString(_digestKey, await _digest(pin, salt));
    await prefs.reload();
    return _storedDigest(prefs) != null && await pinMatches(pin);
  }

  Future<bool> pinMatches(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final salt = prefs.getString(_saltKey);
    final digest = _storedDigest(prefs);
    if (salt == null || digest == null) return false;
    return _constantTimeEquals(digest, await _digest(pin, salt));
  }

  Future<void> clearPin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_saltKey);
    await prefs.remove(_digestKey);
    await prefs.setBool(_enabledKey, false);
    await _forgetLegacyPin();
  }

  /// Moves a keystore PIN from an older build into the durable verifier.
  Future<void> _migrateLegacyPin(SharedPreferences prefs) async {
    if (_storedDigest(prefs) != null) return;
    String? legacy;
    try {
      legacy = await _secure.read(key: _legacyPinKey);
    } catch (failure) {
      debugPrint('Could not read the legacy app PIN: $failure');
      return;
    }
    if (legacy == null || legacy.isEmpty) return;
    final salt = _newSalt();
    await prefs.setString(_saltKey, salt);
    await prefs.setString(_digestKey, await _digest(legacy, salt));
    await _forgetLegacyPin();
  }

  Future<void> _forgetLegacyPin() async {
    try {
      await _secure.delete(key: _legacyPinKey);
    } catch (failure) {
      debugPrint('Could not clear the legacy app PIN: $failure');
    }
  }

  String? _storedDigest(SharedPreferences prefs) {
    final digest = prefs.getString(_digestKey);
    if (digest == null || digest.isEmpty) return null;
    return prefs.getString(_saltKey)?.isNotEmpty == true ? digest : null;
  }
}

String _newSalt() {
  final random = Random.secure();
  return base64Url.encode(List<int>.generate(16, (_) => random.nextInt(256)));
}

Future<String> _digest(String pin, String salt) async {
  final key = await Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 120000,
    bits: 256,
  ).deriveKeyFromPassword(password: pin, nonce: base64Url.decode(salt));
  return base64Url.encode(await key.extractBytes());
}

bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var index = 0; index < a.length; index++) {
    difference |= a.codeUnitAt(index) ^ b.codeUnitAt(index);
  }
  return difference == 0;
}

String _encodeTimeout(AppLockTimeout timeout) => switch (timeout) {
  AppLockTimeout.immediately => '0',
  AppLockTimeout.oneMinute => '60',
  AppLockTimeout.fiveMinutes => '300',
};

AppLockTimeout _decodeTimeout(String? raw) => switch (raw) {
  '60' => AppLockTimeout.oneMinute,
  '300' => AppLockTimeout.fiveMinutes,
  _ => AppLockTimeout.immediately,
};

String _encodePreferredAuth(AppLockPreferredAuth auth) => switch (auth) {
  AppLockPreferredAuth.pin => 'pin',
  AppLockPreferredAuth.biometric => 'biometric',
};

/// Resolves the saved unlock choice, defaulting to fingerprint when possible.
///
/// A phone that can unlock by fingerprint should do so without being asked to
/// configure it: typing a PIN when a finger would do is the whole complaint.
/// Only a stored value counts as a decision, so someone who deliberately picks
/// PIN keeps it, while installs made before this setting existed are treated as
/// "never chose" and follow the fingerprint switch.
AppLockPreferredAuth appLockPreferredAuthOrDefault(
  String? raw, {
  required bool biometricsEnabled,
}) => switch (raw) {
  'biometric' => AppLockPreferredAuth.biometric,
  'pin' => AppLockPreferredAuth.pin,
  _ => biometricsEnabled
      ? AppLockPreferredAuth.biometric
      : AppLockPreferredAuth.pin,
};

bool isValidAppLockPin(String pin) {
  if (pin.length < 4 || pin.length > 8) return false;
  return RegExp(r'^\d+$').hasMatch(pin);
}
