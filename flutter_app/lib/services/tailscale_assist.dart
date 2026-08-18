import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'connectivity_service.dart';

/// Durable ownership phases for the Tailscale tunnel on this phone.
enum TailscaleOwnershipPhase {
  unowned,
  pendingConnect,
  owned;

  static TailscaleOwnershipPhase fromWire(String? wire) {
    switch (wire) {
      case 'pending_connect':
        return TailscaleOwnershipPhase.pendingConnect;
      case 'owned':
        return TailscaleOwnershipPhase.owned;
      default:
        return TailscaleOwnershipPhase.unowned;
    }
  }

  String get wire {
    switch (this) {
      case TailscaleOwnershipPhase.unowned:
        return 'unowned';
      case TailscaleOwnershipPhase.pendingConnect:
        return 'pending_connect';
      case TailscaleOwnershipPhase.owned:
        return 'owned';
    }
  }

  bool get isOwned => this == TailscaleOwnershipPhase.owned;
}

/// Snapshot read from native prefs (authoritative on Android).
class TailscaleOwnershipSnapshot {
  const TailscaleOwnershipSnapshot({
    required this.phase,
    required this.connectRequestedAtMs,
    required this.autoDisconnectEnabled,
  });

  final TailscaleOwnershipPhase phase;
  final int connectRequestedAtMs;
  final bool autoDisconnectEnabled;

  DateTime? get connectRequestedAt {
    if (connectRequestedAtMs <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(connectRequestedAtMs);
  }

  static const empty = TailscaleOwnershipSnapshot(
    phase: TailscaleOwnershipPhase.unowned,
    connectRequestedAtMs: 0,
    autoDisconnectEnabled: false,
  );

  factory TailscaleOwnershipSnapshot.fromChannel(Object? raw) {
    if (raw is! Map) return empty;
    return TailscaleOwnershipSnapshot(
      phase: TailscaleOwnershipPhase.fromWire(raw['phase'] as String?),
      connectRequestedAtMs: (raw['connectRequestedAtMs'] as num?)?.toInt() ?? 0,
      autoDisconnectEnabled: raw['enabled'] as bool? ?? false,
    );
  }
}

/// Drives the separate Tailscale Android app on this phone.
///
/// Local Chat cannot own the system VPN — only Tailscale can. What we can do is
/// send the same broadcasts Tasker uses (`CONNECT_VPN` / `DISCONNECT_VPN`).
/// Those are requests, not guarantees: the user must already have Tailscale
/// installed, signed in, and holding VPN permission. On some OEMs the receiver
/// is dead until Tailscale was opened recently, which is why the gate screen
/// also offers "Open Tailscale app".
class TailscaleAssist {
  TailscaleAssist();

  static const packageName = 'com.tailscale.ipn';
  static const connectAction = 'com.tailscale.ipn.CONNECT_VPN';
  static const disconnectAction = 'com.tailscale.ipn.DISCONNECT_VPN';
  static const receiverClass = 'com.tailscale.ipn.IPNReceiver';

  /// Handles ownership persistence and the disconnect that outlives our isolate.
  static const _exitChannel = MethodChannel('local_chat/tailscale');

  /// Don't spam Tailscale's receiver on every health poll.
  static const nudgeCooldown = Duration(seconds: 20);

  /// How long [pendingConnect] may wait before routing that appears is treated
  /// as someone else's tunnel.
  static const connectClaimWindow = Duration(seconds: 30);

  DateTime? _lastNudgeAt;

  /// Pure policy: when is it worth asking Tailscale to connect?
  ///
  /// True when the configured server lives on the Tailscale mesh, or the last
  /// check already blamed a missing Tailscale address. LAN-only servers are
  /// left alone so we never wake the VPN for no reason.
  static bool shouldNudge({
    required String? serverUrl,
    ServerCheck? lastCheck,
  }) {
    final host = Uri.tryParse(serverUrl ?? '')?.host;
    if (host != null && ConnectivityService.isTailscaleAddress(host)) {
      return true;
    }
    if (lastCheck?.requiresTailscale == true) return true;
    if (lastCheck?.status == ServerStatus.tailscaleOff) return true;
    return false;
  }

  /// Pure policy: may we turn the tunnel off when the app leaves?
  ///
  /// Anything but [TailscaleOwnershipPhase.unowned] counts. A pending connect
  /// is only recorded when routing was down beforehand, so it means this app
  /// asked Tailscale to come up and never got its confirmation — still our
  /// tunnel to close. Native policy reads the same rule.
  static bool shouldDisconnectOnExit({
    required bool enabled,
    required TailscaleOwnershipPhase phase,
  }) => enabled && phase != TailscaleOwnershipPhase.unowned;

  /// Legacy bool mirror for settings copy.
  static bool shouldDisconnectOnExitLegacy({
    required bool enabled,
    required bool startedByApp,
  }) => enabled && startedByApp;

  static bool tunnelIsUp(ServerCheck? check) {
    if (check == null) return false;
    if (check.hasTailscaleIp) return true;
    return check.requiresTailscale && check.isReachable;
  }

