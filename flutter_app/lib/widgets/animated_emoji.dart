import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Remembers which single-emoji messages have already played their entrance,
/// so scrolling back over a chat does not set every one of them bouncing again.
///
/// Keys are message identities, not list positions: a pending message keeps its
/// client id when the server id arrives, so a sent emoji animates exactly once.
class SoloEmojiPlaybackLedger {
  SoloEmojiPlaybackLedger({this.capacity = 400});

  /// Oldest keys are dropped first; a long chat cannot grow this without bound.
  final int capacity;
  final LinkedHashSet<String> _played = LinkedHashSet<String>();

  bool hasPlayed(String key) => _played.contains(key);

  /// Records [key] and reports whether this is the first time it was seen.
  bool markPlayed(String key) {
    if (!_played.add(key)) return false;
    while (_played.length > capacity) {
      _played.remove(_played.first);
    }
    return true;
  }

  int get length => _played.length;
}

/// Shared across the transcript, because rows are rebuilt as they scroll.
final soloEmojiLedger = SoloEmojiPlaybackLedger();

/// Stable identity for a message's emoji animation.
String soloEmojiPlaybackKey({int? messageId, String? clientId}) {
  final client = clientId?.trim() ?? '';
  if (client.isNotEmpty) return 'client:$client';
  return 'id:${messageId ?? 0}';
}

/// Only a lone emoji is animated; two or more read as a sentence, not a
/// reaction, and a row of bouncing glyphs is noise rather than delight.
bool shouldAnimateSoloEmoji({
  required int emojiCount,
  bool animationsEnabled = true,
}) => emojiCount == 1 && animationsEnabled;

/// Restrained visual families for the procedural effect.
enum SoloEmojiEffectCategory { hearts, kisses, celebration, general }

/// Picks a category from the first emoji base in [emoji].
SoloEmojiEffectCategory classifySoloEmojiEffect(String emoji) {
  final trimmed = emoji.trim();
  if (trimmed.isEmpty) return SoloEmojiEffectCategory.general;

  for (final cp in trimmed.runes) {
    if (_isKiss(cp)) return SoloEmojiEffectCategory.kisses;
    if (_isCelebration(cp)) return SoloEmojiEffectCategory.celebration;
    if (_isHeart(cp)) return SoloEmojiEffectCategory.hearts;
    break; // First base glyph drives the variant.
  }
  return SoloEmojiEffectCategory.general;
}

bool _isHeart(int cp) =>
    cp == 0x2764 ||
    cp == 0x2665 ||
    (cp >= 0x1F493 && cp <= 0x1F49F) ||
    cp == 0x1F5A4 ||
    cp == 0x1F90D ||
    cp == 0x1F90E ||
    cp == 0x1F9E1 ||
    (cp >= 0x1FA75 && cp <= 0x1FA77);

bool _isKiss(int cp) =>
    cp == 0x1F48B ||
    (cp >= 0x1F618 && cp <= 0x1F61A) ||
    cp == 0x1F617 ||
    cp == 0x1F619;

bool _isCelebration(int cp) =>
    cp == 0x1F389 ||
    cp == 0x1F38A ||
    cp == 0x1F973 ||
    cp == 0x1F388 ||
    cp == 0x1F386 ||
    cp == 0x1F387 ||
    cp == 0x2728 ||
    cp == 0x1F381 ||
    cp == 0x1F382 ||
    cp == 0x1F383 ||
    cp == 0x1F384 ||
    cp == 0x1F385;

/// One frame of the squash/stretch launch, overshoot, glow, and particle burst.
class SoloEmojiMotionFrame {
  const SoloEmojiMotionFrame({
    required this.scaleX,
    required this.scaleY,
    required this.rotation,
    required this.glowOpacity,
    required this.glowRadiusFactor,
    required this.particleStrength,
  });

  final double scaleX;
  final double scaleY;
  final double rotation;
  final double glowOpacity;
  final double glowRadiusFactor;

  /// 0 when particles are gone; peaks early in the play.
  final double particleStrength;

  static const idle = SoloEmojiMotionFrame(
    scaleX: 1,
    scaleY: 1,
    rotation: 0,
    glowOpacity: 0,
    glowRadiusFactor: 0,
    particleStrength: 0,
  );
}

