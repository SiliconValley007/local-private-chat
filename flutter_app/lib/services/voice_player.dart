import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// What the shared voice-note player is doing right now.
class VoicePlaybackState {
  const VoicePlaybackState({
    this.messageId,
    this.playing = false,
    this.position = Duration.zero,
    this.duration,
  });

  /// Message whose voice note is loaded, or null when nothing is playing.
  final int? messageId;
  final bool playing;
  final Duration position;
  final Duration? duration;

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
  }) {
    return VoicePlaybackState(
      messageId: messageId ?? this.messageId,
      playing: playing ?? this.playing,
      position: position ?? this.position,
      duration: duration ?? this.duration,
    );
  }
}

/// One player for the whole app, so starting a voice note stops the previous
/// one instead of layering two recordings on top of each other.
class VoicePlayer extends ValueNotifier<VoicePlaybackState> {
  VoicePlayer._() : super(const VoicePlaybackState()) {
    _player.onDurationChanged.listen((d) {
      value = value.copyWith(duration: d);
    });
    _player.onPositionChanged.listen((p) {
      value = value.copyWith(position: p);
    });
    _player.onPlayerComplete.listen((_) {
      value = const VoicePlaybackState();
    });
  }

  static final VoicePlayer instance = VoicePlayer._();

  final AudioPlayer _player = AudioPlayer();

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
    value = VoicePlaybackState(messageId: messageId, playing: true);
    await _player.play(DeviceFileSource(path));
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
    value = const VoicePlaybackState();
  }
}
