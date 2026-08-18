import 'package:flutter/material.dart';

/// Drives [NudgeOverlay]. Call [play] to run the animation once; it can be
/// fired again mid-animation and simply restarts. [glyph] is the emoji shown
/// in the centre, so each nudge flavour (wave, poke, hug, kiss) looks distinct.
class NudgeOverlayController extends ChangeNotifier {
  int _tick = 0;
  int get tick => _tick;

  String _glyph = '\u{1F44B}';
  String get glyph => _glyph;

  String? _caption;
  String? get caption => _caption;

  void play({String glyph = '\u{1F44B}', String? caption}) {
    _glyph = glyph;
    _caption = caption;
    _tick++;
    notifyListeners();
  }
}

/// A brief, non-interactive "wave" that expands over the chat when a nudge is
/// sent or received — Hike's poke, rebuilt: concentric rings plus a waving hand.
///
/// Wrapped in [IgnorePointer] so it never eats a tap, and it renders nothing at
/// rest, so it is cheap to keep mounted in the chat's Stack.
class NudgeOverlay extends StatefulWidget {
  const NudgeOverlay({super.key, required this.controller});

  final NudgeOverlayController controller;

  @override
  State<NudgeOverlay> createState() => _NudgeOverlayState();
}

class _NudgeOverlayState extends State<NudgeOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onPlay);
    // Reset to the dismissed state when the run finishes so the overlay renders
    // nothing at rest and can be replayed cleanly.
    _anim.addStatusListener((status) {
      if (status == AnimationStatus.completed) _anim.reset();
    });
  }

  @override
  void didUpdateWidget(NudgeOverlay old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onPlay);
      widget.controller.addListener(_onPlay);
    }
  }

  void _onPlay() => _anim.forward(from: 0);

  @override
  void dispose() {
    widget.controller.removeListener(_onPlay);
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) {
          if (_anim.isDismissed) return const SizedBox.shrink();
          final t = Curves.easeOut.transform(_anim.value);
          // Fade the whole thing out over the back third of the run.
          final opacity = (1.0 - ((_anim.value - 0.6) / 0.4)).clamp(0.0, 1.0);
          return Opacity(
            opacity: opacity,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: Size.infinite,
                  painter: _RingsPainter(progress: t, color: accent),
                ),
                Transform.scale(
                  scale: 0.6 + t * 0.9,
                  child: Transform.rotate(
                    angle: (t * 6.28) % 6.28 * 0.08 * (t < 0.5 ? 1 : -1),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.controller.glyph,
                          style: const TextStyle(fontSize: 72),
                        ),
                        if (widget.controller.caption != null &&
                            widget.controller.caption!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Material(
                              color: Theme.of(
                                context,
                              ).colorScheme.surface.withValues(alpha: 0.88),
                              borderRadius: BorderRadius.circular(20),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 8,
                                ),
                                child: Text(
                                  widget.controller.caption!,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide * 0.55;
    for (var i = 0; i < 3; i++) {
      final ringT = (progress - i * 0.12).clamp(0.0, 1.0);
      if (ringT <= 0) continue;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = color.withValues(alpha: (1 - ringT) * 0.5);
      canvas.drawCircle(center, maxRadius * ringT, paint);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) =>
      old.progress != progress || old.color != color;
}
