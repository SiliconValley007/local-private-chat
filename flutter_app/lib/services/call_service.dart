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

enum CallNetworkQuality { unknown, good, fair, poor, reconnecting }

String callNetworkQualityLabel(CallNetworkQuality quality) => switch (quality) {
  CallNetworkQuality.unknown => 'Measuring connection…',
  CallNetworkQuality.good => 'Good connection',
  CallNetworkQuality.fair => 'Connection is a little slow',
  CallNetworkQuality.poor => 'Weak connection',
  CallNetworkQuality.reconnecting => 'Media interrupted — reconnecting…',
};

/// One in-progress (or ringing) peer call over Tailscale mesh WebRTC.
class CallSession extends ChangeNotifier {
  CallSession({
    required this.conversationId,
    required this.callId,
    required this.media,
    required this.outgoing,
    required this.peerName,
    this.peerUserId,
    this.restored = false,
  });

  final int conversationId;
  final String callId;
  final String media; // audio | video
  final bool outgoing;
  String peerName;
  final int? peerUserId;
  final bool restored;

  CallPhase phase = CallPhase.idle;
  String? error;
  bool muted = false;
  bool cameraOff = false;
  DateTime? connectedAt;
  bool calleeAckedRinging = false;
  CallDeliveryState? deliveryState;
  CallAudioRoute? audioRoute;
  CallNetworkQuality networkQuality = CallNetworkQuality.unknown;

  RTCPeerConnection? _pc;
  MediaStream? _local;
  MediaStream? _remote;
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;
  Timer? _qualityTimer;
  Timer? _mediaGraceTimer;
  DateTime? _mediaGraceStartedAt;
  Future<void> _remoteTrackQueue = Future.value();
  RTCIceConnectionState? _iceState;
  RTCPeerConnectionState? _peerState;
  int iceAddFailures = 0;

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

