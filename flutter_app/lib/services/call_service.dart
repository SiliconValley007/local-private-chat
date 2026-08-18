import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import '../api_client.dart';
import '../call_identity.dart';
import '../realtime_service.dart';
import 'call_audio_controller.dart';
import 'call_signaling.dart';
import 'pending_call_store.dart';

export 'call_signaling.dart';

/// One in-progress (or ringing) peer call over Tailscale mesh WebRTC.
class CallSession extends ChangeNotifier {
  CallSession({
    required this.conversationId,
    required this.callId,
    required this.media,
    required this.outgoing,
    required this.peerName,
    this.peerUserId,
  });

  final int conversationId;
  final String callId;
  final String media; // audio | video
  final bool outgoing;
  String peerName;
  final int? peerUserId;

  CallPhase phase = CallPhase.idle;
  String? error;
  bool muted = false;
  bool cameraOff = false;
  DateTime? connectedAt;
  bool calleeAckedRinging = false;
  CallDeliveryState? deliveryState;
  CallAudioRoute? audioRoute;

  RTCPeerConnection? _pc;
  MediaStream? _local;
  MediaStream? _remote;
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;

  MediaStream? get localStream => _local;
  MediaStream? get remoteStream => _remote;
  bool get isVideo => media == 'video';

  Duration get elapsed {
    final start = connectedAt;
    if (start == null) return Duration.zero;
    return DateTime.now().difference(start);
  }

  Future<void> ensureRenderers() async {
    if (_renderersReady) return;
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _renderersReady = true;
  }

  Future<void> _attachLocal(MediaStream stream) async {
    _local = stream;
    await ensureRenderers();
    localRenderer.srcObject = stream;
    notifyListeners();
  }

  Future<void> _attachRemote(MediaStream stream) async {
    _remote = stream;
    await ensureRenderers();
    remoteRenderer.srcObject = stream;
    notifyListeners();
  }

  Future<RTCPeerConnection> createPeer({
    required void Function(RTCIceCandidate c) onIce,
  }) async {
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    });
    pc.onIceCandidate = (c) {
      if (c.candidate != null) onIce(c);
    };
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        unawaited(_attachRemote(event.streams.first));
      }
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        phase = CallPhase.active;
        connectedAt ??= DateTime.now();
        error = null;
        notifyListeners();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        if (phase == CallPhase.active || phase == CallPhase.connecting) {
          error =
              'Call media failed to connect. Check Tailscale is direct (not relay-only).';
          notifyListeners();
        }
      }
    };
    _pc = pc;
    return pc;
  }

  Future<MediaStream> openLocalMedia({required bool video}) async {
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video
          ? {'facingMode': 'user', 'width': 640, 'height': 480}
          : false,
    });
    await _attachLocal(stream);
    return stream;
  }

  Future<void> addLocalTracks(RTCPeerConnection pc) async {
    final stream = _local;
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }
  }

  Future<void> setMuted(bool value) async {
    muted = value;
    for (final t in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !value;
    }
    notifyListeners();
  }

  Future<void> setCameraOff(bool value) async {
    cameraOff = value;
    for (final t in _local?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !value;
    }
    notifyListeners();
  }

  Future<void> disposeMedia() async {
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    for (final t in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _local?.dispose();
    _local = null;
    await _remote?.dispose();
    _remote = null;
    if (_renderersReady) {
      localRenderer.srcObject = null;
      remoteRenderer.srcObject = null;
      await localRenderer.dispose();
      await remoteRenderer.dispose();
      _renderersReady = false;
    }
  }
}

/// Owns at most one [CallSession] and bridges WebSocket call.* signaling.
class CallService extends ChangeNotifier {
  CallService(this.api, this.realtime);

  final ApiClient api;
  final RealtimeService realtime;

  CallSession? active;
  final _uuid = const Uuid();
  final List<RTCIceCandidate> _pendingRemoteIce = [];
  bool _remoteDescSet = false;
  bool _bound = false;
  Map<String, dynamic>? _pendingOffer;
  Timer? _outgoingTimeout;
  bool _ringingAckSent = false;
  CallSession? _boundSession;
  VoidCallback? _sessionListener;

  /// Optional: resolve a friendly peer name for an incoming invite.
  String Function(int conversationId)? peerNameFor;

  /// Resolve caller display names from server username + display name.
  String Function(String username, String displayName)? resolveCallerName;

