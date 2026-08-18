import 'dart:io';

import 'package:http/http.dart' as http;

import '../app_config.dart';

/// Why the app can or can't talk to the private chat server.
enum ServerStatus {
  /// The server answered its health check.
  ok,

  /// The server URL isn't a usable address.
  badAddress,

  /// This phone has no usable network at all (no Wi-Fi, no mobile data).
  noNetwork,

  /// The server lives on a Tailscale address but this phone has no Tailscale IP,
  /// so the VPN is off or still connecting.
  tailscaleOff,

  /// The network looks fine, but nothing answered at the server address —
  /// almost always the chat server not running on the other phone.
  serverDown,
}

/// Result of one connectivity check, with enough detail to explain the problem.
class ServerCheck {
  const ServerCheck({
    required this.status,
    required this.baseUrl,
    this.host,
    this.requiresTailscale = false,
    this.hasTailscaleIp = false,
    this.hadTailscaleIpBeforeProbe = false,
  });

  final ServerStatus status;
  final String baseUrl;
  final String? host;

  /// The server address is inside Tailscale's range, so the VPN is mandatory.
  final bool requiresTailscale;

  /// This phone currently holds a Tailscale address.
  final bool hasTailscaleIp;

  /// Whether Tailscale was already present before this health check began.
  ///
  /// This snapshot is intentionally separate from [hasTailscaleIp]. A tunnel
  /// can appear while a slow probe is in flight; ownership decisions need to
  /// know what existed before Local Chat sent a connect request.
  final bool hadTailscaleIpBeforeProbe;

  bool get isReachable => status == ServerStatus.ok;

  static const unknown = ServerCheck(
    status: ServerStatus.serverDown,
    baseUrl: '',
  );
}

class ConnectivityService {
  ConnectivityService({
    this.baseUrlProvider,
    http.Client Function()? clientFactory,
    this.addressProvider,
  }) : _clientFactory = clientFactory ?? http.Client.new {
    _client = _clientFactory();
  }

  /// Returns current API base URL (may change in settings).
  final String? Function()? baseUrlProvider;

  /// How a probing client is made. Injectable so tests can drive the retry
  /// behaviour without a real network.
  final http.Client Function() _clientFactory;
  final Future<List<String>> Function()? addressProvider;

  String get _baseUrl => (baseUrlProvider?.call() ?? AppConfig.defaultServerUrl)
      .replaceAll(RegExp(r'/+$'), '');

  /// One client for every probe. A kept-alive connection makes the repeated
  /// health checks much cheaper than opening a fresh socket each time, which
  /// matters on a metered or weak link.
  late http.Client _client;

  /// Gap before a retry, long enough for a waking radio to finish coming up.
  static const _retryGap = Duration(milliseconds: 500);

  void dispose() => _client.close();

  /// Throws away the pooled connections.
  ///
  /// After a tunnel drops, the pool can hold a socket that looks open but goes
  /// nowhere, which would keep failing every future probe and make a running
  /// server look permanently dead. Starting clean removes that trap.
  void _resetClient() {
    try {
      _client.close();
    } catch (_) {
      // Already closed or never used; a fresh client is all that matters.
    }
    _client = _clientFactory();
  }

  /// True when addr is inside Tailscale's CGNAT range 100.64.0.0/10.
  static bool isTailscaleAddress(String addr) {
    final parts = addr.split('.');
    if (parts.length != 4 || parts[0] != '100') return false;
    final second = int.tryParse(parts[1]);
    return second != null && second >= 64 && second <= 127;
  }

