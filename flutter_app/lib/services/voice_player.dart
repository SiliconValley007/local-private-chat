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

/// Clip lengths already learnt, keyed by message.
///
/// Android announces a duration when a file is *prepared*, and preparing the
/// same file a second time announces nothing: replaying a voice note used to
/// leave the length unknown, which showed as `0:01 / --:--` with a progress bar
/// that never filled even though the audio was playing. Remembering the length
/// makes every replay behave like the first.
class VoiceClipLengths {
  VoiceClipLengths({this.limit = 200});

  /// Bounded, so a long scroll through a chat full of voice notes cannot grow
  /// this without end.
  final int limit;

  final Map<int, Duration> _lengths = {};

  Duration? of(int messageId) => _lengths[messageId];

  int get count => _lengths.length;

  void remember(int messageId, Duration length) {
    if (length <= Duration.zero) return;
    if (_lengths.length >= limit && !_lengths.containsKey(messageId)) {
      _lengths.remove(_lengths.keys.first);
    }
    _lengths[messageId] = length;
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
      final id = value.messageId;
      if (id == null || d <= Duration.zero) return;
      _lengths.remember(id, d);
      value = value.copyWith(duration: d);
    });
    _player.onPositionChanged.listen((p) {
      if (value.messageId == null) return;
      value = value.copyWith(position: p);
    });
    _player.onPlayerComplete.listen((_) {
      value = VoicePlaybackState(speed: value.speed);
    });
  }

  static final VoicePlayer instance = VoicePlayer._();

  final AudioPlayer _player = AudioPlayer();

  final VoiceClipLengths _lengths = VoiceClipLengths();

  /// Bumped on every new clip so a slow duration lookup cannot land on the
  /// clip that replaced it.
  int _session = 0;

  static const speeds = <double>[1.0, 1.5, 2.0];

  /// Length of [messageId]'s clip if it is already known.
  Duration? lengthOf(int messageId) => _lengths.of(messageId);

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
    final session = ++_session;
    value = VoicePlaybackState(
      messageId: messageId,
      playing: true,
      duration: _lengths.of(messageId),
      speed: value.speed,
    );
    await _player.setPlaybackRate(value.speed);
    await _player.play(DeviceFileSource(path));
    if (session != _session) return;
    // Asked for outright rather than waited for: the duration stream stays
    // silent when a file is prepared a second time.
    final measured = await _player.getDuration();
    if (session != _session || measured == null || measured <= Duration.zero) {
      return;
    }
    _lengths.remember(messageId, measured);
    if (value.isFor(messageId)) value = value.copyWith(duration: measured);
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