/// Deterministic seed so the same emoji always bursts the same way.
int soloEmojiEffectSeed(String emoji) {
  var hash = 0;
  for (final cp in emoji.runes) {
    hash = 0x1fffffff & (hash + cp);
    hash = 0x1fffffff & (hash + ((hash & 0x0007ffff) << 10));
    hash ^= hash >> 6;
  }
  hash = 0x1fffffff & (hash + ((hash & 0x03ffffff) << 3));
  hash ^= hash >> 11;
  hash = 0x1fffffff & (hash + ((hash & 0x00003fff) << 15));
  return hash == 0 ? 1 : hash;
}

/// How many radial particles this category may spawn (hard cap for lists).
int soloEmojiParticleCount(SoloEmojiEffectCategory category) =>
    switch (category) {
      SoloEmojiEffectCategory.celebration => 10,
      SoloEmojiEffectCategory.hearts => 6,
      SoloEmojiEffectCategory.kisses => 5,
      SoloEmojiEffectCategory.general => 8,
    };

/// A single procedural sparkle; positions are normalized to the emoji box.
class SoloEmojiParticleSample {
  const SoloEmojiParticleSample({
    required this.dx,
    required this.dy,
    required this.radius,
    required this.opacity,
  });

  final double dx;
  final double dy;
  final double radius;
  final double opacity;
}

double _easeOutBack(double t) {
  const c1 = 1.70158;
  const c3 = c1 + 1;
  return 1 + c3 * math.pow(t - 1, 3) + c1 * math.pow(t - 1, 2);
}

double _categoryOvershoot(SoloEmojiEffectCategory category) =>
    switch (category) {
      SoloEmojiEffectCategory.celebration => 0.11,
      SoloEmojiEffectCategory.hearts => 0.085,
      SoloEmojiEffectCategory.kisses => 0.075,
      SoloEmojiEffectCategory.general => 0.065,
    };

double _categoryTilt(SoloEmojiEffectCategory category) => switch (category) {
  SoloEmojiEffectCategory.kisses => 0.055,
  SoloEmojiEffectCategory.celebration => 0.04,
  SoloEmojiEffectCategory.hearts => 0.03,
  SoloEmojiEffectCategory.general => 0.035,
};

Color soloEmojiGlowColor(
  SoloEmojiEffectCategory category,
  Brightness brightness,
) {
  final dark = brightness == Brightness.dark;
  return switch (category) {
    SoloEmojiEffectCategory.hearts =>
      dark ? const Color(0xFFFF6B9D) : const Color(0xFFFF4D7D),
    SoloEmojiEffectCategory.kisses =>
      dark ? const Color(0xFFFF8AB8) : const Color(0xFFFF7AA8),
    SoloEmojiEffectCategory.celebration =>
      dark ? const Color(0xFFFFD166) : const Color(0xFFFFB703),
    SoloEmojiEffectCategory.general =>
      dark ? AppColors.accent : AppColors.brand,
  };
}

Color soloEmojiParticleColor(
  SoloEmojiEffectCategory category,
  Brightness brightness,
) {
  final glow = soloEmojiGlowColor(category, brightness);
  return glow.withValues(alpha: brightness == Brightness.dark ? 0.92 : 0.85);
}