  /// Whether the conversation is muted on this device.
  bool Function(int conversationId)? isConversationMuted;

  /// Fired when an incoming call session is created (UI should present).
  void Function(CallSession session)? onIncoming;

  /// Fired when an active incoming call ends remotely (cancel notification).
  void Function(String callId)? onIncomingEnded;

  List<CallAudioRoute> get availableRoutes =>
      CallAudioController.instance.availableRoutes;

  void bind() {
    if (_bound) return;
    _bound = true;
    realtime.addHandler(_onEvent);
  }

  void unbind() {
    if (!_bound) return;
    _bound = false;
    realtime.removeHandler(_onEvent);
  }

  Future<CallSession> startOutgoing({
    required int conversationId,
    required String media,
    required String peerName,
    int? peerUserId,
  }) async {
    if (active != null) {
      throw StateError('Already in a call');
    }
    final callId = _uuid.v4();
    final session = CallSession(
      conversationId: conversationId,
      callId: callId,
      media: media,
      outgoing: true,
      peerName: peerName,
      peerUserId: peerUserId,
    )..phase = CallPhase.outgoing;
    active = session;
    _resetCallState();
    notifyListeners();
    _bindSession(session);
    await _syncCallAudio(session);
    _armOutgoingTimeout(session);

    try {
      await session.openLocalMedia(video: media == 'video');
      await CallAudioController.instance.prepareInCallAudio(
        isVideo: session.isVideo,
      );
      session.audioRoute = CallAudioController.instance.selectedRoute;
      final pc = await session.createPeer(onIce: (c) => _sendIce(session, c));
      await session.addLocalTracks(pc);

      realtime.sendCallSignal({
        'type': 'call.invite',
        'conversation_id': conversationId,
        'call_id': callId,
        'media': media,
      });

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      realtime.sendCallSignal({
        'type': 'call.offer',
        'conversation_id': conversationId,
        'call_id': callId,
        'sdp': offer.sdp,
        'sdp_type': offer.type,
      });
      notifyListeners();
    } catch (e) {
      session.error = 'Could not start call: $e';
      await _hangUp(local: true, skipSignal: true);
      rethrow;
    }
    return session;
  }

  /// Restores an incoming call from push/local persistence or server pending list.
  Future<bool> restorePendingIncoming(PendingCall pending) async {
    if (active != null) return false;
    if (pending.callId.isEmpty || pending.conversationId <= 0) return false;
    final name = _incomingPeerName(pending);
    final session = CallSession(
      conversationId: pending.conversationId,
      callId: pending.callId,
      media: pending.media,
      outgoing: false,
      peerName: name,
      peerUserId: pending.callerId > 0 ? pending.callerId : null,
    )..phase = CallPhase.incoming;
    active = session;
    _resetCallState();
    _bindSession(session);
    notifyListeners();
    await _syncCallAudio(session);
    await _ackRinging(session);
    onIncoming?.call(session);
    await _fetchServerPendingOffer(session);
    return true;
  }

  Future<void> recoverPendingCalls() async {
    if (active != null) return;
    final local = await PendingCallStore.instance.load();
    if (local != null) {
      await restorePendingIncoming(local);
      return;
    }
    try {
      final remote = await api.fetchPendingCalls();
      if (remote.isEmpty) return;
      final first = remote.first;
      final pending = PendingCall.fromServer(
        first,
        callerName: _resolveCallerName(
          '${first['caller_username'] ?? ''}',
          '${first['caller_name'] ?? ''}',
          peerNameFor?.call(first['conversation_id'] as int? ?? 0),
        ),
        callerUsername: '${first['caller_username'] ?? ''}',
      );
      await restorePendingIncoming(pending);
    } catch (_) {
      // Recovery is best-effort until Tailscale/server is reachable.
    }
  }

  Future<void> acceptIncoming() async {
    final session = active;
    if (session == null || session.phase != CallPhase.incoming) return;
    try {
      session.phase = CallPhase.connecting;
      notifyListeners();
      await _syncCallAudio(session);
      await session.openLocalMedia(video: session.isVideo);
      await CallAudioController.instance.prepareInCallAudio(
        isVideo: session.isVideo,
      );
      session.audioRoute = CallAudioController.instance.selectedRoute;
      final pc = await session.createPeer(onIce: (c) => _sendIce(session, c));
      await session.addLocalTracks(pc);
      final pending = _pendingOffer;
      if (pending != null) {
        await _applyRemoteOffer(session, pc, pending);
      }
    } catch (e) {
      session.error = 'Could not accept call: $e';
      await rejectIncoming();
    }
  }

