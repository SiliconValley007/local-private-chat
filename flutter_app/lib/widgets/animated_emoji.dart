import 'dart:collection';
import 'dart:math' as math;

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

/// Expressive motion family selected from the emoji's first base code point.
enum SoloEmojiEffectCategory { love, flying, sad, general }

SoloEmojiEffectCategory classifySoloEmojiEffect(String emoji) {
  for (final cp in emoji.trim().runes) {
    if (_loveCodePoints.contains(cp)) return SoloEmojiEffectCategory.love;
    if (_flyingCodePoints.contains(cp)) return SoloEmojiEffectCategory.flying;
    if (_sadCodePoints.contains(cp)) return SoloEmojiEffectCategory.sad;
    if (cp == 0xFE0F || cp == 0x200D) continue;
    break;
  }
  return SoloEmojiEffectCategory.general;
}

const _loveCodePoints = {
  0x2764, // heart
  0x1F493,
  0x1F494,
  0x1F495,
  0x1F496,
  0x1F497,
  0x1F498,
  0x1F499,
  0x1F49A,
  0x1F49B,
  0x1F49C,
  0x1F49D,
  0x1F49E,
  0x1F49F,
  0x1F5A4,
  0x1F90D,
  0x1F90E,
  0x1F9E1,
  0x1FA75,
  0x1FA76,
  0x1FA77,
};

const _flyingCodePoints = {
  0x1F98B, // butterfly
  0x1F388, // balloon
  0x1F54A, // dove
};

const _sadCodePoints = {
  0x1F622,
  0x1F625,
  0x1F62D, // loudly crying
  0x1F97A, // pleading
  0x1F641,
  0x2639,
};

/// Normalized entrance stage boundaries (880 ms total).
abstract final class SoloEmojiEntranceStages {
  static const double anticipationEnd = 0.14;
  static const double springEnd = 0.40;
  static const double recoilEnd = 0.58;
  static const double wobbleEnd = 0.76;
  static const double settleEnd = 0.92;
  static const double end = 1.0;
}

/// Every visual property for one frame. A single sampled frame keeps scale,
/// translation, rotation, and alpha synchronized.
class SoloEmojiMotionFrame {
  const SoloEmojiMotionFrame({
    required this.scaleX,
    required this.scaleY,
    required this.translationX,
    required this.translationY,
    required this.rotationDegrees,
    required this.opacity,
  });