/// Samples motion at normalized progress [t] in `[0, 1]`.
SoloEmojiMotionFrame sampleSoloEmojiMotion({
  required double t,
  required SoloEmojiEffectCategory category,
}) {
  if (t <= 0) {
    return SoloEmojiMotionFrame(
      scaleX: 1.06,
      scaleY: 0.68,
      rotation: -_categoryTilt(category) * 0.35,
      glowOpacity: 0,
      glowRadiusFactor: 0.35,
      particleStrength: 0,
    );
  }
  if (t >= 1) return SoloEmojiMotionFrame.idle;

  final overshoot = _categoryOvershoot(category);
  final tilt = _categoryTilt(category);

  late double scaleX;
  late double scaleY;
  late double rotation;

  if (t <= 0.34) {
    final p = Curves.easeOutCubic.transform(t / 0.34);
    scaleX = lerpDouble(1.06, 0.86, p)!;
    scaleY = lerpDouble(0.68, 1.26, p)!;
    rotation = lerpDouble(-tilt * 0.35, tilt * 0.55, p)!;
  } else if (t <= 0.54) {
    final p = _easeOutBack((t - 0.34) / 0.20);
    scaleX = lerpDouble(0.86, 1 + overshoot, p)!;
    scaleY = lerpDouble(1.26, 1 + overshoot * 0.55, p)!;
    rotation = lerpDouble(tilt * 0.55, -tilt * 0.25, p)!;
  } else {
    final p = Curves.easeOut.transform((t - 0.54) / 0.46);
    scaleX = lerpDouble(1 + overshoot, 1, p)!;
    scaleY = lerpDouble(1 + overshoot * 0.55, 1, p)!;
    rotation = lerpDouble(-tilt * 0.25, 0, p)!;
  }

  final glowPeak = math.exp(-math.pow((t - 0.24) / 0.22, 2));
  final glowTail =
      (1 - Curves.easeIn.transform(((t - 0.42) / 0.58).clamp(0.0, 1.0)));
  final glowOpacity = (glowPeak * 0.42 * glowTail).clamp(0.0, 0.42);

  final particleStrength = t <= 0.58
      ? (1 - Curves.easeInCubic.transform(t / 0.58)).clamp(0.0, 1.0)
      : 0.0;

  return SoloEmojiMotionFrame(
    scaleX: scaleX,
    scaleY: scaleY,
    rotation: rotation,
    glowOpacity: glowOpacity,
    glowRadiusFactor: lerpDouble(0.35, 0.95, glowPeak)!,
    particleStrength: particleStrength,
  );
}

/// Radial particles for one frame; count is bounded by [soloEmojiParticleCount].
List<SoloEmojiParticleSample> sampleSoloEmojiParticles({
  required double t,
  required SoloEmojiEffectCategory category,
  required int seed,
}) {
  final strength = sampleSoloEmojiMotion(
    t: t,
    category: category,
  ).particleStrength;
  if (strength <= 0.001) return const [];

  final count = soloEmojiParticleCount(category);
  final spread = switch (category) {
    SoloEmojiEffectCategory.celebration => 0.72,
    SoloEmojiEffectCategory.hearts => 0.58,
    SoloEmojiEffectCategory.kisses => 0.52,
    SoloEmojiEffectCategory.general => 0.62,
  };
  final lift = switch (category) {
    SoloEmojiEffectCategory.hearts => -0.08,
    SoloEmojiEffectCategory.kisses => -0.05,
    SoloEmojiEffectCategory.celebration => -0.12,
    SoloEmojiEffectCategory.general => 0,
  };

  final burst = Curves.easeOutCubic.transform((t / 0.34).clamp(0.0, 1.0));
  final samples = <SoloEmojiParticleSample>[];
  for (var i = 0; i < count; i++) {
    final angleSeed = (seed + i * 9973) & 0x7fffffff;
    final angle = (angleSeed % 360) * math.pi / 180;
    final distJitter = 0.78 + ((angleSeed >> 8) % 35) / 100.0;
    final dx = math.cos(angle) * spread * burst * distJitter;
    final dy = math.sin(angle) * spread * burst * distJitter + lift * burst;
    final radius = 1.4 + ((angleSeed >> 4) % 6) * 0.35;
    final opacity = (strength * (0.55 + ((angleSeed >> 12) % 40) / 100.0))
        .clamp(0.0, 1.0);
    if (opacity <= 0.01) continue;
    samples.add(
      SoloEmojiParticleSample(dx: dx, dy: dy, radius: radius, opacity: opacity),
    );
  }
  return samples;
}

/// A single emoji drawn oversized, with a Google-Messages-inspired procedural
/// entrance: squash/stretch launch, overshoot, glow pulse, and radial sparks.
///
/// The static Noto glyph is always used so every Unicode emoji renders; only
/// the surrounding motion varies by category. Tapping replays the effect after
/// the once-per-message entrance has been consumed.
class SoloEmojiBubble extends StatefulWidget {
  const SoloEmojiBubble({
    super.key,
    required this.emoji,
    required this.fontSize,
    required this.playbackKey,
    this.ledger,
  });

  final String emoji;
  final double fontSize;
  final String playbackKey;
  final SoloEmojiPlaybackLedger? ledger;

  static const Duration playDuration = Duration(milliseconds: 680);

  @override
  State<SoloEmojiBubble> createState() => _SoloEmojiBubbleState();
}