  Future<void> rejectIncoming() async {
    final session = active;
    if (session == null) return;
    realtime.sendCallSignal({
      'type': 'call.reject',
      'conversation_id': session.conversationId,
      'call_id': session.callId,
    });
    await PendingCallStore.instance.clear();
    onIncomingEnded?.call(session.callId);
    await _hangUp(local: true, skipSignal: true);
  }

  Future<void> endCall() async {
    await _hangUp(local: true, skipSignal: false);
  }

  void _sendIce(CallSession session, RTCIceCandidate c) {
    realtime.sendCallSignal({
      'type': 'call.ice',
      'conversation_id': session.conversationId,
      'call_id': session.callId,
      'candidate': c.candidate,
      'sdpMid': c.sdpMid,
      'sdpMLineIndex': c.sdpMLineIndex,
    });
  }

  Future<void> _applyRemoteOffer(
    CallSession session,
    RTCPeerConnection pc,
    Map<String, dynamic> offer,
  ) async {
    final sdp = offer['sdp'] as String?;
    final type = offer['sdp_type'] as String? ?? 'offer';
    if (sdp == null) return;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
    _remoteDescSet = true;
    await _flushIce(pc);
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    realtime.sendCallSignal({
      'type': 'call.answer',
      'conversation_id': session.conversationId,
      'call_id': session.callId,
      'sdp': answer.sdp,
      'sdp_type': answer.type,
    });
    _pendingOffer = null;
  }

