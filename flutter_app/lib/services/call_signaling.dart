/// Pure call phase rules shared by [CallService] and unit tests.
library;

/// How the server delivered an outgoing invite to the callee.
enum CallDeliveryState {
  /// Callee had an active WebSocket when the invite was sent.
  websocket,

  /// Callee was offline but at least one FCM wake-up was attempted.
  pushAttempted,

  /// No live socket and no push could be attempted (no tokens / FCM off).
  unreachable,
}

/// Lifecycle of one peer call.
enum CallPhase {
  idle,

  /// Caller side: invite sent, waiting for callee delivery ack.
  outgoing,

  /// Caller side: callee acknowledged and their phone is ringing.
  ringing,

  /// Callee side: invite received, not yet accepted.
  incoming,
  connecting,
  active,
  ended,
}

/// Default unanswered-call timeout (matches server TTL).
const callTotalTimeout = Duration(seconds: 90);

/// How long to wait for ringing after delivery when the callee looks reachable.
const callRingingWaitTimeout = Duration(seconds: 45);

/// Terminate quickly when the server says the callee is unreachable.
const callUnreachableTimeout = Duration(seconds: 8);

/// After SDP answer, how long to wait for ICE/media before surfacing failure.
///
/// Kept short (18s) so "Connecting…" does not linger, but still above typical
/// Tailscale direct-path setup; ring/no-answer timers stop once answer arrives.
const callMediaConnectTimeout = Duration(seconds: 18);

/// Parses server `call.delivery` state strings.
CallDeliveryState? parseCallDeliveryState(String? raw) {
  return switch (raw) {
    'websocket' => CallDeliveryState.websocket,
    'push_attempted' => CallDeliveryState.pushAttempted,
    'unreachable' => CallDeliveryState.unreachable,
    _ => null,
  };
}

/// Outgoing timeout after the server reports delivery state.
Duration outgoingTimeoutForDelivery(CallDeliveryState? delivery) {
  if (delivery == CallDeliveryState.unreachable) {
    return callUnreachableTimeout;
  }
  return callRingingWaitTimeout;
}

/// Outgoing label shown to the caller before explicit callee ack.
String outgoingCallLabel(CallPhase phase) {
  return switch (phase) {
    CallPhase.outgoing => 'Calling…',
    CallPhase.ringing => 'Ringing…',
    CallPhase.connecting => 'Connecting…',
    CallPhase.active => 'Connected',
    CallPhase.incoming => 'Incoming call',
    CallPhase.ended => 'Call ended',
    CallPhase.idle => '',
  };
}

/// What the caller is told while the invite makes its way to the other phone.
///
/// "Trying to reach…" was the only word for every one of these, silent and
/// identical whether the invite had been delivered, was waking a sleeping
/// phone, or had nowhere to go at all.
String outgoingCallStatus(
  CallPhase phase,
  CallDeliveryState? delivery, {
  String peerName = '',
}) {
  if (phase != CallPhase.outgoing) return outgoingCallLabel(phase);
  final who = peerName.trim().isNotEmpty ? peerName.trim() : 'them';
  return switch (delivery) {
    null => 'Calling…',
    CallDeliveryState.websocket => 'Ringing their phone…',
    CallDeliveryState.pushAttempted => 'Waking their phone…',
    CallDeliveryState.unreachable => "Can't reach $who",
  };
}

/// User-facing hint when the callee cannot be reached at all.
String? unreachableCallMessage(String peerName, CallDeliveryState? delivery) {
  if (delivery != CallDeliveryState.unreachable) return null;
  final who = peerName.isNotEmpty ? peerName : 'them';
  return "Couldn't reach $who. Check Tailscale is connected on both phones.";
}

/// Hint when delivery looked possible but ringing never arrived.
String noAnswerCallMessage(String peerName) {
  final who = peerName.isNotEmpty ? peerName : 'them';
  return "No answer from $who. Check Tailscale is connected on both phones.";
}

/// Whether the caller may transition to [CallPhase.ringing].
bool callerMayShowRinging(CallPhase phase) =>
    phase == CallPhase.outgoing || phase == CallPhase.ringing;