  /// Some Android WebRTC builds emit audio/video [RTCTrackEvent]s without
  /// `streams`. Keep one aggregate stream: replacing it for each event makes
  /// whichever track arrives last win, so video-first/audio-last becomes a
  /// connected call with a black remote view.
  Future<void> _handleRemoteTrack(RTCTrackEvent event) async {
    try {
      var stream = _remote;
      if (stream == null) {
        stream = event.streams.isNotEmpty
            ? event.streams.first
            : await createLocalMediaStream('remote-$callId');
        await _attachRemote(stream);
      } else if (event.streams.isNotEmpty) {
        final richer = event.streams.first;
        final currentIds = stream.getTracks().map((track) => track.id).toSet();
        final richerIds = richer.getTracks().map((track) => track.id).toSet();
        // Some builds first emit an empty-stream event, then a populated stream
        // containing both media tracks. Adopt it only when it is a true
        // superset, so replacing can never discard the earlier audio/video.
        if (richerIds.length > currentIds.length &&
            richerIds.containsAll(currentIds)) {
          stream = richer;
          await _attachRemote(stream);
        }
      }
      final alreadyAttached = stream.getTracks().any(
        (track) => track.id == event.track.id,
      );
      if (!alreadyAttached) await stream.addTrack(event.track);
      // Reassigning is harmless and makes Android renderers notice a track
      // added to a synthetic stream after srcObject was first attached.
      remoteRenderer.srcObject = stream;
      notifyListeners();
    } catch (e) {
      debugPrint('Call remote track attach failed: ${e.runtimeType}');
      if (event.track.kind == 'video') {
        error =
            'Remote video could not be displayed. End the call and try again.';
        notifyListeners();
      }
    }
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
      _remoteTrackQueue = _remoteTrackQueue
          .then((_) => _handleRemoteTrack(event))
          .catchError((Object error, StackTrace stack) {
            debugPrint('Call remote track queue failed: ${error.runtimeType}');
          });
    };
    pc.onIceConnectionState = (state) {
      _iceState = state;
      _applyMediaLinkState();
    };
    pc.onConnectionState = (state) {
      _peerState = state;
      _applyMediaLinkState();
    };
    _pc = pc;
    return pc;
  }

  void _applyMediaLinkState({bool graceExpired = false}) {
    if (phase == CallPhase.ended || phase == CallPhase.idle) return;

    final ice = parseCallMediaIceWire(_iceState?.name);
    final peer = parseCallMediaPeerWire(_peerState?.name);
    final link = deriveCallMediaLinkState(ice: ice, peer: peer);

    if (link == CallMediaLinkState.connected) {
      _mediaGraceTimer?.cancel();
      _mediaGraceTimer = null;
      _mediaGraceStartedAt = null;
      phase = CallPhase.active;
      connectedAt ??= DateTime.now();
      error = null;
      networkQuality = CallNetworkQuality.unknown;
      _startQualitySampling();
      notifyListeners();
      return;
    }

    if (shouldStartMediaReconnectGrace(phase: phase, ice: ice, peer: peer)) {
      networkQuality = CallNetworkQuality.reconnecting;
      error = null;
      _armMediaReconnectGrace();
      notifyListeners();
      return;
    }

    if (link == CallMediaLinkState.reconnecting &&
        (phase == CallPhase.connecting || phase == CallPhase.active)) {
      networkQuality = CallNetworkQuality.reconnecting;
      error = null;
      notifyListeners();
      return;
    }

    if (shouldReportMediaConnectFailure(
      phase: phase,
      ice: ice,
      peer: peer,
      graceExpired: graceExpired,
    )) {
      _mediaGraceTimer?.cancel();
      _mediaGraceTimer = null;
      _mediaGraceStartedAt = null;
      networkQuality = CallNetworkQuality.reconnecting;
      error = callMediaFailedMessage(iceAddFailures: iceAddFailures);
      notifyListeners();
    }
  }

  void _armMediaReconnectGrace() {
    _mediaGraceTimer?.cancel();
    _mediaGraceStartedAt = DateTime.now();
    _mediaGraceTimer = Timer(callMediaReconnectGrace, () {
      _mediaGraceStartedAt = null;
      if (phase != CallPhase.connecting && phase != CallPhase.active) return;
      _applyMediaLinkState(graceExpired: true);
    });
  }

  Duration get mediaReconnectGraceRemaining {
    if (_mediaGraceTimer?.isActive != true || _mediaGraceStartedAt == null) {
      return Duration.zero;
    }
    final elapsed = DateTime.now().difference(_mediaGraceStartedAt!);
    final remaining = callMediaReconnectGrace - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Clears grace/media state when the peer connection is torn down.
  void _resetMediaLinkTracking() {
    _mediaGraceTimer?.cancel();
    _mediaGraceTimer = null;
    _mediaGraceStartedAt = null;
    _iceState = null;
    _peerState = null;
    iceAddFailures = 0;
  }

  void _startQualitySampling() {
    _qualityTimer?.cancel();
    // Stats stay entirely on-device. Seven seconds is responsive enough to be
    // useful without waking the CPU every second for a cosmetic indicator.
    _qualityTimer = Timer.periodic(
      const Duration(seconds: 7),
      (_) => unawaited(_sampleNetworkQuality()),
    );
    unawaited(_sampleNetworkQuality());
  }

  Future<void> _sampleNetworkQuality() async {
    final pc = _pc;
    if (pc == null || phase != CallPhase.active) return;
    try {
      final reports = await pc.getStats();
      var worst = CallNetworkQuality.good;
      for (final report in reports) {
        final values = report.values;
        if (report.type == 'candidate-pair') {
          final rtt = _statNumber(values['currentRoundTripTime']);
          if (rtt != null) {
            if (rtt >= 0.8) {
              worst = CallNetworkQuality.poor;
            } else if (rtt >= 0.35 && worst != CallNetworkQuality.poor) {
              worst = CallNetworkQuality.fair;
            }
          }
        }
        if (report.type == 'inbound-rtp') {
          final received = _statNumber(values['packetsReceived']) ?? 0;
          final lost = _statNumber(values['packetsLost']) ?? 0;
          final total = received + (lost > 0 ? lost : 0);
          final loss = total > 0 ? lost / total : 0;
          final jitter = _statNumber(values['jitter']) ?? 0;
          if (loss >= 0.08 || jitter >= 0.08) {
            worst = CallNetworkQuality.poor;
          } else if ((loss >= 0.03 || jitter >= 0.03) &&
              worst != CallNetworkQuality.poor) {
            worst = CallNetworkQuality.fair;
          }
        }
      }
      if (networkQuality != worst) {
        networkQuality = worst;
        notifyListeners();
      }
    } catch (_) {
      // Stats support differs by WebRTC build. The call itself is authority;
      // never disturb working media because its quality badge could not sample.
    }
  }

  num? _statNumber(dynamic value) {
    if (value is num) return value;
    return num.tryParse('$value');
  }

  Future<MediaStream> openLocalMedia({
    required bool video,
    Future<void> Function(bool active)? onExpectReturn,
  }) async {
    await onExpectReturn?.call(true);
    try {
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': video
            ? {'facingMode': 'user', 'width': 640, 'height': 480}
            : false,
      });
      await _attachLocal(stream);
      return stream;
    } finally {
      await onExpectReturn?.call(false);
    }
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
    _qualityTimer?.cancel();
    _qualityTimer = null;
    _resetMediaLinkTracking();
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
  CallService(
    this.api,
    this.realtime, {
    this.onCallTunnelHold,
    this.onCallExpectReturn,
  });

  final ApiClient api;
  final RealtimeService realtime;
  final Future<void> Function(bool active)? onCallTunnelHold;
  final Future<void> Function(bool active)? onCallExpectReturn;

  CallSession? active;
  final _uuid = const Uuid();
  final List<RTCIceCandidate> _pendingRemoteIce = [];
  bool _remoteDescSet = false;
  bool _remoteDescApplying = false;
  bool _localTracksAdded = false;
  bool _bound = false;
  Map<String, dynamic>? _pendingOffer;
  Timer? _outgoingTimeout;
  Timer? _mediaConnectTimeout;
  bool _ringingAckSent = false;
  Future<void> _eventQueue = Future.value();
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
    await _syncCallTunnelHold(session);
    await _syncCallAudio(session);
    _armOutgoingTimeout(session);

    var inviteSent = false;
    try {
      await session.openLocalMedia(
        video: media == 'video',
        onExpectReturn: onCallExpectReturn,
      );
      await CallAudioController.instance.prepareInCallAudio();
      session.audioRoute = CallAudioController.instance.selectedRoute;
      final pc = await session.createPeer(onIce: (c) => _sendIce(session, c));
      await session.addLocalTracks(pc);
      _localTracksAdded = true;

      realtime.sendCallSignal({
        'type': 'call.invite',
        'conversation_id': conversationId,
        'call_id': callId,
        'media': media,
      });
      inviteSent = true;

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
      if (inviteSent) {
        await _failCall(session, reason: 'caller_setup_failed');
      } else {
        await _hangUp(local: true, skipSignal: true);
      }
      rethrow;
    }
    return session;
  }

  /// Restores an incoming call from push/local persistence or server pending list.
  Future<bool> restorePendingIncoming(PendingCall pending) async {
    // Recovery, notification taps, and WebSocket frames all mutate [active].
    // Put them through one queue so a delayed local restore cannot overwrite a
    // newer live invite (or resurrect a call after its terminal frame).
    final operation = _eventQueue.then((_) => _restorePendingIncoming(pending));
    _eventQueue = operation.then<void>((_) {}).catchError((
      Object error,
      StackTrace stack,
    ) {
      debugPrint('Call recovery failed: ${error.runtimeType}');
    });
    return operation;
  }

  Future<bool> _restorePendingIncoming(PendingCall pending) async {
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
      restored: true,
    )..phase = CallPhase.incoming;
    active = session;
    _resetCallState();
    _bindSession(session);
    notifyListeners();
    await _syncCallTunnelHold(session);
    await _syncCallAudio(session);
    await _ackRinging(session);
    if (active != session || session.phase != CallPhase.incoming) return false;
    onIncoming?.call(session);
    unawaited(_fetchServerPendingOffer(session));
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
    onIncomingEnded?.call(session.callId);
    try {
      session.phase = CallPhase.connecting;
      notifyListeners();
      await _syncCallTunnelHold(session);
      await _syncCallAudio(session);
      await session.openLocalMedia(
        video: session.isVideo,
        onExpectReturn: onCallExpectReturn,
      );
      await CallAudioController.instance.prepareInCallAudio();
      session.audioRoute = CallAudioController.instance.selectedRoute;
      final pc = await session.createPeer(onIce: (c) => _sendIce(session, c));
      await session.addLocalTracks(pc);
      _localTracksAdded = true;
      await _maybeApplyStoredOffer(session);
    } catch (e) {
      session.error = 'Could not accept call: $e';
      await _failCall(session, reason: 'accept_failed');
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

  Future<void> _maybeApplyStoredOffer(CallSession session) async {
    if (!calleeShouldApplyStoredOffer(
      localTracksAdded: _localTracksAdded,
      remoteDescSet: _remoteDescSet,
      remoteDescApplying: _remoteDescApplying,
      pendingOffer: _pendingOffer,
    )) {
      return;
    }
    final pc = session._pc;
    if (pc == null) return;
    await _applyRemoteOffer(session, pc, _pendingOffer!);
  }

  Future<void> _applyRemoteOffer(
    CallSession session,
    RTCPeerConnection pc,
    Map<String, dynamic> offer,
  ) async {
    if (!calleeMayApplyRemoteOffer(
      localTracksAdded: _localTracksAdded,
      remoteDescSet: _remoteDescSet,
      remoteDescApplying: _remoteDescApplying,
      isOutgoing: session.outgoing,
    )) {
      return;
    }
    final sdp = offer['sdp'] as String?;
    final type = offer['sdp_type'] as String? ?? 'offer';
    if (sdp == null) return;
    _remoteDescApplying = true;
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
      _remoteDescSet = true;
      await _flushIce(pc);
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      _cancelOutgoingTimeout();
      _armMediaConnectTimeout(session);
      realtime.sendCallSignal({
        'type': 'call.answer',
        'conversation_id': session.conversationId,
        'call_id': session.callId,
        'sdp': answer.sdp,
        'sdp_type': answer.type,
      });
      _pendingOffer = null;
    } finally {
      _remoteDescApplying = false;
    }
  }

  Future<void> _flushIce(RTCPeerConnection pc) async {
    for (final c in _pendingRemoteIce) {
      await _addRemoteIce(pc, c);
    }
    _pendingRemoteIce.clear();
  }

  Future<void> _addRemoteIce(RTCPeerConnection pc, RTCIceCandidate ice) async {
    try {
      await pc.addCandidate(ice);
    } catch (e) {
      final session = active;
      if (session != null) {
        session.iceAddFailures++;
      }
      debugPrint(
        'Call ICE add #${session?.iceAddFailures ?? 0}: '
        '${iceAddFailureDiagnostic(e, hadRemoteDesc: _remoteDescSet)}',
      );
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    if (type == null || !type.startsWith('call.')) return;
    // WebSocket callbacks can overlap at every await. Process signaling in wire
    // order so an invite cannot finish presenting after a terminal event has
    // already cleared the same session.
    _eventQueue = _eventQueue
        .then((_) => _handleCallEvent(type, event))
        .catchError((Object error, StackTrace stack) {
          debugPrint('Call event handling failed: ${error.runtimeType}');
        });
  }

  Future<void> _handleCallEvent(String type, Map<String, dynamic> event) async {
    final conversationId = event['conversation_id'] as int?;
    final callId = event['call_id'] as String? ?? '';
    if (conversationId == null) return;

    switch (type) {
      case 'call.invite':
        if (active != null) {
          if (active!.callId == callId) return;
          final current = active!;
          if (current.restored && current.phase == CallPhase.incoming) {
            final stillPending = await _serverHasPendingCall(current.callId);
            if (stillPending == false && active == current) {
              await _hangUp(local: false, skipSignal: true);
            }
          }
        }
        if (active != null) {
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
        await _syncCallTunnelHold(session);
        await _syncCallAudio(session);
        await _ackRinging(session);
        if (active != session || session.phase != CallPhase.incoming) return;
        onIncoming?.call(session);
        unawaited(_fetchServerPendingOffer(session));
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
        // Delivery decides whether the ringback keeps going, and it arrives
        // without the phase moving, so the tones need telling directly.
        await _syncCallAudio(session);
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
        if (callOfferEventShouldStoreOnly(isOutgoing: session.outgoing)) {
          await _maybeApplyStoredOffer(session);
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
        await _syncCallTunnelHold(session);
        await _syncCallAudio(session);
        notifyListeners();
        break;

      case 'call.answer':
        final session = active;
        final pc = session?._pc;
        if (session == null || pc == null || session.callId != callId) return;
        final sdp = event['sdp'] as String?;
        if (sdp == null) return;
        if (!_remoteDescSet && !_remoteDescApplying) {
          _remoteDescApplying = true;
          try {
            await pc.setRemoteDescription(
              RTCSessionDescription(
                sdp,
                event['sdp_type'] as String? ?? 'answer',
              ),
            );
            _remoteDescSet = true;
            await _flushIce(pc);
          } finally {
            _remoteDescApplying = false;
          }
        }
        if (shouldCancelOutgoingTimeoutOnAnswer(type)) {
          _cancelOutgoingTimeout();
        }
        _armMediaConnectTimeout(session);
        final next = callerPhaseAfterEvent(session.phase, type);
        if (next != null) {
          session.phase = next;
          await _syncCallTunnelHold(session);
          await _syncCallAudio(session);
          notifyListeners();
        }
        break;

      case 'call.ice':
        final session = active;
        if (session == null || session.callId != callId) return;
        final parsed = parseCallIceEvent(event);
        if (parsed == null) return;
        final ice = RTCIceCandidate(
          parsed['candidate'] as String,
          parsed['sdpMid'] as String?,
          parsed['sdpMLineIndex'] as int?,
        );
        final pc = session._pc;
        if (pc == null || !_remoteDescSet) {
          _pendingRemoteIce.add(ice);
        } else {
          await _addRemoteIce(pc, ice);
        }
        break;

      case 'call.reject':
      case 'call.busy':
      case 'call.cancel':
      case 'call.timeout':
      case 'call.failed':
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
        if (active != session || session.phase == CallPhase.ended) return;
        final sdp = row['offer_sdp'] as String?;
        if (sdp == null) return;
        _pendingOffer = {
          'type': 'call.offer',
          'conversation_id': session.conversationId,
          'call_id': session.callId,
          'sdp': sdp,
          'sdp_type': row['offer_sdp_type'] as String? ?? 'offer',
        };
        await _maybeApplyStoredOffer(session);
        return;
      }
    } catch (_) {}
  }

  Future<bool?> _serverHasPendingCall(String callId) async {
    try {
      final pending = await api.fetchPendingCalls();
      return pending.any((row) => row['call_id'] == callId);
    } catch (_) {
      // A live call must not be discarded just because a reconciliation request
      // failed. Keeping it and replying busy is the safe fallback.
      return null;
    }
  }

  void _cancelOutgoingTimeout() {
    _outgoingTimeout?.cancel();
    _outgoingTimeout = null;
  }

  void _cancelMediaConnectTimeout() {
    _mediaConnectTimeout?.cancel();
    _mediaConnectTimeout = null;
  }

  void _armOutgoingTimeout(CallSession session) {
    _cancelOutgoingTimeout();
    final timeout = session.deliveryState == null
        ? callTotalTimeout
        : outgoingTimeoutForDelivery(session.deliveryState);
    _outgoingTimeout = Timer(timeout, () async {
      if (active?.callId != session.callId) return;
      if (!outgoingTimeoutMayFire(
        phase: session.phase,
        remoteAnswered: _remoteDescSet,
      )) {
        return;
      }
      session.error ??= session.deliveryState == CallDeliveryState.unreachable
          ? unreachableCallMessage(session.peerName, session.deliveryState)
          : noAnswerCallMessage(session.peerName);
      await _hangUp(local: true, skipSignal: true);
      realtime.sendCallSignal({
        'type': 'call.timeout',
        'conversation_id': session.conversationId,
        'call_id': session.callId,
      });
    });
  }

  void _armMediaConnectTimeout(CallSession session) {
    if (!shouldArmMediaConnectTimeout(
      phase: session.phase,
      remoteDescSet: _remoteDescSet,
    )) {
      return;
    }
    _cancelMediaConnectTimeout();
    _mediaConnectTimeout = Timer(
      callMediaConnectTimeout,
      () => unawaited(_finishMediaConnectTimeout(session)),
    );
  }

  Future<void> _finishMediaConnectTimeout(CallSession session) async {
    if (active?.callId != session.callId) return;
    if (session.phase == CallPhase.active || session.phase == CallPhase.ended) {
      return;
    }
    if (session.phase != CallPhase.connecting) return;

    // A transient ICE disconnect owns its own 12-second grace. Do not let the
    // shorter post-answer deadline cut through that grace and falsely end a
    // call that is still recovering.
    final graceRemaining = session.mediaReconnectGraceRemaining;
    if (graceRemaining > Duration.zero) {
      _mediaConnectTimeout = Timer(
        graceRemaining,
        () => unawaited(_finishMediaConnectTimeout(session)),
      );
      return;
    }

    session.error ??= callMediaFailedMessage(
      iceAddFailures: session.iceAddFailures,
    );
    await _failCall(session, reason: 'media_connect_failed');
  }

  Future<void> _failCall(CallSession session, {required String reason}) async {
    if (active != session) return;
    realtime.sendCallSignal({
      'type': 'call.failed',
      'conversation_id': session.conversationId,
      'call_id': session.callId,
      'reason': reason,
    });
    await _hangUp(local: true, skipSignal: true);
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
    if (session.phase == CallPhase.active) {
      _cancelMediaConnectTimeout();
    }
    notifyListeners();
    unawaited(_syncCallAudio(session));
    unawaited(_syncCallTunnelHold(session));
  }

  Future<void> _syncCallTunnelHold(CallSession session) async {
    final hold = callPhaseNeedsTunnelHold(session.phase);
    await onCallTunnelHold?.call(hold);
  }

  Future<void> _syncCallAudio(CallSession session) async {
    final muted = isConversationMuted?.call(session.conversationId) ?? false;
    await CallAudioController.instance.syncAlerts(
      phase: session.phase,
      conversationMuted: muted,
      delivery: session.deliveryState,
    );
    if (session.phase == CallPhase.connecting ||
        session.phase == CallPhase.active) {
      await CallAudioController.instance.prepareInCallAudio();
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
    _cancelOutgoingTimeout();
    _cancelMediaConnectTimeout();
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
    await _syncCallTunnelHold(session);
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
    _remoteDescApplying = false;
    _localTracksAdded = false;
    _ringingAckSent = false;
    _cancelMediaConnectTimeout();
  }

  @override
  void dispose() {
    unbind();
    _cancelOutgoingTimeout();
    _cancelMediaConnectTimeout();
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
