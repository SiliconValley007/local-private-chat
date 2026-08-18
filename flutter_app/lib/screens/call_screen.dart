import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/call_service.dart';
import '../theme.dart';

/// Whether a full-screen call route is already on the navigator stack.
bool callScreenRouteOpen = false;

/// Opens [CallScreen] once; ignores duplicate pushes while a route is up.
Future<void> presentCallScreen(BuildContext context) async {
  if (callScreenRouteOpen) return;
  final nav = Navigator.of(context, rootNavigator: true);
  callScreenRouteOpen = true;
  try {
    await nav.push(
      MaterialPageRoute(
        fullscreenDialog: true,
        settings: const RouteSettings(name: 'CallScreen'),
        builder: (_) => const CallScreen(),
      ),
    );
  } finally {
    callScreenRouteOpen = false;
  }
}

/// How far above the safe bottom edge the call controls sit.
///
/// Android puts its screen-recording privacy notice in a system window over the
/// strip just above the navigation area, and a system window always draws on top
/// of the app: no z-order, scrim, or elevation can rescue a button underneath
/// it. Mute and End therefore keep clear of that strip entirely, scaled to the
/// screen so they stay within thumb reach on short and tall phones alike.
double callControlsBottomInset(double screenHeight) =>
    (screenHeight * 0.17).clamp(120.0, 220.0);

/// Whether tapping the picture may clear the name, timer, and buttons away.
///
/// Only on a video call that is under way: on a voice call there is nothing
/// underneath to look at, and while a call is being offered or answered the
/// buttons are the only way to take it.
bool callChromeCanHide({required bool isVideo, required CallPhase phase}) =>
    isVideo && phase == CallPhase.active;

