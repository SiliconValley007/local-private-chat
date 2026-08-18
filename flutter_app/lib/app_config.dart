/// App-wide defaults. Change [defaultServerUrl] if the Tailscale server IP changes.
class AppConfig {
  AppConfig._();

  /// realme-2 Tailscale IPv4 — phones use this unless overridden in Settings.
  static const String defaultServerUrl = 'http://100.71.32.92:8000';

  /// Invite QR / deep-link scheme (username only — no secrets).
  static const String inviteScheme = 'localchat';

  /// Builds an invite for [username].
  ///
  /// The address of the chat server rides along because a username alone is
  /// useless to someone whose phone still points at a different server — which
  /// is everyone who has not been set up by hand. It is not a secret: reaching
  /// it still requires being on the tailnet, and logging in still requires an
  /// account.
  static String inviteUri(String username, {String? serverUrl}) {
    final base = '$inviteScheme://user/$username';
    final server = serverUrl?.trim().replaceAll(RegExp(r'/+$'), '') ?? '';
    if (server.isEmpty) return base;
    return '$base?server=${Uri.encodeComponent(server)}';
  }

  static String? usernameFromInvite(String raw) => parseInvite(raw)?.username;

  /// Reads an invite link, an invite QR payload, or a bare username.
  static Invite? parseInvite(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    final uri = Uri.tryParse(text);
    if (uri != null && uri.scheme == inviteScheme && uri.host == 'user') {
      final username = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.first
          : '';
      if (username.isEmpty) return null;
      return Invite(
        username: username,
        serverUrl: _cleanServer(uri.queryParameters['server']),
      );
    }

    // Plain username pasted.
    if (RegExp(r'^[A-Za-z0-9_-]{3,40}$').hasMatch(text)) {
      return Invite(username: text);
    }
    return null;
  }

  /// Accepts only an http(s) address, so a malformed or hostile `server=` value
  /// can never be written into settings.
  static String? _cleanServer(String? raw) {
    final text = raw?.trim().replaceAll(RegExp(r'/+$'), '') ?? '';
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return text;
  }
}

/// Who to add, and where their server lives.
class Invite {
  const Invite({required this.username, this.serverUrl});

  final String username;

  /// The inviter's server address, when their link carried one.
  final String? serverUrl;

  /// True when [serverUrl] is set and differs from [current].
  bool pointsElsewhere(String? current) {
    final server = serverUrl;
    if (server == null) return false;
    final now = current?.trim().replaceAll(RegExp(r'/+$'), '') ?? '';
    return server != now;
  }
}