  static bool tunnelRoutingIsUp(ServerCheck? check) {
    if (check == null) return false;
    return check.requiresTailscale && check.isReachable;
  }

  static bool requestRaisedTunnel({
    required bool awaitingRequest,
    required bool? previousRouting,
    required ServerCheck check,
  }) =>
      awaitingRequest &&
      (previousRouting ?? false) == false &&
      tunnelRoutingIsUp(check);

  static bool provedNoTunnel(ServerCheck? check) =>
      check?.status == ServerStatus.tailscaleOff;

  /// Routing was down before a connect request — includes [ServerStatus.serverDown]
  /// with a 100.x interface but no route, fixing the connect-vs-claim mismatch.
  static bool routingWasDownBeforeConnect(ServerCheck? check) {
    if (check == null) return false;
    if (provedNoTunnel(check)) return true;
    if (check.requiresTailscale && !tunnelRoutingIsUp(check)) return true;
    return false;
  }

  /// Tunnel already routing before we asked — never enter [pendingConnect].
  static bool preexistingRoutedTunnel(ServerCheck? check) =>
      check != null && tunnelRoutingIsUp(check);

  static bool awaitingConnectClaim({
    required DateTime? connectRequestedAt,
    required DateTime now,
    Duration claimWindow = connectClaimWindow,
  }) {
    if (connectRequestedAt == null) return false;
    return now.difference(connectRequestedAt) < claimWindow;
  }

  /// Pure transition table driven by connectivity observations.
  static TailscaleOwnershipPhase transitionOnConnectivityCheck({
    required TailscaleOwnershipPhase phase,
    required ServerCheck check,
    required bool? previousRouting,
    required DateTime? connectRequestedAt,
    required DateTime now,
    Duration claimWindow = connectClaimWindow,
  }) {
    final routingUp = tunnelRoutingIsUp(check);
    final tunnelUp = tunnelIsUp(check);
    final awaiting = awaitingConnectClaim(
      connectRequestedAt: connectRequestedAt,
      now: now,
      claimWindow: claimWindow,
    );

    if (phase == TailscaleOwnershipPhase.owned &&
        !tunnelUp &&
        provedNoTunnel(check)) {
      return TailscaleOwnershipPhase.unowned;
    }

    if (phase == TailscaleOwnershipPhase.unowned &&
        preexistingRoutedTunnel(check)) {
      return TailscaleOwnershipPhase.unowned;
    }

    if (phase == TailscaleOwnershipPhase.pendingConnect) {
      final weRaisedIt = requestRaisedTunnel(
        awaitingRequest: awaiting,
        previousRouting: previousRouting,
        check: check,
      );
      if (weRaisedIt) return TailscaleOwnershipPhase.owned;

      if (routingUp && !awaiting && connectRequestedAt != null) {
        return TailscaleOwnershipPhase.unowned;
      }

      if (provedNoTunnel(check) && !awaiting) {
        return TailscaleOwnershipPhase.unowned;
      }
    }

    return phase;
  }

  static bool resolveOwnership({
    required bool remembered,
    required bool tunnelUp,
    required bool weRaisedIt,
  }) {
    if (!tunnelUp) return false;
    if (weRaisedIt) return true;
    return remembered;
  }

  static bool cooldownElapsed(
    DateTime? lastNudgeAt,
    DateTime now, {
    Duration cooldown = nudgeCooldown,
  }) {
    if (lastNudgeAt == null) return true;
    return now.difference(lastNudgeAt) >= cooldown;
  }

  static int phaseRank(TailscaleOwnershipPhase phase) {
    switch (phase) {
      case TailscaleOwnershipPhase.owned:
        return 3;
      case TailscaleOwnershipPhase.pendingConnect:
        return 2;
      case TailscaleOwnershipPhase.unowned:
        return 1;
    }
  }

  /// Stale native reads must not downgrade a fresher local [owned] claim.
  static bool shouldAcceptNativePhase({
    required TailscaleOwnershipPhase local,
    required TailscaleOwnershipPhase native,
  }) {
    if (native == TailscaleOwnershipPhase.unowned) return true;
    return phaseRank(native) >= phaseRank(local);
  }

  /// Merge flags when overlapping health checks coalesce instead of dropping.
  static bool mergeCoalescedQuick({
    required bool existing,
    required bool incoming,
  }) => existing && incoming;

  static bool mergeCoalescedNudge({
    required bool existing,
    required bool incoming,
  }) => existing || incoming;

  Future<TailscaleOwnershipSnapshot> readOwnershipSnapshot() async {
    if (!Platform.isAndroid) return TailscaleOwnershipSnapshot.empty;
    try {
      final raw = await _exitChannel.invokeMethod<Object>('getExitPolicy');
      return TailscaleOwnershipSnapshot.fromChannel(raw);
    } on MissingPluginException {
      return TailscaleOwnershipSnapshot.empty;
    } catch (e) {
      debugPrint('Could not read Tailscale ownership: $e');
      return TailscaleOwnershipSnapshot.empty;
    }
  }