  final double scaleX;
  final double scaleY;
  final double translationX;
  final double translationY;
  final double rotationDegrees;
  final double opacity;
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

double _segment(double t, double start, double end) =>
    ((t - start) / (end - start)).clamp(0.0, 1.0);

/// Google Messages' snappy spring curve:
/// `cubic-bezier(0.175, 0.885, 0.32, 1.275)`.
const Curve _popCurve = Cubic(0.175, 0.885, 0.32, 1.275);

/// A staged entrance whose scale, landing, alpha and wobble share one timeline.
SoloEmojiMotionFrame sampleSoloEmojiEntrance({
  required double t,
  required SoloEmojiEffectCategory category,
}) {
  final p = t.clamp(0.0, 1.0);
  double scale;
  double rotation;
  double translationX;

  double translationY;
  double opacity;

  if (p <= SoloEmojiEntranceStages.anticipationEnd) {
    final q = Curves.easeOutCubic.transform(
      _segment(p, 0, SoloEmojiEntranceStages.anticipationEnd),
    );
    scale = _lerp(0.15, 0.38, q);
    translationX = 0;
    translationY = _lerp(16, 10, q);
    rotation = 0;
    opacity = _lerp(0, 0.7, q);
  } else if (p <= SoloEmojiEntranceStages.springEnd) {
    final spring = _popCurve.transform(
      _segment(
        p,
        SoloEmojiEntranceStages.anticipationEnd,
        SoloEmojiEntranceStages.springEnd,
      ),
    );
    scale = _lerp(0.38, 1.30, spring);
    final q = Curves.easeOutCubic.transform(
      _segment(
        p,
        SoloEmojiEntranceStages.anticipationEnd,
        SoloEmojiEntranceStages.springEnd,
      ),
    );
    rotation = category == SoloEmojiEffectCategory.flying
        ? _lerp(-10, 4, q)
        : 0;
    translationX = 2 * math.sin(math.pi * q);
    translationY = _lerp(10, -3, q);
    opacity = _lerp(0.7, 1, q);
  } else if (p <= SoloEmojiEntranceStages.recoilEnd) {
    final q = Curves.easeInOutCubic.transform(
      _segment(
        p,
        SoloEmojiEntranceStages.springEnd,
        SoloEmojiEntranceStages.recoilEnd,
      ),
    );
    scale = _lerp(1.30, 0.97, q);
    rotation = _lerp(0, -7, q);
    translationX = _lerp(0, -2.5, q);
    translationY = _lerp(-3, 1, q);
    opacity = 1;
  } else if (p <= SoloEmojiEntranceStages.wobbleEnd) {
    final q = Curves.easeInOut.transform(
      _segment(
        p,
        SoloEmojiEntranceStages.recoilEnd,
        SoloEmojiEntranceStages.wobbleEnd,
      ),
    );
    scale = _lerp(0.97, 1.035, q);
    rotation = _lerp(-7, 6, q);
    translationX = _lerp(-2.5, 2, q);
    translationY = _lerp(1, -1, q);
    opacity = 1;
  } else if (p <= SoloEmojiEntranceStages.settleEnd) {
    final q = Curves.easeOutCubic.transform(
      _segment(
        p,
        SoloEmojiEntranceStages.wobbleEnd,
        SoloEmojiEntranceStages.settleEnd,
      ),
    );
    scale = _lerp(1.035, 1, q);
    rotation = _lerp(6, 0, q);
    translationX = _lerp(2, 0, q);
    translationY = _lerp(-1, 0, q);
    opacity = 1;
  } else {
    scale = 1;
    rotation = 0;
    translationX = 0;
    translationY = 0;
    opacity = 1;
  }

  var scaleX = scale;
  var scaleY = scale;

  switch (category) {
    case SoloEmojiEffectCategory.love:
      final beat = math.sin(math.pi * _segment(p, 0.38, 0.72));
      scaleX *= 1 + 0.08 * beat;
      scaleY *= 1 + 0.08 * beat;
    case SoloEmojiEffectCategory.flying:
      final lift = math.sin(math.pi * _segment(p, 0.14, 0.74));
      final decay = 1 - _segment(p, 0.65, 1);
      translationY -= 11 * lift;
      translationX += 4 * math.sin(2 * math.pi * p) * decay;
      rotation += 8 * math.sin(3 * math.pi * p) * decay;
    case SoloEmojiEffectCategory.sad:
      final droop = math.sin(math.pi * _segment(p, 0.10, 0.55));
      scaleX *= 1 - 0.05 * droop;
      scaleY *= 1 + 0.16 * droop;
      translationY += 7 * droop;
      if (p > 0.52 && p < 0.88) {
        final decay = 1 - _segment(p, 0.52, 0.88);
        rotation += 2.5 * math.sin(p * math.pi * 6) * decay;
      }
    case SoloEmojiEffectCategory.general:
      break;
  }

  return SoloEmojiMotionFrame(
    scaleX: scaleX,
    scaleY: scaleY,
    translationX: translationX,
    translationY: translationY,
    rotationDegrees: rotation,
    opacity: opacity,
  );
}

double _heartBeat(double t) {
  if (t <= 0.12) return _lerp(1, 1.2, _segment(t, 0, 0.12));
  if (t <= 0.24) return _lerp(1.2, 1.05, _segment(t, 0.12, 0.24));
  if (t <= 0.38) return _lerp(1.05, 1.25, _segment(t, 0.24, 0.38));
  if (t <= 0.58) return _lerp(1.25, 1, _segment(t, 0.38, 0.58));
  return 1 + 0.012 * math.sin(_segment(t, 0.58, 1) * math.pi * 2);
}

/// Repeating ambient keyframes after the entrance has settled.
SoloEmojiMotionFrame sampleSoloEmojiIdle({
  required double t,
  required SoloEmojiEffectCategory category,
}) {
  final p = t.clamp(0.0, 1.0);
  final wave = math.sin(p * math.pi * 2);
  var scaleX = 1 + 0.022 * wave;
  var scaleY = scaleX;
  var translationX = 0.0;
  var translationY = -4 * wave;
  var rotation = 0.0;

  switch (category) {
    case SoloEmojiEffectCategory.love:
      scaleX = _heartBeat(p);
      scaleY = scaleX;
    case SoloEmojiEffectCategory.flying:
      translationY = -5 * wave;
      translationX = 3 * math.sin(p * math.pi * 4);
      rotation = 6 * math.sin(p * math.pi * 4);
      scaleX = 1 + 0.025 * wave;
      scaleY = scaleX;
    case SoloEmojiEffectCategory.sad:
      translationY = 2 + 3 * math.sin(math.pi * p).abs();
      scaleX = 1 - 0.015 * wave.abs();
      scaleY = 1 + 0.04 * wave.abs();
      rotation = 1.5 * math.sin(p * math.pi * 8);
    case SoloEmojiEffectCategory.general:
      break;
  }

  return SoloEmojiMotionFrame(
    scaleX: scaleX,
    scaleY: scaleY,
    translationX: translationX,
    translationY: translationY,
    rotationDegrees: rotation,
    opacity: 1,
  );
}

/// An oversized, bubble-free single emoji with an expressive RCS-style
/// entrance, category motion, and short ambient movement.
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

