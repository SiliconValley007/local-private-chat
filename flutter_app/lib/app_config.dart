/// App-wide defaults. Change [defaultServerUrl] if the Tailscale server IP changes.
class AppConfig {
  AppConfig._();

  /// realme-2 Tailscale IPv4 — phones use this unless overridden in Settings.
  static const String defaultServerUrl = 'http://100.71.32.92:8000';

  /// Invite QR / deep-link scheme (username only — no secrets).
  static const String inviteScheme = 'localchat';

  static String inviteUri(String username) => '$inviteScheme://user/$username';

  static String? usernameFromInvite(String raw) {
    final text = raw.trim();
    final uri = Uri.tryParse(text);
    if (uri != null && uri.scheme == inviteScheme && uri.host == 'user') {
      final user = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
      return user.isEmpty ? null : user;
    }
    // Plain username pasted
    if (RegExp(r'^[A-Za-z0-9_-]{3,40}$').hasMatch(text)) return text;
    return null;
  }
}