  Future<void> retryInterruptedDisconnect() async {
    if (!Platform.isAndroid) return;
    try {
      await _exitChannel.invokeMethod<void>('retryInterruptedDisconnect');
    } on MissingPluginException {
      // Older host build.
    } catch (e) {
      debugPrint('Tailscale disconnect retry failed: $e');
    }
  }

  Future<bool> isInstalled() async {
    if (!Platform.isAndroid) return false;
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.MAIN',
        category: 'android.intent.category.LAUNCHER',
        package: packageName,
      );
      return await intent.canResolveActivity() ?? false;
    } catch (e) {
      debugPrint('Tailscale install check failed: $e');
      return false;
    }
  }

  /// Records connect intent in native prefs, then broadcasts CONNECT_VPN.
  Future<bool> requestConnect({
    bool force = false,
    required ServerCheck? lastCheck,
  }) async {
    if (!Platform.isAndroid) return false;
    final now = DateTime.now();
    if (!force && !cooldownElapsed(_lastNudgeAt, now)) return false;

    final routingWasDown = routingWasDownBeforeConnect(lastCheck);
    final routingAlreadyUp = preexistingRoutedTunnel(lastCheck);

    try {
      final sent = await _exitChannel.invokeMethod<bool>('requestConnect', {
        'routingWasDown': routingWasDown,
        'routingAlreadyUp': routingAlreadyUp,
      });
      // Honor native false (e.g. exit disconnect guard) — do not bypass via broadcast.
      if (sent != null) {
        if (sent) _lastNudgeAt = now;
        return sent;
      }
    } on MissingPluginException {
      // Fall through to Dart-only broadcast below.
    } catch (e) {
      debugPrint('Native connect failed, sending broadcast instead: $e');
    }
    final sent = await _broadcast(connectAction);
    if (sent) _lastNudgeAt = now;
    return sent;
  }

  Future<bool> requestDisconnect({bool force = true}) async {
    if (!Platform.isAndroid) return false;
    try {
      await _exitChannel.invokeMethod<void>(
        force ? 'disconnectNow' : 'disconnectIfAllowed',
      );
      return true;
    } on MissingPluginException {
      return _broadcast(disconnectAction);
    } catch (e) {
      debugPrint('Host disconnect failed, sending broadcast instead: $e');
      return _broadcast(disconnectAction);
    }
  }

  /// Tell the native guard a file transfer needs the tunnel held in background.
  Future<void> noteTransfer(bool active) async {
    if (!Platform.isAndroid) return;
    try {
      await _exitChannel.invokeMethod<void>('noteTransfer', {'active': active});
    } on MissingPluginException {
      // Older host build without the transfer flag.
    } catch (e) {
      debugPrint('Could not note transfer state: $e');
    }
  }

  Future<void> markOwnedNative() async {
    if (!Platform.isAndroid) return;
    try {
      await _exitChannel.invokeMethod<void>('markOwned');
    } on MissingPluginException {
      // Host without channel.
    } catch (e) {
      debugPrint('Could not mark Tailscale owned: $e');
    }
  }

  Future<void> releaseOwnershipNative({String reason = 'dart'}) async {
    if (!Platform.isAndroid) return;
    try {
      await _exitChannel.invokeMethod<void>('releaseOwnership', {
        'reason': reason,
      });
    } on MissingPluginException {
      // Host without channel.
    } catch (e) {
      debugPrint('Could not release Tailscale ownership: $e');
    }
  }

  Future<bool> _broadcast(String action) async {
    try {
      final intent = AndroidIntent(
        action: action,
        package: packageName,
        componentName: receiverClass,
      );
      await intent.sendBroadcast();
      return true;
    } catch (e) {
      debugPrint('Tailscale $action failed: $e');
      return false;
    }
  }

  Future<bool> openApp() async {
    if (!Platform.isAndroid) return false;
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.MAIN',
        category: 'android.intent.category.LAUNCHER',
        package: packageName,
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );
      await intent.launch();
      return true;
    } catch (e) {
      debugPrint('Could not open Tailscale: $e');
      return false;
    }
  }

  Future<void> setExitPolicy({
    required bool enabled,
    required TailscaleOwnershipPhase phase,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _exitChannel.invokeMethod<void>('setExitPolicy', {
        'enabled': enabled,
        'phase': phase.wire,
        'startedByApp': phase.isOwned,
      });
    } on MissingPluginException {
      // Older host build without the channel.
    } catch (e) {
      debugPrint('Could not save Tailscale exit policy: $e');
    }
  }

  Future<bool> nudgeIfNeeded({
    required String? serverUrl,
    ServerCheck? lastCheck,
    bool force = false,
  }) async {
    if (!Platform.isAndroid) return false;
    if (!shouldNudge(serverUrl: serverUrl, lastCheck: lastCheck)) return false;
    return requestConnect(force: force, lastCheck: lastCheck);
  }
}