/// Full-screen voice/video call chrome (incoming, outgoing, active).
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Timer? _tick;
  Timer? _popRetry;
  bool _didPop = false;
  bool _chromeHidden = false;
  CallService? _calls;

  /// Last live session, kept so the route never paints a black spinner while
  /// popping after the call service has already cleared [CallService.active].
  CallSession? _lastSession;

  static const _callCanvas = Color(0xFF0B1220);

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _calls = context.read<AppState>().calls;
      _calls!.addListener(_onCallChanged);
      _onCallChanged();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _popRetry?.cancel();
    _calls?.removeListener(_onCallChanged);
    // Leaving the call must never leave the phone without its status bar.
    if (_chromeHidden) _applySystemBars(hidden: false);
    super.dispose();
  }

  Future<void> _onBackPressed() async {
    final session = _calls?.active;
    if (session == null) {
      _popOnce();
      return;
    }
    if (session.phase == CallPhase.incoming) {
      await _calls?.rejectIncoming();
    } else if (session.phase != CallPhase.ended) {
      await _calls?.endCall();
    }
    _popOnce();
  }

  void _onCallChanged() {
    final session = _calls?.active;
    if (session != null) _lastSession = session;
    if (session == null || session.phase == CallPhase.ended) {
      _popOnce();
    }
  }

  /// Leaves the call route, whatever else is going on.
  ///
  /// This used to call `maybePop`, which asks the route's own [PopScope] for
  /// permission — and the guard that stops a live call being swiped away
  /// refused it. "Call ended" then had no exit at all: the button, the system
  /// back gesture, and the automatic close all went through here and were all
  /// denied, so the only way out was to kill the app.
  void _popOnce() {
    if (_didPop || !mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    _didPop = true;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      // Something was pushed on top (a permission sheet, say): take this route
      // out from under it rather than popping whatever is in front.
      navigator.removeRoute(route);
    }
    // Nothing here may be a one-shot. If the pop does not take, the periodic
    // tick rebuilds, sees the call is over, and asks again.
    _popRetry?.cancel();
    _popRetry = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _didPop = false;
    });
  }

  void _schedulePop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _popOnce();
    });
  }

  double _controlsBottomFor(BuildContext context) =>
      callControlsBottomInset(MediaQuery.sizeOf(context).height);

  void _toggleChrome() {
    setState(() => _chromeHidden = !_chromeHidden);
    _applySystemBars(hidden: _chromeHidden);
  }

  /// Nothing but the picture while the chrome is away, system bars included.
  ///
  /// Coming back means edge-to-edge rather than a fixed set of overlays: that is
  /// what the rest of the app runs in, and recent Android versions insist on it.
  void _applySystemBars({required bool hidden}) {
    SystemChrome.setEnabledSystemUIMode(
      hidden ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  @override
  Widget build(BuildContext context) {
    final calls = context.watch<AppState>().calls;
    final live = calls.active;
    if (live != null) _lastSession = live;
    final session = live ?? _lastSession;

    // No session was ever painted: leave without a loading body so the
    // previous chat/inbox stays visible under the popping route.
    if (session == null) {
      _schedulePop();
      return const Scaffold(
        backgroundColor: _callCanvas,
        body: SizedBox.expand(),
      );
    }

    final ending = live == null || session.phase == CallPhase.ended;
    if (ending) _schedulePop();

    final phase = ending ? CallPhase.ended : session.phase;
    final title = switch (phase) {
      CallPhase.incoming =>
        'Incoming ${session.isVideo ? 'video' : 'voice'} call',
      CallPhase.outgoing => outgoingCallStatus(
        phase,
        session.deliveryState,
        peerName: session.peerName,
      ),
      CallPhase.ringing => outgoingCallLabel(phase),
      CallPhase.connecting => outgoingCallLabel(phase),
      CallPhase.active => formatCallElapsed(session.elapsed),
      CallPhase.ended => 'Call ended',
      CallPhase.idle => '',
    };

    final canHide = callChromeCanHide(isVideo: session.isVideo, phase: phase);
    if (!canHide && _chromeHidden) {
      // A call that just ended, or a video call that dropped to voice, must not
      // keep its only buttons hidden.
      _chromeHidden = false;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _applySystemBars(hidden: false),
      );
    }
    final chromeShown = !_chromeHidden;

    return PopScope(
      // A live call is worth confirming with a hang-up before leaving, so back
      // is intercepted then. Once the call is over there is nothing to protect
      // and back closes the route directly.
      canPop: ending,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_onBackPressed());
      },
      child: Scaffold(
        backgroundColor: _callCanvas,
        // The picture runs to the edges of the screen; only the chrome over it
        // keeps clear of the system insets.
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (session.isVideo) _VideoStage(session: session),
            // Tapping the picture puts the chrome away and brings it back, so
            // the person on the other end can be watched without buttons over
            // them.
            if (canHide)
              Positioned.fill(
                child: GestureDetector(
                  key: const Key('call-chrome-toggle'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleChrome,
                ),
              ),
            IgnorePointer(
              key: const Key('call-chrome'),
              ignoring: !chromeShown,
              child: AnimatedOpacity(
                opacity: chromeShown ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: SafeArea(
                  child: Stack(
                    children: [
                      if (!session.isVideo)
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircleAvatar(
                                radius: 48,
                                backgroundColor: AppColors.brand.withValues(
                                  alpha: 0.25,
                                ),
                                child: Text(
                                  session.peerName.isNotEmpty
                                      ? session.peerName.characters.first
                                            .toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                    fontSize: 36,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                              Text(
                                session.peerName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                title,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (session.isVideo)
                        Positioned(
                          top: 24,
                          left: 0,
                          right: 0,
                          child: Column(
                            children: [
                              Text(
                                session.peerName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                title,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                      if (session.error != null)
                        Positioned(
                          left: 16,
                          right: 16,
                          // Clear of the controls, wherever this screen's
                          // height put them.
                          bottom: _controlsBottomFor(context) + 108,
                          child: Material(
                            color: Colors.red.shade900.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                session.error!,
                                style: const TextStyle(color: Colors.white),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: _controlsBottomFor(context),
                        child: _CallControls(
                          session: session,
                          ending: ending,
                          availableRoutes: calls.availableRoutes,
                          onAccept: () => calls.acceptIncoming(),
                          onReject: () => calls.rejectIncoming(),
                          onEnd: () => calls.endCall(),
                          onToggleMute: () => session.setMuted(!session.muted),
                          onToggleCam: () =>
                              session.setCameraOff(!session.cameraOff),
                          onSelectRoute: (route) => calls.setAudioRoute(route),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoStage extends StatelessWidget {
  const _VideoStage({required this.session});

  final CallSession session;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (session.remoteStream != null)
          RTCVideoView(
            session.remoteRenderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          )
        else
          const ColoredBox(color: Color(0xFF0B1220)),
        if (session.localStream != null && !session.cameraOff)
          Positioned(
            right: 16,
            // The picture behind it runs under the status bar, so the preview
            // has to step around the notch itself.
            top: MediaQuery.paddingOf(context).top + 72,
            width: 110,
            height: 160,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: RTCVideoView(
                session.localRenderer,
                mirror: true,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            ),
          ),
      ],
    );
  }
}

class _CallControls extends StatelessWidget {
  const _CallControls({
    required this.session,
    required this.onAccept,
    required this.onReject,
    required this.onEnd,
    required this.onToggleMute,
    required this.onToggleCam,
    required this.onSelectRoute,
    required this.availableRoutes,
    this.ending = false,
  });

  final CallSession session;
  final bool ending;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback onEnd;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleCam;
  final void Function(CallAudioRoute route) onSelectRoute;
  final List<CallAudioRoute> availableRoutes;

  @override
  Widget build(BuildContext context) {
    if (ending) {
      return const SizedBox(height: 80);
    }
    if (session.phase == CallPhase.incoming) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _RoundBtn(
            color: Colors.red,
            icon: Icons.call_end_rounded,
            label: 'Decline',
            onTap: onReject,
          ),
          _RoundBtn(
            color: Colors.green,
            icon: Icons.call_rounded,
            label: 'Accept',
            onTap: onAccept,
          ),
        ],
      );
    }

    final controls = <Widget>[
      _RoundBtn(
        color: session.muted ? Colors.white24 : Colors.white12,
        icon: session.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
        label: session.muted ? 'Unmute' : 'Mute',
        onTap: onToggleMute,
      ),
      _RoundBtn(
        color: Colors.red,
        icon: Icons.call_end_rounded,
        label: 'End',
        onTap: onEnd,
      ),
      if (session.isVideo)
        _RoundBtn(
          color: session.cameraOff ? Colors.white24 : Colors.white12,
          icon: session.cameraOff
              ? Icons.videocam_off_rounded
              : Icons.videocam_rounded,
          label: session.cameraOff ? 'Camera' : 'Camera',
          onTap: onToggleCam,
        ),
      if (availableRoutes.length > 1)
        _RoundBtn(
          color: Colors.white12,
          icon: _routeIcon(session.audioRoute),
          label: _routeLabel(session.audioRoute),
          onTap: () => _showRoutePicker(context),
        ),
    ];

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 24,
      runSpacing: 12,
      children: controls,
    );
  }

  IconData _routeIcon(CallAudioRoute? route) => switch (route) {
    CallAudioRoute.speaker => Icons.volume_up_rounded,
    CallAudioRoute.bluetooth => Icons.bluetooth_audio_rounded,
    CallAudioRoute.earpiece || null => Icons.hearing_rounded,
  };

  String _routeLabel(CallAudioRoute? route) =>
      route == null ? 'Audio' : callAudioRouteLabel(route);

  Future<void> _showRoutePicker(BuildContext context) async {
    final picked = await showModalBottomSheet<CallAudioRoute>(
      context: context,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final route in availableRoutes)
                ListTile(
                  leading: Icon(_routeIcon(route), color: Colors.white70),
                  title: Text(
                    callAudioRouteLabel(route),
                    style: const TextStyle(color: Colors.white),
                  ),
                  trailing: session.audioRoute == route
                      ? const Icon(Icons.check_rounded, color: Colors.white70)
                      : null,
                  onTap: () => Navigator.pop(ctx, route),
                ),
            ],
          ),
        );
      },
    );
    if (picked != null) onSelectRoute(picked);
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 64,
              height: 64,
              child: Icon(icon, color: Colors.white, size: 30),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }
}