/// Next caller phase after a server event (pure, no side effects).
CallPhase? callerPhaseAfterEvent(CallPhase current, String eventType) {
  switch (eventType) {
    case 'call.ringing':
      if (callerMayShowRinging(current)) return CallPhase.ringing;
      return null;
    case 'call.answer':
      if (current == CallPhase.outgoing ||
          current == CallPhase.ringing ||
          current == CallPhase.connecting) {
        return CallPhase.connecting;
      }
      return null;
    case 'call.reject':
    case 'call.busy':
    case 'call.cancel':
    case 'call.timeout':
    case 'call.failed':
    case 'call.end':
      if (current != CallPhase.ended && current != CallPhase.idle) {
        return CallPhase.ended;
      }
      return null;
    default:
      return null;
  }
}

/// Whether the callee should send `call.ringing` for this invite.
bool calleeShouldAckRinging({required bool alreadyAcked, CallPhase? phase}) {
  if (alreadyAcked) return false;
  return phase == null || phase == CallPhase.incoming;
}

/// Maps a terminal signaling event to a call-log outcome for the caller.
String callerLogOutcome(String eventType, {required bool wasRinging}) {
  return switch (eventType) {
    'call.busy' => 'busy',
    'call.reject' => 'rejected',
    'call.cancel' => 'missed',
    'call.timeout' => wasRinging ? 'missed' : 'missed',
    'call.failed' => 'failed',
    'call.end' => 'answered',
    _ => wasRinging ? 'missed' : 'missed',
  };
}

/// Whether an outgoing call should send `call.cancel` instead of `call.end`.
bool outgoingShouldCancel(CallPhase phase) =>
    phase == CallPhase.outgoing || phase == CallPhase.ringing;

/// Ring/no-answer timers must stop once the callee answers; media has its own window.
bool shouldCancelOutgoingTimeoutOnAnswer(String eventType) =>
    eventType == 'call.answer';

/// Whether the outgoing ring timer may still end the call.
bool outgoingTimeoutMayFire({
  required CallPhase phase,
  required bool remoteAnswered,
}) {
  if (phase == CallPhase.active || phase == CallPhase.ended) return false;
  if (remoteAnswered) return false;
  return true;
}

/// Arm a post-answer media connect watchdog once remote SDP is in place.
bool shouldArmMediaConnectTimeout({
  required CallPhase phase,
  required bool remoteDescSet,
}) {
  return phase == CallPhase.connecting && remoteDescSet;
}

/// Callee applies the remote offer exactly once after local setup is complete.
bool calleeMayApplyRemoteOffer({
  required bool localTracksAdded,
  required bool remoteDescSet,
  required bool remoteDescApplying,
  required bool isOutgoing,
}) {
  if (isOutgoing) return false;
  if (!localTracksAdded) return false;
  if (remoteDescSet || remoteDescApplying) return false;
  return true;
}

/// `call.offer` events for the callee are stored, never applied inline.
bool callOfferEventShouldStoreOnly({required bool isOutgoing}) => !isOutgoing;

/// Whether accept/recovery should try applying a stored offer after setup.
bool calleeShouldApplyStoredOffer({
  required bool localTracksAdded,
  required bool remoteDescSet,
  required bool remoteDescApplying,
  required Map<String, dynamic>? pendingOffer,
}) {
  return pendingOffer != null &&
      calleeMayApplyRemoteOffer(
        localTracksAdded: localTracksAdded,
        remoteDescSet: remoteDescSet,
        remoteDescApplying: remoteDescApplying,
        isOutgoing: false,
      );
}

/// In-call audio output routes exposed to the user.
enum CallAudioRoute { earpiece, speaker, bluetooth }

String callAudioRouteLabel(CallAudioRoute route) => switch (route) {
  CallAudioRoute.earpiece => 'Earpiece',
  CallAudioRoute.speaker => 'Speaker',
  CallAudioRoute.bluetooth => 'Bluetooth',
};

CallAudioRoute? parseCallAudioRoute(String? raw) => switch (raw) {
  'earpiece' => CallAudioRoute.earpiece,
  'speaker' => CallAudioRoute.speaker,
  'bluetooth' => CallAudioRoute.bluetooth,
  _ => null,
};

