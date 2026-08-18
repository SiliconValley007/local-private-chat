import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// What the shared voice-note player is doing right now.
class VoicePlaybackState {
  const VoicePlaybackState({
    this.messageId,
    this.playing = false,
    this.position = Duration.zero,
    this.duration,
    this.speed = 1.0,
  });

  /// Message whose voice note is loaded, or null when nothing is playing.
  final int? messageId;
  final bool playing;
  final Duration position;
  final Duration? duration;
  final double speed;

  bool isFor(int id) => messageId == id;

  double progressFor(int id) {
    final total = duration?.inMilliseconds ?? 0;
    if (!isFor(id) || total <= 0) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  VoicePlaybackState copyWith({
    int? messageId,
    bool? playing,
    Duration? position,
    Duration? duration,
    double? speed,
  }) {
    return VoicePlaybackState(
      messageId: messageId ?? this.messageId,
      playing: playing ?? this.playing,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      speed: speed ?? this.speed,
    );
  }
}

/// One player for the whole app, so starting a voice note stops the previous
/// one instead of layering two recordings on top of each other.
class VoicePlayer extends ValueNotifier<VoicePlaybackState> {
  VoicePlayer._() : super(const VoicePlaybackState()) {
    // stayAwake keeps the clip going when the screen turns off.
    unawaited(
      _player.setReleaseMode(ReleaseMode.stop).then((_) {
        return _player.setAudioContext(
          AudioContext(
            android: const AudioContextAndroid(
              isSpeakerphoneOn: false,
              stayAwake: true,
              contentType: AndroidContentType.speech,
              usageType: AndroidUsageType.media,
              audioFocus: AndroidAudioFocus.gain,
            ),
          ),
        );
      }),
    );
    _player.onDurationChanged.listen((d) {
      value = value.copyWith(duration: d);
    });
    _player.onPositionChanged.listen((p) {
      value = value.copyWith(position: p);
    });
    _player.onPlayerComplete.listen((_) {
      value = VoicePlaybackState(speed: value.speed);
    });
  }

  static final VoicePlayer instance = VoicePlayer._();

  final AudioPlayer _player = AudioPlayer();

  static const speeds = <double>[1.0, 1.5, 2.0];

  /// Plays [path] for [messageId], pausing/resuming when it is already loaded.
  Future<void> toggle(int messageId, String path) async {
    if (value.isFor(messageId)) {
      if (value.playing) {
        await _player.pause();
        value = value.copyWith(playing: false);
      } else {
        await _player.resume();
        value = value.copyWith(playing: true);
      }
      return;
    }
    await _player.stop();
    value = VoicePlaybackState(
      messageId: messageId,
      playing: true,
      speed: value.speed,
    );
    await _player.setPlaybackRate(value.speed);
    await _player.play(DeviceFileSource(path));
  }

  Future<void> cycleSpeed() async {
    final idx = speeds.indexOf(value.speed);
    final next = speeds[(idx < 0 ? 0 : idx + 1) % speeds.length];
    await _player.setPlaybackRate(next);
    value = value.copyWith(speed: next);
  }

  Future<void> seekTo(int messageId, double fraction) async {
    final total = value.duration;
    if (!value.isFor(messageId) || total == null) return;
    final target = Duration(
      milliseconds: (total.inMilliseconds * fraction.clamp(0.0, 1.0)).round(),
    );
    await _player.seek(target);
    value = value.copyWith(position: target);
  }

  Future<void> stop() async {
    await _player.stop();
    value = VoicePlaybackState(speed: value.speed);
  }
}
