import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../app_state.dart';
import '../errors.dart';
import '../models.dart';
import '../services/media_store.dart';
import '../theme.dart';
import 'attachments.dart';

/// Inline video card: a play button, the file name, and how big it is.
///
/// Nothing is fetched until it is tapped. That is deliberate — a transcript
/// that quietly streamed every clip it scrolled past would burn through a weak
/// or metered connection, which is exactly what this app is trying to avoid.
class VideoAttachment extends StatelessWidget {
  const VideoAttachment({
    super.key,
    required this.message,
    required this.maxWidth,
    this.footer,
    this.onLongPress,
  });

  final ChatMessage message;
  final double maxWidth;

  /// Timestamp and ticks, drawn under the card.
  final Widget? footer;

  /// Long-press opens the unified message action sheet.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final caption = message.body?.trim() ?? '';
    final width = maxWidth < 260.0 ? maxWidth : 260.0;
    final durationMs = message.mediaDurationMs;
    final durationText = durationMs != null && durationMs > 0
        ? formatClipDuration(Duration(milliseconds: durationMs))
        : null;
    final detail = [
      'Video',
      formatFileSize(message.mediaSize),
    ].where((part) => part.isNotEmpty).join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => VideoViewerScreen(message: message),
            ),
          ),
          onLongPress: onLongPress,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.card - 6),
            child: Container(
              width: width,
              height: width * 0.62,
              color: Colors.black.withValues(alpha: 0.82),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Hero(
                      tag: 'media-hero-${message.id}',
                      child: Image.network(
                        context.read<AppState>().api.mediaThumbnailUrl(
                          message.id,
                        ),
                        headers: context.read<AppState>().api.imageAuthHeaders,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.18),
                    ),
                  ),
                  Center(
                    child: Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.92),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        size: 34,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  if (durationText != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          durationText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 8,
                    child: Row(
                      children: [
                        const Icon(
                          Icons.videocam_rounded,
                          size: 15,
                          color: Colors.white70,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            detail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        // The clock and ticks sit on the card itself, exactly as
                        // they do over a photo, so the tile reads as one piece.
                        if (footer != null)
                          IgnorePointer(
                            child: DefaultTextStyle.merge(
                              style: const TextStyle(color: Colors.white),
                              child: IconTheme(
                                data: const IconThemeData(color: Colors.white),
                                child: footer!,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SizedBox(
              width: width,
              child: Text(
                caption,
                style: TextStyle(height: 1.35, color: scheme.onSurface),
              ),
            ),
          ),
      ],
    );
  }
}

/// Full-screen player, with the same save and share actions a photo has.
///
/// Plays the local copy when the clip has already been downloaded, and streams
/// from the server otherwise, so watching something once costs one pass over
/// the network and saving it stays an explicit choice.
class VideoViewerScreen extends StatefulWidget {
  const VideoViewerScreen({
    super.key,
    required this.message,
    this.onShowInChat,
  });

  final ChatMessage message;

  /// Optional "jump back to the chat bubble" action (gallery use).
  final VoidCallback? onShowInChat;

  @override
  State<VideoViewerScreen> createState() => _VideoViewerScreenState();
}

class _VideoViewerScreenState extends State<VideoViewerScreen> {
  VideoPlayerController? _controller;
  String? _failure;

  /// null when idle; 0..1 while a Save download is running.
  double? _saveProgress;
  DateTime? _saveStartedAt;
  bool _showSlowHint = false;
  double _drag = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final state = context.read<AppState>();
    try {
      // A clip already on the phone costs nothing to watch again.
      final local = await state.media.cached(widget.message);
      final controller = local != null
          ? VideoPlayerController.file(File(local.path))
          : VideoPlayerController.networkUrl(
              Uri.parse(state.api.mediaUrl(widget.message.id)),
              httpHeaders: {'Authorization': 'Bearer ${state.api.token}'},
            );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      await controller.setLooping(false);
      await controller.play();
    } catch (error) {
      if (mounted) setState(() => _failure = friendlyMessage(error));
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saveProgress != null) return;
    final state = context.read<AppState>();
    if (!await state.allowVideoDownload()) {
      if (!mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Wi‑Fi only downloads'),
          content: const Text(
            'Video downloads are limited to Wi‑Fi. Continue on this network anyway?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Download'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }
    setState(() {
      _saveProgress = 0;
      _saveStartedAt = DateTime.now();
      _showSlowHint = false;
    });
    final store = state.media;
    try {
      final outcome = await store.saveToDevice(
        widget.message,
        onProgress: (value) {
          if (!mounted) return;
          final started = _saveStartedAt;
          final slow =
              started != null &&
              DateTime.now().difference(started) > const Duration(seconds: 8) &&
              value < 0.15;
          setState(() {
            _saveProgress = value;
            if (slow) _showSlowHint = true;
          });
        },
      );
      if (outcome == SaveOutcome.saved && mounted) {
        _toast('Saved to your phone');
      }
    } on DownloadCancelled {
      // The user asked to stop; no error worth showing.
    } catch (error) {
      if (mounted) _toast(friendlyMessage(error));
    } finally {
      if (mounted) {
        setState(() {
          _saveProgress = null;
          _showSlowHint = false;
        });
      }
    }
  }

  void _cancelSave() {
    context.read<AppState>().media.cancelDownload(widget.message.id);
  }

  Future<void> _share() async {
    final store = context.read<AppState>().media;
    try {
      await store.share(widget.message);
    } catch (error) {
      if (mounted) _toast(friendlyMessage(error));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final opacity = (1.0 - (_drag.abs() / 280)).clamp(0.35, 1.0);

    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: opacity),
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.black,
        title: Text(
          widget.message.mediaName ?? 'Video',
          style: const TextStyle(fontSize: 15, color: Colors.white),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (widget.onShowInChat != null)
            IconButton(
              tooltip: 'Show in chat',
              onPressed: widget.onShowInChat,
              icon: const Icon(Icons.chat_bubble_outline_rounded),
            ),
          if (_saveProgress != null)
            _DownloadingAction(progress: _saveProgress!, onCancel: _cancelSave)
          else
            IconButton(
              tooltip: 'Save to phone',
              onPressed: _save,
              icon: const Icon(Icons.download_rounded),
            ),
          IconButton(
            tooltip: 'Share',
            onPressed: _share,
            icon: const Icon(Icons.share_outlined),
          ),
        ],
      ),
      body: GestureDetector(
        onVerticalDragUpdate: (d) => setState(() => _drag += d.delta.dy),
        onVerticalDragEnd: (d) {
          if (_drag.abs() > 120 ||
              (d.primaryVelocity != null && d.primaryVelocity!.abs() > 700)) {
            Navigator.of(context).maybePop();
          } else {
            setState(() => _drag = 0);
          }
        },
        child: Transform.translate(
          offset: Offset(0, _drag),
          child: Column(
            children: [
              if (_showSlowHint)
                const Material(
                  color: Color(0xCC000000),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      'This download is crawling — Tailscale may be on a relay. '
                      'Same Wi‑Fi or a direct tunnel is much faster.',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                ),
              Expanded(
                child: Center(
                  child: _failure != null
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _failure!,
                            style: const TextStyle(color: Colors.white70),
                            textAlign: TextAlign.center,
                          ),
                        )
                      : controller == null
                      ? const CircularProgressIndicator(color: Colors.white)
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AspectRatio(
                              aspectRatio: controller.value.aspectRatio == 0
                                  ? 16 / 9
                                  : controller.value.aspectRatio,
                              child: GestureDetector(
                                onTap: () => setState(() {
                                  controller.value.isPlaying
                                      ? controller.pause()
                                      : controller.play();
                                }),
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Hero(
                                      tag: 'media-hero-${widget.message.id}',
                                      child: VideoPlayer(controller),
                                    ),
                                    if (!controller.value.isPlaying)
                                      Container(
                                        width: 62,
                                        height: 62,
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: 0.45,
                                          ),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.play_arrow_rounded,
                                          color: Colors.white,
                                          size: 40,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            VideoProgressIndicator(
                              controller,
                              allowScrubbing: true,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Save button while a download runs: a determinate ring with the percent,
/// and tapping it cancels. A brand-new download shows an indeterminate ring
/// until the first bytes arrive.
class _DownloadingAction extends StatelessWidget {
  const _DownloadingAction({required this.progress, required this.onCancel});

  final double progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final percent = (progress * 100).round();
    return TextButton(
      onPressed: onCancel,
      style: TextButton.styleFrom(foregroundColor: Colors.white),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: progress == 0 ? null : progress,
                  color: Colors.white,
                  backgroundColor: Colors.white24,
                ),
              ),
              const Icon(Icons.close_rounded, size: 12, color: Colors.white),
            ],
          ),
          if (progress > 0) ...[
            const SizedBox(width: 6),
            Text(
              '$percent%',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