String callAudioRouteWire(CallAudioRoute route) => switch (route) {
  CallAudioRoute.earpiece => 'earpiece',
  CallAudioRoute.speaker => 'speaker',
  CallAudioRoute.bluetooth => 'bluetooth',
};

/// Where every call starts, in order of preference.
///
/// A headset if one is connected, otherwise the earpiece, and the speaker only
/// when there is nothing else. Video calls used to open on the speaker, which
/// put the call on show for whoever else was in the room and ignored a headset
/// that was already on. The kind of call no longer decides this; only the person
/// on it does, with the audio button.
const callRoutePriority = <CallAudioRoute>[
  CallAudioRoute.bluetooth,
  CallAudioRoute.earpiece,
  CallAudioRoute.speaker,
];

/// The route a call should open on, given what this phone can reach.
CallAudioRoute preferredCallRoute(Iterable<CallAudioRoute> available) {
  final reachable = available.toSet();
  for (final route in callRoutePriority) {
    if (reachable.contains(route)) return route;
  }
  return reachable.isEmpty ? CallAudioRoute.earpiece : available.first;
}

/// Whether incoming ringtone/vibration should play for this phase.
bool shouldPlayIncomingAlert(CallPhase phase) => phase == CallPhase.incoming;

/// Whether the caller should hear a ringback tone.
///
/// It starts the moment the call is placed, not when the other phone acks: a
/// caller staring at a silent screen has no way to tell a call that is on its
/// way from one that never left. The exception is a callee the server says it
/// cannot reach — that silence is the answer, and the screen says so.
bool shouldPlayOutgoingRingback(
  CallPhase phase, {
  CallDeliveryState? delivery,
}) {
  if (phase == CallPhase.ringing) return true;
  if (phase != CallPhase.outgoing) return false;
  return delivery != CallDeliveryState.unreachable;
}

/// Alert tones must stop once media connects or the call ends.
bool shouldStopCallAlerts(CallPhase phase) =>
    phase == CallPhase.connecting ||
    phase == CallPhase.active ||
    phase == CallPhase.ended ||
    phase == CallPhase.idle;

/// ICE/peer link quality for in-call media (pure, string wire values).
enum CallMediaLinkState {
  idle,
  gathering,
  checking,
  connected,
  reconnecting,
  failed,
}

/// How long a transient ICE `disconnected` may last before we treat it as dead.
const callMediaReconnectGrace = Duration(seconds: 12);

