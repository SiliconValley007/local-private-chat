import 'dart:async';

import 'package:flutter/material.dart';
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

/// Full-screen voice/video call chrome (incoming, outgoing, active).
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Timer? _tick;
  bool _didPop = false;
  CallService? _calls;

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
    _calls?.removeListener(_onCallChanged);
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
    if (session == null || session.phase == CallPhase.ended) {
      _popOnce();
    }
  }

  void _popOnce() {
    if (_didPop || !mounted) return;
    _didPop = true;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final calls = context.watch<AppState>().calls;
    final session = calls.active;
    if (session == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _popOnce());
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    final phase = session.phase;
    final title = switch (phase) {
      CallPhase.incoming =>
        'Incoming ${session.isVideo ? 'video' : 'voice'} call',
      CallPhase.outgoing => outgoingCallLabel(phase),
      CallPhase.ringing => outgoingCallLabel(phase),
      CallPhase.connecting => outgoingCallLabel(phase),
      CallPhase.active => formatCallElapsed(session.elapsed),
      CallPhase.ended => 'Call ended',
      CallPhase.idle => '',
    };

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_onBackPressed());
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1220),
        body: SafeArea(
          child: Stack(
            children: [
              if (session.isVideo) _VideoStage(session: session),
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
                              ? session.peerName.characters.first.toUpperCase()
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
                  bottom: 140,
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
                bottom: 28,
                child: _CallControls(
                  session: session,
                  availableRoutes: calls.availableRoutes,
                  onAccept: () => calls.acceptIncoming(),
                  onReject: () => calls.rejectIncoming(),
                  onEnd: () => calls.endCall(),
                  onToggleMute: () => session.setMuted(!session.muted),
                  onToggleCam: () => session.setCameraOff(!session.cameraOff),
                  onSelectRoute: (route) => calls.setAudioRoute(route),
                ),
              ),
            ],
          ),
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
            top: 72,
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
  });

  final CallSession session;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback onEnd;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleCam;
  final void Function(CallAudioRoute route) onSelectRoute;
  final List<CallAudioRoute> availableRoutes;

  @override
  Widget build(BuildContext context) {
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