  Future<void> _flushIce(RTCPeerConnection pc) async {
    for (final c in _pendingRemoteIce) {
      try {
        await pc.addCandidate(c);
      } catch (_) {}
    }
    _pendingRemoteIce.clear();
  }

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    if (type == null || !type.startsWith('call.')) return;
    unawaited(_handleCallEvent(type, event));
  }

  Future<void> _handleCallEvent(String type, Map<String, dynamic> event) async {
    final conversationId = event['conversation_id'] as int?;
    final callId = event['call_id'] as String? ?? '';
    if (conversationId == null) return;

    switch (type) {
      case 'call.invite':
        if (active != null) {
          if (active!.callId == callId) return;
          realtime.sendCallSignal({
            'type': 'call.busy',
            'conversation_id': conversationId,
            'call_id': callId,
          });
          return;
        }
        final media = event['media'] as String? ?? 'audio';
        final fromId = event['from_user_id'] as int?;
        final callerUsername = '${event['caller_username'] ?? ''}';
        final callerName = '${event['caller_name'] ?? ''}';
        final name = _resolveCallerName(
          callerUsername,
          callerName,
          peerNameFor?.call(conversationId),
        );
        final session = CallSession(
          conversationId: conversationId,
          callId: callId.isEmpty ? _uuid.v4() : callId,
          media: media,
          outgoing: false,
          peerName: name,
          peerUserId: fromId,
        )..phase = CallPhase.incoming;
        active = session;
        _resetCallState();
        _bindSession(session);
        notifyListeners();
        await _syncCallAudio(session);
        await _ackRinging(session);
        onIncoming?.call(session);
        break;

      case 'call.delivery':
        final session = active;
        if (session == null || !session.outgoing || session.callId != callId) {
          return;
        }
        session.deliveryState = parseCallDeliveryState(
          event['state'] as String?,
        );
        session.error ??= unreachableCallMessage(
          session.peerName,
          session.deliveryState,
        );
        _armOutgoingTimeout(session);
        notifyListeners();
        break;

      case 'call.offer':
        final session = active;
        if (session == null || session.callId != callId) {
          _pendingOffer = event;
          return;
        }
        if (session.outgoing) return;
        _pendingOffer = event;
        if (session.phase == CallPhase.connecting ||
            session.phase == CallPhase.active) {
          final pc = session._pc;
          if (pc != null) await _applyRemoteOffer(session, pc, event);
        }
        break;

      case 'call.ringing':
        final session = active;
        if (session == null || !session.outgoing || session.callId != callId) {
          return;
        }
        final next = callerPhaseAfterEvent(session.phase, type);
        if (next == null) return;
        session.phase = next;
        session.calleeAckedRinging = true;
        session.error = null;
        await _syncCallAudio(session);
        notifyListeners();
        break;

      case 'call.answer':
        final session = active;
        final pc = session?._pc;
        if (session == null || pc == null || session.callId != callId) return;
        final sdp = event['sdp'] as String?;
        if (sdp == null) return;
        await pc.setRemoteDescription(
          RTCSessionDescription(sdp, event['sdp_type'] as String? ?? 'answer'),
        );
        _remoteDescSet = true;
        await _flushIce(pc);
        final next = callerPhaseAfterEvent(session.phase, type);
        if (next != null) {
          session.phase = next;
          await _syncCallAudio(session);
          notifyListeners();
        }
        break;

      case 'call.ice':
        final session = active;
        if (session == null || session.callId != callId) return;
        final candidate = event['candidate'] as String?;
        if (candidate == null) return;
        final ice = RTCIceCandidate(
          candidate,
          event['sdpMid'] as String?,
          event['sdpMLineIndex'] as int?,
        );
        final pc = session._pc;
        if (pc == null || !_remoteDescSet) {
          _pendingRemoteIce.add(ice);
        } else {
          try {
            await pc.addCandidate(ice);
          } catch (_) {}
        }
        break;

      case 'call.reject':
      case 'call.busy':
      case 'call.cancel':
      case 'call.timeout':
        final session = active;
        if (session == null) return;
        if (session.callId != callId && callId.isNotEmpty) return;
        await PendingCallStore.instance.clear();
        onIncomingEnded?.call(session.callId);
        await _hangUp(local: false, skipSignal: true);
        break;

      case 'call.end':
        final session = active;
        if (session == null) {
          await PendingCallStore.instance.clear();
          if (callId.isNotEmpty) onIncomingEnded?.call(callId);
          return;
        }
        if (session.callId != callId && callId.isNotEmpty) return;
        await PendingCallStore.instance.clear();
        onIncomingEnded?.call(session.callId);
        await _hangUp(local: false, skipSignal: true);
        break;
    }
  }

  Future<void> _ackRinging(CallSession session) async {
    if (!calleeShouldAckRinging(
      alreadyAcked: _ringingAckSent,
      phase: session.phase,
    )) {
      return;
    }
    _ringingAckSent = true;
    session.calleeAckedRinging = true;
    final payload = {
      'type': 'call.ringing',
      'conversation_id': session.conversationId,
      'call_id': session.callId,
    };
    if (realtime.isConnected) {
      realtime.sendCallSignal(payload);
      return;
    }
    try {
      await api.ackCallRinging(session.callId);
    } catch (_) {
      // Tailscale/server may still be down; WS retry happens on reconnect.
      realtime.sendCallSignal(payload);
    }
  }

  Future<void> _fetchServerPendingOffer(CallSession session) async {
    try {
      final pending = await api.fetchPendingCalls();
      for (final row in pending) {
        if (row['call_id'] != session.callId) continue;
        final sdp = row['offer_sdp'] as String?;
        if (sdp == null) return;
        _pendingOffer = {
          'type': 'call.offer',
          'conversation_id': session.conversationId,
          'call_id': session.callId,
          'sdp': sdp,
          'sdp_type': row['offer_sdp_type'] as String? ?? 'offer',
        };
        return;
      }
    } catch (_) {}
  }

  void _armOutgoingTimeout(CallSession session) {
    _outgoingTimeout?.cancel();
    final timeout = session.deliveryState == null
        ? callTotalTimeout
        : outgoingTimeoutForDelivery(session.deliveryState);
    _outgoingTimeout = Timer(timeout, () async {
      if (active?.callId != session.callId) return;
      if (session.phase == CallPhase.active ||
          session.phase == CallPhase.ended) {
        return;
      }
      session.error ??= session.deliveryState == CallDeliveryState.unreachable
          ? unreachableCallMessage(session.peerName, session.deliveryState)
          : noAnswerCallMessage(session.peerName);
      await _hangUp(local: true, skipSignal: true);
      realtime.sendCallSignal({
        'type': 'call.cancel',
        'conversation_id': session.conversationId,
        'call_id': session.callId,
      });
    });
  }

  Future<void> setAudioRoute(CallAudioRoute route) async {
    final session = active;
    if (session == null) return;
    await CallAudioController.instance.setRoute(route);
    session.audioRoute = CallAudioController.instance.selectedRoute;
    notifyListeners();
  }

  Future<void> onAppLifecycleBackground() async {
    await CallAudioController.instance.stopAll(restoreAudio: false);
  }

  Future<void> syncActiveCallAudio() async {
    final session = active;
    if (session == null) return;
    await _syncCallAudio(session);
  }

  void _bindSession(CallSession session) {
    _unbindSession();
    _boundSession = session;
    _sessionListener = () => _onSessionChanged(session);
    session.addListener(_sessionListener!);
  }

  void _unbindSession() {
    final session = _boundSession;
    final listener = _sessionListener;
    if (session != null && listener != null) {
      session.removeListener(listener);
    }
    _boundSession = null;
    _sessionListener = null;
  }

  void _onSessionChanged(CallSession session) {
    notifyListeners();
    unawaited(_syncCallAudio(session));
  }

  Future<void> _syncCallAudio(CallSession session) async {
    final muted = isConversationMuted?.call(session.conversationId) ?? false;
    await CallAudioController.instance.syncAlerts(
      phase: session.phase,
      conversationMuted: muted,
    );
    if (session.phase == CallPhase.connecting ||
        session.phase == CallPhase.active) {
      await CallAudioController.instance.prepareInCallAudio(
        isVideo: session.isVideo,
      );
      session.audioRoute = CallAudioController.instance.selectedRoute;
    }
  }

  String _incomingPeerName(PendingCall pending) {
    if (pending.callerName.isNotEmpty && pending.callerUsername.isEmpty) {
      return pending.callerName;
    }
    return _resolveCallerName(
      pending.callerUsername,
      pending.callerName,
      peerNameFor?.call(pending.conversationId),
    );
  }

  String _resolveCallerName(
    String username,
    String displayName,
    String? conversationTitle,
  ) {
    final resolved = resolveCallerName?.call(username, displayName);
    if (resolved != null && resolved.isNotEmpty) return resolved;
    if (conversationTitle != null && conversationTitle.isNotEmpty) {
      return conversationTitle;
    }
    return resolveCallerDisplayNameSync(
      username: username,
      serverName: displayName,
      aliases: const {},
    );
  }

  Future<void> _hangUp({required bool local, required bool skipSignal}) async {
    final session = active;
    if (session == null) return;
    _outgoingTimeout?.cancel();
    _outgoingTimeout = null;
    if (local && !skipSignal) {
      final signalType = session.outgoing && outgoingShouldCancel(session.phase)
          ? 'call.cancel'
          : 'call.end';
      realtime.sendCallSignal({
        'type': signalType,
        'conversation_id': session.conversationId,
        'call_id': session.callId,
      });
    }
    session.phase = CallPhase.ended;
    await PendingCallStore.instance.clear();
    onIncomingEnded?.call(session.callId);
    await _syncCallAudio(session);
    await CallAudioController.instance.stopAll();
    await session.disposeMedia();
    _unbindSession();
    active = null;
    _resetCallState();
    notifyListeners();
  }

  void _resetCallState() {
    _pendingRemoteIce.clear();
    _pendingOffer = null;
    _remoteDescSet = false;
    _ringingAckSent = false;
  }

  @override
  void dispose() {
    unbind();
    _outgoingTimeout?.cancel();
    unawaited(CallAudioController.instance.stopAll());
    unawaited(active?.disposeMedia() ?? Future.value());
    super.dispose();
  }
}

/// Tiny helper so call UI can format 0:42 style elapsed times.
String formatCallElapsed(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(1, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Debug-only: encode a candidate map (kept for unit tests without WebRTC).
Map<String, dynamic> callIcePayload({
  required int conversationId,
  required String callId,
  required String candidate,
  String? sdpMid,
  int? sdpMLineIndex,
}) => {
  'type': 'call.ice',
  'conversation_id': conversationId,
  'call_id': callId,
  'candidate': candidate,
  'sdpMid': sdpMid,
  'sdpMLineIndex': sdpMLineIndex,
};

String encodeCallSignal(Map<String, dynamic> payload) => jsonEncode(payload);

/// Handles FCM `call.incoming` in foreground/background isolates.
Future<PendingCall?> pendingCallFromPushData(Map<String, dynamic> data) async {
  if ('${data['type'] ?? ''}' != 'call.incoming') return null;
  final pending = PendingCall.fromPushData(data);
  if (pending.callId.isEmpty || pending.conversationId <= 0) return null;
  await PendingCallStore.instance.save(pending);
  return pending;
}