  /// Checks the server and, when it fails, works out *why* so the UI can say so.
  ///
  /// The health check is the only source of truth for "is it working". Interface
  /// inspection is used solely to explain a failure, never to declare one.
  /// [attempts] is how many probes must fail before a failure is believed.
  Future<ServerCheck> check({
    Duration timeout = const Duration(seconds: 5),
    int attempts = 3,
  }) async {
    final base = _baseUrl;
    final uri = Uri.tryParse(base);
    if (uri == null || uri.host.isEmpty) {
      return ServerCheck(status: ServerStatus.badAddress, baseUrl: base);
    }

    final requiresTailscale = isTailscaleAddress(uri.host);
    final healthUri = Uri.parse('$base/api/health');
    // Snapshot before any potentially slow retry. If Tailscale appears while
    // probing, the caller can still prove that it was absent at the start.
    final addressesBefore = await _localIpv4Addresses();
    final hadTailscaleIpBeforeProbe = addressesBefore.any(isTailscaleAddress);

    // A tunnel waking from idle regularly loses the first probe: the radio is
    // still coming up, or Tailscale is renegotiating its path to the peer. One
    // lost packet must never be announced as "the chat server is not running",
    // so a failure is only trusted once every attempt has failed. A healthy
    // server still answers on the first try, so nothing gets slower when all
    // is well.
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0) await Future<void>.delayed(_retryGap);
      try {
        final res = await _client
            .get(healthUri)
            // Later attempts get more room: a slow path is the usual reason the
            // previous one ran out of time.
            .timeout(timeout + Duration(seconds: 2 * attempt));
        if (res.statusCode == 200) {
          return ServerCheck(
            status: ServerStatus.ok,
            baseUrl: base,
            host: uri.host,
            requiresTailscale: requiresTailscale,
            hasTailscaleIp: true,
            hadTailscaleIpBeforeProbe: hadTailscaleIpBeforeProbe,
          );
        }
      } catch (_) {
        // Retry, then diagnose below once the attempts are used up.
      }
    }

    // Every probe failed, so drop any connection that may have gone stale.
    _resetClient();

    final addresses = await _localIpv4Addresses();
    final hasTailscaleIp = addresses.any(isTailscaleAddress);

    ServerStatus status;
    if (addressesBefore.isEmpty && addresses.isEmpty) {
      // Enumeration worked but found nothing routable, or the OS hid the list.
      // Either way "no network" is the most useful thing to tell the user.
      status = ServerStatus.noNetwork;
    } else if (requiresTailscale && !hadTailscaleIpBeforeProbe) {
      status = ServerStatus.tailscaleOff;
    } else {
      status = ServerStatus.serverDown;
    }

    return ServerCheck(
      status: status,
      baseUrl: base,
      host: uri.host,
      requiresTailscale: requiresTailscale,
      hasTailscaleIp: hasTailscaleIp,
      hadTailscaleIpBeforeProbe: hadTailscaleIpBeforeProbe,
    );
  }

  /// Non-loopback IPv4 addresses of this phone, including the Tailscale tunnel.
  Future<List<String>> _localIpv4Addresses() async {
    final provider = addressProvider;
    if (provider != null) return provider();
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      return [
        for (final interface in interfaces)
          for (final addr in interface.addresses) addr.address,
      ];
    } catch (_) {
      // Some Android builds refuse to list interfaces. Returning a placeholder
      // keeps us from wrongly claiming the phone is offline.
      return const ['0.0.0.0'];
    }
  }

  /// True when the phone looks to be on Wi‑Fi / Ethernet (not cellular-only).
  ///
  /// Used for the optional "Wi‑Fi only video download" preference. Interface
  /// names vary by OEM; private LAN addresses that aren't Tailscale also count.
  Future<bool> looksLikeWifiOrLan() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (name.contains('wlan') ||
            name.contains('wifi') ||
            name.contains('eth') ||
            name.startsWith('en')) {
          return true;
        }
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (isTailscaleAddress(ip)) continue;
          if (_isPrivateLan(ip)) return true;
        }
      }
    } catch (_) {
      // If we can't tell, don't block the user.
      return true;
    }
    return false;
  }

  static bool _isPrivateLan(String addr) {
    final parts = addr.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    return false;
  }
}
