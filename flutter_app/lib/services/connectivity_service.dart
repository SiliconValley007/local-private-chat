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
  });

  final ServerStatus status;
  final String baseUrl;
  final String? host;

  /// The server address is inside Tailscale's range, so the VPN is mandatory.
  final bool requiresTailscale;

  /// This phone currently holds a Tailscale address.
  final bool hasTailscaleIp;

  bool get isReachable => status == ServerStatus.ok;

  static const unknown = ServerCheck(
    status: ServerStatus.serverDown,
    baseUrl: '',
  );
}

class ConnectivityService {
  ConnectivityService({this.baseUrlProvider});

  /// Returns current API base URL (may change in settings).
  final String? Function()? baseUrlProvider;

  String get _baseUrl => (baseUrlProvider?.call() ?? AppConfig.defaultServerUrl)
      .replaceAll(RegExp(r'/+$'), '');

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
  Future<ServerCheck> check({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final base = _baseUrl;
    final uri = Uri.tryParse(base);
    if (uri == null || uri.host.isEmpty) {
      return ServerCheck(status: ServerStatus.badAddress, baseUrl: base);
    }

    final requiresTailscale = isTailscaleAddress(uri.host);

    try {
      final res = await http.get(Uri.parse('$base/api/health')).timeout(timeout);
      if (res.statusCode == 200) {
        return ServerCheck(
          status: ServerStatus.ok,
          baseUrl: base,
          host: uri.host,
          requiresTailscale: requiresTailscale,
          hasTailscaleIp: true,
        );
      }
    } catch (_) {
      // Fall through to diagnosis below.
    }

    final addresses = await _localIpv4Addresses();
    final hasTailscaleIp = addresses.any(isTailscaleAddress);

    ServerStatus status;
    if (addresses.isEmpty) {
      // Enumeration worked but found nothing routable, or the OS hid the list.
      // Either way "no network" is the most useful thing to tell the user.
      status = ServerStatus.noNetwork;
    } else if (requiresTailscale && !hasTailscaleIp) {
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
    );
  }

  /// Non-loopback IPv4 addresses of this phone, including the Tailscale tunnel.
  Future<List<String>> _localIpv4Addresses() async {
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
}
