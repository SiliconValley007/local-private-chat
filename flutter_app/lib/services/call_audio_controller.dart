import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'call_signaling.dart';

/// Bridges Android call tones and in-call audio routing to Dart.
class CallAudioController {
  CallAudioController._();
  static final instance = CallAudioController._();

  static const _channel = MethodChannel('local_chat/call_audio');

  CallPhase? _syncedPhase;
  bool _incomingPlaying = false;
  bool _ringbackPlaying = false;
  bool _prepared = false;
  List<CallAudioRoute> _routes = const [
    CallAudioRoute.earpiece,
    CallAudioRoute.speaker,
  ];
  CallAudioRoute? _selectedRoute;

  List<CallAudioRoute> get availableRoutes => List.unmodifiable(_routes);
  CallAudioRoute? get selectedRoute => _selectedRoute;

  /// Phase-driven alert tones. Idempotent for repeated syncs with same phase.
  Future<void> syncAlerts({
    required CallPhase phase,
    required bool conversationMuted,
  }) async {
    if (!Platform.isAndroid) return;
    if (_syncedPhase == phase) return;
    _syncedPhase = phase;

    if (conversationMuted || shouldStopCallAlerts(phase)) {
      await _stopAlerts();
      return;
    }
    if (shouldPlayIncomingAlert(phase)) {
      await _startIncomingAlert();
      return;
    }
    if (shouldPlayOutgoingRingback(phase)) {
      await _startRingback();
      return;
    }
    await _stopAlerts();
  }

  Future<void> prepareInCallAudio({required bool isVideo}) async {
    if (!Platform.isAndroid || _prepared) return;
    try {
      await _channel.invokeMethod<void>('prepareForCall', {'isVideo': isVideo});
      _prepared = true;
      await refreshRoutes(
        preferred: defaultRouteForMedia(isVideo ? 'video' : 'audio'),
      );
    } catch (e) {
      debugPrint('Call audio prepare skipped: $e');
    }
  }

  Future<void> refreshRoutes({CallAudioRoute? preferred}) async {
    if (!Platform.isAndroid) return;
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listRoutes');
      final parsed = <CallAudioRoute>[
        for (final item in raw ?? const []) ?parseCallAudioRoute('$item'),
      ];
      if (parsed.isEmpty) {
        _routes = const [CallAudioRoute.earpiece, CallAudioRoute.speaker];
      } else {
        _routes = parsed;
      }
      final pick = preferred != null && _routes.contains(preferred)
          ? preferred
          : (_selectedRoute != null && _routes.contains(_selectedRoute!)
                ? _selectedRoute
                : _routes.first);
      if (pick != null) await setRoute(pick);
    } catch (e) {
      debugPrint('Call audio routes skipped: $e');
    }
  }

  Future<void> setRoute(CallAudioRoute route) async {
    if (!Platform.isAndroid) return;
    if (!_routes.contains(route)) return;
    try {
      await _channel.invokeMethod<void>('setRoute', {
        'route': callAudioRouteWire(route),
      });
      _selectedRoute = route;
    } catch (e) {
      debugPrint('Call audio route skipped: $e');
    }
  }

  Future<void> stopAll({bool restoreAudio = true}) async {
    _syncedPhase = null;
    await _stopAlerts();
    if (restoreAudio) await restoreAudioMode();
  }

  Future<void> restoreAudioMode() async {
    if (!Platform.isAndroid || !_prepared) return;
    try {
      await _channel.invokeMethod<void>('restoreAudio');
    } catch (e) {
      debugPrint('Call audio restore skipped: $e');
    } finally {
      _prepared = false;
      _selectedRoute = null;
      _routes = const [CallAudioRoute.earpiece, CallAudioRoute.speaker];
    }
  }

  Future<void> _startIncomingAlert() async {
    if (_incomingPlaying) return;
    await _stopRingback();
    try {
      await _channel.invokeMethod<void>('startIncomingAlert');
      _incomingPlaying = true;
    } catch (e) {
      debugPrint('Incoming call alert skipped: $e');
    }
  }

  Future<void> _startRingback() async {
    if (_ringbackPlaying) return;
    await _stopIncoming();
    try {
      await _channel.invokeMethod<void>('startRingback');
      _ringbackPlaying = true;
    } catch (e) {
      debugPrint('Outgoing ringback skipped: $e');
    }
  }

  Future<void> _stopAlerts() async {
    final hadAlert = _incomingPlaying || _ringbackPlaying;
    _incomingPlaying = false;
    _ringbackPlaying = false;
    if (hadAlert) await _invokeNativeStopAlerts();
  }

  Future<void> _stopIncoming() async {
    if (!_incomingPlaying) return;
    _incomingPlaying = false;
    await _invokeNativeStopAlerts();
  }

  Future<void> _stopRingback() async {
    if (!_ringbackPlaying) return;
    _ringbackPlaying = false;
    await _invokeNativeStopAlerts();
  }

  Future<void> _invokeNativeStopAlerts() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stopAlerts');
    } catch (e) {
      debugPrint('Stop call alerts skipped: $e');
    }
  }
}