  static const Duration playDuration = Duration(milliseconds: 880);
  static const Duration idleDuration = Duration(milliseconds: 2400);
  static const int idleCycleCount = 3;

  @override
  State<SoloEmojiBubble> createState() => _SoloEmojiBubbleState();
}

class _SoloEmojiBubbleState extends State<SoloEmojiBubble>
    with TickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: SoloEmojiBubble.playDuration,
    value: 1,
  );
  late final AnimationController _idle = AnimationController(
    vsync: this,
    duration: SoloEmojiBubble.idleDuration,
  );
  late final SoloEmojiEffectCategory _category = classifySoloEmojiEffect(
    widget.emoji,
  );

  bool _entranceChecked = false;

  bool get _motionAllowed => !MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_motionAllowed) {
      _entrance.stop();
      _idle.stop();
      return;
    }
    if (_entranceChecked) {
      if (!_entrance.isAnimating && !_idle.isAnimating) _startIdle();
      return;
    }
    _entranceChecked = true;
    final ledger = widget.ledger ?? soloEmojiLedger;
    if (ledger.markPlayed(widget.playbackKey)) {
      _play();
    } else {
      _startIdle();
    }
  }

  void _play() {
    if (!_motionAllowed) return;
    _idle
      ..stop()
      ..value = 0;
    _entrance.forward(from: 0).then<void>((_) {
      if (mounted && _motionAllowed) _startIdle();
    });
  }

  void _startIdle() {
    if (!_motionAllowed || _idle.isAnimating) return;
    _runIdleCycles(0);
  }

  Future<void> _runIdleCycles(int completed) async {
    if (!mounted || !_motionAllowed) return;
    if (completed >= SoloEmojiBubble.idleCycleCount) {
      _idle.stop();
      return;
    }
    await _idle.forward(from: 0);
    if (!mounted || !_motionAllowed) return;
    await _runIdleCycles(completed + 1);
  }

  @override
  void dispose() {
    _entrance.dispose();
    _idle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = widget.fontSize * 1.7;

    return Semantics(
      button: true,
      label: widget.emoji,
      onTap: _motionAllowed ? _play : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _play,
        child: RepaintBoundary(
          child: SizedBox(
            width: box,
            height: box,
            child: Center(
              child: AnimatedBuilder(
                animation: Listenable.merge([_entrance, _idle]),
                builder: (context, child) {
                  final frame = _entrance.isAnimating || _entrance.value < 1
                      ? sampleSoloEmojiEntrance(
                          t: _entrance.value,
                          category: _category,
                        )
                      : _motionAllowed
                      ? sampleSoloEmojiIdle(t: _idle.value, category: _category)
                      : const SoloEmojiMotionFrame(
                          scaleX: 1,
                          scaleY: 1,
                          translationX: 0,
                          translationY: 0,
                          rotationDegrees: 0,
                          opacity: 1,
                        );
                  return Opacity(
                    opacity: frame.opacity.clamp(0, 1),
                    child: Transform.translate(
                      key: const Key('solo-emoji-translation'),
                      offset: Offset(frame.translationX, frame.translationY),
                      child: Transform(
                        key: const Key('solo-emoji-transform'),
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..rotateZ(frame.rotationDegrees * math.pi / 180)
                          ..scaleByDouble(frame.scaleX, frame.scaleY, 1.0, 1.0),
                        child: child,
                      ),
                    ),
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
      ),
    );
  }
}