class _SoloEmojiBubbleState extends State<SoloEmojiBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: SoloEmojiBubble.playDuration,
    value: 1,
  );

  late final SoloEmojiEffectCategory _category = classifySoloEmojiEffect(
    widget.emoji,
  );
  late final int _seed = soloEmojiEffectSeed(widget.emoji);

  bool _entranceChecked = false;
  bool _decorActive = false;

  bool get _motionAllowed => !MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entranceChecked) return;
    _entranceChecked = true;
    if (!_motionAllowed) return;
    final ledger = widget.ledger ?? soloEmojiLedger;
    if (ledger.markPlayed(widget.playbackKey)) _play();
  }

  void _play() {
    if (!_motionAllowed) return;
    setState(() => _decorActive = true);
    _controller.forward(from: 0).whenComplete(() {
      if (mounted) setState(() => _decorActive = false);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final glowColor = soloEmojiGlowColor(_category, brightness);
    final particleColor = soloEmojiParticleColor(_category, brightness);
    final box = widget.fontSize * 1.22;

    return Semantics(
      button: true,
      label: widget.emoji,
      onTap: _motionAllowed ? _play : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _play,
        child: RepaintBoundary(
          child: SizedBox(
            width: box * 1.55,
            height: box * 1.45,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final frame = _controller.isAnimating || _decorActive
                    ? sampleSoloEmojiMotion(
                        t: _controller.value,
                        category: _category,
                      )
                    : SoloEmojiMotionFrame.idle;
                final particles = frame.particleStrength > 0
                    ? sampleSoloEmojiParticles(
                        t: _controller.value,
                        category: _category,
                        seed: _seed,
                      )
                    : const <SoloEmojiParticleSample>[];

                return Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    if (frame.glowOpacity > 0.01)
                      ExcludeSemantics(
                        child: CustomPaint(
                          size: Size(box * 1.4, box * 1.4),
                          painter: SoloEmojiGlowPainter(
                            color: glowColor,
                            opacity: frame.glowOpacity,
                            radiusFactor: frame.glowRadiusFactor,
                          ),
                        ),
                      ),
                    if (particles.isNotEmpty)
                      ExcludeSemantics(
                        child: CustomPaint(
                          size: Size(box * 1.5, box * 1.5),
                          painter: SoloEmojiParticlePainter(
                            particles: particles,
                            color: particleColor,
                            fontSize: widget.fontSize,
                          ),
                        ),
                      ),
                    Transform(
                      key: const Key('solo-emoji-transform'),
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..rotateZ(frame.rotation)
                        ..scaleByDouble(frame.scaleX, frame.scaleY, 1.0, 1.0),
                      child: child,
                    ),
                  ],
                );
              },
              child: Text(
                widget.emoji,
                style: emojiTextStyle(fontSize: widget.fontSize),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SoloEmojiGlowPainter extends CustomPainter {
  SoloEmojiGlowPainter({
    required this.color,
    required this.opacity,
    required this.radiusFactor,
  });

  final Color color;
  final double opacity;
  final double radiusFactor;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide * 0.5 * radiusFactor;
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          color.withValues(alpha: opacity),
          color.withValues(alpha: opacity * 0.35),
          color.withValues(alpha: 0),
        ],
        stops: const [0, 0.55, 1],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(covariant SoloEmojiGlowPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.opacity != opacity ||
      oldDelegate.radiusFactor != radiusFactor;
}

class SoloEmojiParticlePainter extends CustomPainter {
  SoloEmojiParticlePainter({
    required this.particles,
    required this.color,
    required this.fontSize,
  });

  final List<SoloEmojiParticleSample> particles;
  final Color color;
  final double fontSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (particles.isEmpty) return;
    final center = Offset(size.width / 2, size.height / 2);
    final unit = fontSize * 0.42;
    final paint = Paint()..style = PaintingStyle.fill;
    for (final p in particles) {
      paint.color = color.withValues(alpha: p.opacity.clamp(0, 1));
      canvas.drawCircle(
        center + Offset(p.dx * unit, p.dy * unit),
        p.radius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant SoloEmojiParticlePainter oldDelegate) =>
      oldDelegate.particles != particles ||
      oldDelegate.color != color ||
      oldDelegate.fontSize != fontSize;
}