/// Parses `sdpMLineIndex` from JSON numbers or numeric strings.
int? parseIceMLineIndex(dynamic raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

/// Normalizes a `call.ice` event into candidate fields, or null when unusable.
Map<String, dynamic>? parseCallIceEvent(Map<String, dynamic> event) {
  final candidate = event['candidate'];
  if (candidate is! String || candidate.isEmpty) return null;
  return {
    'candidate': candidate,
    'sdpMid': event['sdpMid'] as String?,
    'sdpMLineIndex': parseIceMLineIndex(event['sdpMLineIndex']),
  };
}

/// Safe diagnostic when [RTCPeerConnection.addCandidate] fails — no SDP/secrets.
String iceAddFailureDiagnostic(Object error, {required bool hadRemoteDesc}) =>
    'ICE add failed (remoteDesc=$hadRemoteDesc, ${error.runtimeType})';

/// Phases where the app-owned Tailscale tunnel must stay up in background.
bool callPhaseNeedsTunnelHold(CallPhase phase) =>
    phase == CallPhase.outgoing ||
    phase == CallPhase.ringing ||
    phase == CallPhase.incoming ||
    phase == CallPhase.connecting ||
    phase == CallPhase.active;

/// User-facing media failure copy; includes ICE apply count when relevant.
String callMediaFailedMessage({required int iceAddFailures}) {
  if (iceAddFailures > 0) {
    return 'Call media failed to connect. ICE candidates could not be '
        'applied ($iceAddFailures). Check Tailscale is direct on both phones.';
  }
  return 'Call media failed to connect. Check Tailscale is direct '
      '(not relay-only).';
}

CallMediaIceWire? parseCallMediaIceWire(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final tail = raw.contains('.') ? raw.split('.').last : raw;
  return switch (tail) {
    'new' || 'RTCIceConnectionStateNew' => CallMediaIceWire.new_,
    'checking' || 'RTCIceConnectionStateChecking' => CallMediaIceWire.checking,
    'connected' ||
    'RTCIceConnectionStateConnected' => CallMediaIceWire.connected,
    'completed' ||
    'RTCIceConnectionStateCompleted' => CallMediaIceWire.completed,
    'failed' || 'RTCIceConnectionStateFailed' => CallMediaIceWire.failed,
    'disconnected' ||
    'RTCIceConnectionStateDisconnected' => CallMediaIceWire.disconnected,
    'closed' || 'RTCIceConnectionStateClosed' => CallMediaIceWire.closed,
    _ => null,
  };
}

CallMediaPeerWire? parseCallMediaPeerWire(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final tail = raw.contains('.') ? raw.split('.').last : raw;
  return switch (tail) {
    'new' || 'RTCPeerConnectionStateNew' => CallMediaPeerWire.new_,
    'connecting' ||
    'RTCPeerConnectionStateConnecting' => CallMediaPeerWire.connecting,
    'connected' ||
    'RTCPeerConnectionStateConnected' => CallMediaPeerWire.connected,
    'disconnected' ||
    'RTCPeerConnectionStateDisconnected' => CallMediaPeerWire.disconnected,
    'failed' || 'RTCPeerConnectionStateFailed' => CallMediaPeerWire.failed,
    'closed' || 'RTCPeerConnectionStateClosed' => CallMediaPeerWire.closed,
    _ => null,
  };
}

/// Maps ICE + peer states to a single link state for UI/policy.
CallMediaLinkState deriveCallMediaLinkState({
  CallMediaIceWire? ice,
  CallMediaPeerWire? peer,
}) {
  if (ice == CallMediaIceWire.connected ||
      ice == CallMediaIceWire.completed ||
      peer == CallMediaPeerWire.connected) {
    return CallMediaLinkState.connected;
  }
  if (ice == CallMediaIceWire.failed || peer == CallMediaPeerWire.failed) {
    return CallMediaLinkState.failed;
  }
  if (ice == CallMediaIceWire.disconnected ||
      peer == CallMediaPeerWire.disconnected) {
    return CallMediaLinkState.reconnecting;
  }
  if (ice == CallMediaIceWire.checking ||
      peer == CallMediaPeerWire.connecting) {
    return CallMediaLinkState.checking;
  }
  if (ice == CallMediaIceWire.new_) {
    return CallMediaLinkState.gathering;
  }
  return CallMediaLinkState.idle;
}

/// Whether a transient ICE disconnect should start the reconnect grace window.
bool shouldStartMediaReconnectGrace({
  required CallPhase phase,
  required CallMediaIceWire? ice,
  required CallMediaPeerWire? peer,
}) {
  if (phase != CallPhase.connecting && phase != CallPhase.active) return false;
  if (ice != CallMediaIceWire.disconnected) return false;
  if (peer == CallMediaPeerWire.connected) return false;
  return true;
}

/// Whether media should surface a terminal failure to the user.
bool shouldReportMediaConnectFailure({
  required CallPhase phase,
  required CallMediaIceWire? ice,
  required CallMediaPeerWire? peer,
  required bool graceExpired,
}) {
  if (phase != CallPhase.connecting && phase != CallPhase.active) return false;
  if (ice == CallMediaIceWire.failed || peer == CallMediaPeerWire.failed) {
    return true;
  }
  if (!graceExpired) return false;
  if (ice == CallMediaIceWire.disconnected &&
      peer != CallMediaPeerWire.connected) {
    return true;
  }
  return false;
}

/// ICE connection state wire values (WebRTC enum tails).
enum CallMediaIceWire {
  new_,
  gathering,
  checking,
  connected,
  completed,
  failed,
  disconnected,
  closed,
}

/// Peer connection state wire values (WebRTC enum tails).
enum CallMediaPeerWire {
  new_,
  connecting,
  connected,
  disconnected,
  failed,
  closed,
}
