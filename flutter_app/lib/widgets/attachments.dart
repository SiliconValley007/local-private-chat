import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../e2e_text.dart';
import '../errors.dart';
import '../models.dart';
import '../services/media_store.dart';
import '../services/voice_player.dart';
import '../theme.dart';
import 'media_shape.dart';

/// "1.4 MB" — short enough to sit under a file name.
String formatFileSize(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final rounded = size >= 10 || unit == 0
      ? size.toStringAsFixed(0)
      : size.toStringAsFixed(1);
  return '$rounded ${units[unit]}';
}

String formatClipDuration(Duration? value) {
  if (value == null) return '--:--';
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// Text under a voice note's waveform.
///
/// A clip that is loaded reads as a clock, and one that has been played before
/// keeps its length even while idle rather than falling back to a bare label.
String voiceClipLabel({
  required bool loaded,
  Duration? elapsed,
  Duration? total,
}) {
  if (loaded) {
    return '${formatClipDuration(elapsed)} / ${formatClipDuration(total)}';
  }
  return total == null ? 'Voice message' : formatClipDuration(total);
}

String formatPlaybackSpeed(double speed) => speed == 1.0
    ? '1×'
    : speed == 1.5
    ? '1.5×'
    : '2×';

String fileExtensionOf(ChatMessage msg) {
  final name = msg.mediaName ?? '';
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toUpperCase();
}

/// Colour + glyph per file family, so a PDF never looks like a zip.
({IconData icon, Color color}) fileBadge(ChatMessage msg) {
  final ext = fileExtensionOf(msg).toLowerCase();
  final mime = (msg.mediaMime ?? '').toLowerCase();

  if (mime.startsWith('image/') ||
      ['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic'].contains(ext)) {
    return (icon: Icons.image_outlined, color: const Color(0xFF7C3AED));
  }
  if (mime.startsWith('video/') ||
      ['mp4', 'mkv', 'mov', 'avi', 'webm'].contains(ext)) {
    return (icon: Icons.movie_outlined, color: const Color(0xFFDB2777));
  }
  if (mime.startsWith('audio/') ||
      ['mp3', 'm4a', 'wav', 'ogg', 'aac'].contains(ext)) {
    return (icon: Icons.audiotrack_outlined, color: const Color(0xFF0891B2));
  }
  if (ext == 'pdf') {
    return (
      icon: Icons.picture_as_pdf_outlined,
      color: const Color(0xFFDC2626),
    );
  }
  if (['doc', 'docx', 'rtf', 'txt', 'md'].contains(ext)) {
    return (icon: Icons.description_outlined, color: const Color(0xFF2563EB));
  }
  if (['xls', 'xlsx', 'csv'].contains(ext)) {
    return (icon: Icons.table_chart_outlined, color: const Color(0xFF16A34A));
  }
  if (['ppt', 'pptx'].contains(ext)) {
    return (icon: Icons.slideshow_outlined, color: const Color(0xFFEA580C));
  }
  if (['zip', 'rar', '7z', 'tar', 'gz', 'apk'].contains(ext)) {
    return (icon: Icons.folder_zip_outlined, color: const Color(0xFFCA8A04));
  }
  return (
    icon: Icons.insert_drive_file_outlined,
    color: const Color(0xFF475569),
  );
}

void _report(BuildContext context, Object error) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(friendlyMessage(error))));
}

void _toast(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// Tracks one download so the widget can show a progress ring.
mixin _DownloadState<T extends StatefulWidget> on State<T> {
  double? downloadProgress;

  bool get downloading => downloadProgress != null;

  Future<void> runDownload(
    Future<void> Function(void Function(double) onProgress) job,
  ) async {
    if (downloading) return;
    setState(() => downloadProgress = 0);
    try {
      await job((value) {
        if (mounted) setState(() => downloadProgress = value);
      });
    } catch (error) {
      if (mounted) _report(context, error);
    } finally {
      if (mounted) setState(() => downloadProgress = null);
    }
  }
}

/// Open / save / share actions for attachment messages.
enum AttachmentAction { open, save, share }

bool messageHasAttachmentActions(ChatMessage msg) =>
    !msg.isDeleted &&
    (msg.type == 'image' ||
        msg.type == 'video' ||
        msg.type == 'doodle' ||
        msg.type == 'voice' ||
        msg.type == 'file');

Future<void> runAttachmentAction(
  BuildContext context,
  ChatMessage msg,
  AttachmentAction action,
) async {
  final store = context.read<AppState>().media;
  final cached = await store.cached(msg);
  if (cached == null && context.mounted) {
    _toast(context, 'Downloading ${msg.mediaName ?? 'attachment'}…');
  }

  try {
    switch (action) {
      case AttachmentAction.open:
        await store.openExternally(msg);
      case AttachmentAction.save:
        final outcome = await store.saveToDevice(msg);
        if (outcome == SaveOutcome.saved && context.mounted) {
          _toast(context, 'Saved to your phone');
        }
      case AttachmentAction.share:
        await store.share(msg);
    }
  } catch (error) {
    if (context.mounted) _report(context, error);
  }
}

/// Open / save / share, the way a long-press on a WhatsApp attachment behaves.
Future<void> showAttachmentActions(
  BuildContext context,
  ChatMessage msg,
) async {
  final scheme = Theme.of(context).colorScheme;
  final badge = fileBadge(msg);

  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: [
                _FileGlyph(badge: badge, size: 42),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        msg.mediaName ?? 'Attachment',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(sheetContext).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        [
                          fileExtensionOf(msg),
                          formatFileSize(msg.mediaSize),
                        ].where((part) => part.isNotEmpty).join(' · '),
                        style: Theme.of(sheetContext).textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 16),
          ListTile(
            leading: const Icon(Icons.open_in_new_rounded),
            title: const Text('Open'),
            onTap: () => Navigator.pop(sheetContext, 'open'),
          ),
          ListTile(
            leading: const Icon(Icons.download_rounded),
            title: const Text('Save to phone'),
            subtitle: const Text('Choose where to keep this file'),
            onTap: () => Navigator.pop(sheetContext, 'save'),
          ),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: const Text('Share'),
            onTap: () => Navigator.pop(sheetContext, 'share'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  if (action == null || !context.mounted) return;
  await runAttachmentAction(context, msg, switch (action) {
    'open' => AttachmentAction.open,
    'save' => AttachmentAction.save,
    _ => AttachmentAction.share,
  });
}

class _FileGlyph extends StatelessWidget {
  const _FileGlyph({required this.badge, this.size = 46});

  final ({IconData icon, Color color}) badge;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: badge.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(badge.icon, color: badge.color, size: size * 0.5),
    );
  }
}

/// Inline photo preview. Loads straight from the server with the session token,
/// so the thumbnail appears without waiting for a manual download.
class ImageAttachment extends StatefulWidget {
  const ImageAttachment({
    super.key,
    required this.message,
    required this.maxWidth,
    this.footer,
    this.onLongPress,
  });

  final ChatMessage message;
  final double maxWidth;

  /// Timestamp and ticks, drawn over the bottom of the photo.
  final Widget? footer;

  /// Long-press opens the unified message action sheet.
  final VoidCallback? onLongPress;

  @override
  State<ImageAttachment> createState() => _ImageAttachmentState();
}

class _ImageAttachmentState extends State<ImageAttachment> {
  int _reloadKey = 0;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final caption = readableBody(widget.message.body)?.trim() ?? '';
    final width = math.min(widget.maxWidth, 260.0);
    // Decoded to the width of the bubble rather than the camera's full
    // resolution — a 12 MP photo in a 260 px bubble is waste. Height is left to
    // follow, because pinning both would resize the picture to a shape it never
    // had and a screenshot would arrive squashed.
    final image = ResizeImage(
      CachedNetworkImageProvider(
        state.api.mediaThumbnailUrl(widget.message.id),
        headers: state.api.imageAuthHeaders,
      ),
      width: (width * MediaQuery.devicePixelRatioOf(context)).round(),
      policy: ResizeImagePolicy.fit,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.card - 6),
          child: MediaShape(
            key: ValueKey(_reloadKey),
            messageId: widget.message.id,
            image: image,
            width: width,
            source: widget.message.mediaShape,
            builder: (context, box, alignment) => Stack(
              children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          ImageViewerScreen(message: widget.message),
                    ),
                  ),
                  onLongPress: widget.onLongPress,
                  child: Hero(
                    tag: 'media-hero-${widget.message.id}',
                    child: SizedBox.fromSize(
                      size: box,
                      child: Image(
                        image: image,
                        width: box.width,
                        height: box.height,
                        fit: BoxFit.cover,
                        alignment: alignment,
                        loadingBuilder: (context, child, progress) {
                          if (progress == null) return child;
                          final expected = progress.expectedTotalBytes;
                          return _ImagePlaceholder(
                            box: box,
                            progress: expected == null
                                ? null
                                : progress.cumulativeBytesLoaded / expected,
                          );
                        },
                        errorBuilder: (context, _, _) => _ImageFailed(
                          box: box,
                          onRetry: () => setState(() => _reloadKey++),
                        ),
                      ),
                    ),
                  ),
                ),
                if (widget.footer != null)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    left: 0,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(10, 18, 8, 6),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Color(0x66000000)],
                          ),
                        ),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: DefaultTextStyle.merge(
                            style: const TextStyle(color: Colors.white),
                            child: IconTheme(
                              data: const IconThemeData(color: Colors.white),
                              child: widget.footer!,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SizedBox(
              width: width,
              child: Text(caption, style: const TextStyle(height: 1.35)),
            ),
          ),
      ],
    );
  }
}

class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({required this.box, this.progress});

  final Size box;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: box.width,
      height: box.height,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: SizedBox(
        width: 30,
        height: 30,
        child: CircularProgressIndicator(strokeWidth: 2.4, value: progress),
      ),
    );
  }
}

class _ImageFailed extends StatelessWidget {
  const _ImageFailed({required this.box, required this.onRetry});

  final Size box;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onRetry,
      child: Container(
        width: box.width,
        height: box.height,
        color: scheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.image_not_supported_outlined, color: scheme.outline),
            const SizedBox(height: 6),
            Text(
              'Tap to retry',
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen photo with save and share, like tapping a photo in WhatsApp.
class ImageViewerScreen extends StatefulWidget {
  const ImageViewerScreen({
    super.key,
    required this.message,
    this.onShowInChat,
  });

  final ChatMessage message;

  /// Optional "jump back to the chat bubble" action (gallery use).
  final VoidCallback? onShowInChat;

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  final _transform = TransformationController();
  TapDownDetails? _doubleTap;

  ChatMessage get message => widget.message;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _onDoubleTap() {
    if (_transform.value.getMaxScaleOnAxis() > 1.01) {
      _transform.value = Matrix4.identity();
      return;
    }
    final position = _doubleTap?.localPosition ?? Offset.zero;
    _transform.value = Matrix4.identity()
      ..translateByDouble(-position.dx * 1.5, -position.dy * 1.5, 0, 1)
      ..scaleByDouble(2.5, 2.5, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final caption = readableBody(message.body)?.trim() ?? '';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.black,
        title: Text(
          message.mediaName ?? 'Photo',
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
          IconButton(
            tooltip: 'Save to phone',
            onPressed: () => _save(context),
            icon: const Icon(Icons.download_rounded),
          ),
          IconButton(
            tooltip: 'Share',
            onPressed: () => _share(context),
            icon: const Icon(Icons.share_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTapDown: (details) => _doubleTap = details,
              onDoubleTap: _onDoubleTap,
              child: InteractiveViewer(
                transformationController: _transform,
                minScale: 1,
                maxScale: 5,
                panEnabled: true,
                scaleEnabled: true,
                boundaryMargin: const EdgeInsets.all(80),
                child: Center(
                  child: Hero(
                    tag: 'media-hero-${message.id}',
                    child: Image(
                      image: CachedNetworkImageProvider(
                        state.api.mediaUrl(message.id),
                        headers: state.api.imageAuthHeaders,
                      ),
                      errorBuilder: (context, _, _) => const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          "This photo couldn't be loaded from the server.",
                          style: TextStyle(color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Text(
                caption,
                style: const TextStyle(color: Colors.white, height: 1.4),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context) async {
    final store = context.read<AppState>().media;
    try {
      final outcome = await store.saveToDevice(message);
      if (outcome == SaveOutcome.saved && context.mounted) {
        _toast(context, 'Saved to your phone');
      }
    } catch (error) {
      if (context.mounted) _report(context, error);
    }
  }

  Future<void> _share(BuildContext context) async {
    final store = context.read<AppState>().media;
    try {
      await store.share(message);
    } catch (error) {
      if (context.mounted) _report(context, error);
    }
  }
}

/// File card: icon, name, size, and a button that downloads then opens.
class FileAttachment extends StatefulWidget {
  const FileAttachment({
    super.key,
    required this.message,
    required this.maxWidth,
    this.onSurfaceColor,
    this.onLongPress,
  });

  final ChatMessage message;
  final double maxWidth;
  final Color? onSurfaceColor;
  final VoidCallback? onLongPress;

  @override
  State<FileAttachment> createState() => _FileAttachmentState();
}

class _FileAttachmentState extends State<FileAttachment>
    with _DownloadState<FileAttachment> {
  bool _cached = false;

  @override
  void initState() {
    super.initState();
    _refreshCached();
  }

  Future<void> _refreshCached() async {
    final file = await context.read<AppState>().media.cached(widget.message);
    if (mounted) setState(() => _cached = file != null);
  }

  Future<void> _openOrDownload() async {
    final store = context.read<AppState>().media;
    await runDownload((onProgress) async {
      await store.ensureLocal(widget.message, onProgress: onProgress);
      if (mounted) setState(() => _cached = true);
      await store.openExternally(widget.message);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final badge = fileBadge(widget.message);
    final subtitle = [
      fileExtensionOf(widget.message),
      formatFileSize(widget.message.mediaSize),
    ].where((part) => part.isNotEmpty).join(' · ');

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: math.min(widget.maxWidth, 268)),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.field),
        onTap: _openOrDownload,
        onLongPress: widget.onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              _FileGlyph(badge: badge),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.message.mediaName ?? 'File',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: widget.onSurfaceColor,
                        height: 1.25,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              _RoundActionButton(
                progress: downloadProgress,
                icon: _cached
                    ? Icons.open_in_new_rounded
                    : Icons.download_rounded,
                onPressed: _openOrDownload,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Voice note with a play button and a scrubbable progress bar.
class VoiceAttachment extends StatefulWidget {
  const VoiceAttachment({
    super.key,
    required this.message,
    required this.accent,
    this.onLongPress,
  });

  final ChatMessage message;
  final Color accent;
  final VoidCallback? onLongPress;

  @override
  State<VoiceAttachment> createState() => _VoiceAttachmentState();
}

class _VoiceAttachmentState extends State<VoiceAttachment>
    with _DownloadState<VoiceAttachment> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _loadCached();
  }

  Future<void> _loadCached() async {
    final file = await context.read<AppState>().media.cached(widget.message);
    if (mounted && file != null) setState(() => _file = file);
  }

  Future<void> _toggle() async {
    final store = context.read<AppState>().media;
    var file = _file;
    if (file == null) {
      await runDownload((onProgress) async {
        file = await store.ensureLocal(widget.message, onProgress: onProgress);
      });
      if (file == null || !mounted) return;
      setState(() => _file = file);
    }
    await VoicePlayer.instance.toggle(widget.message.id, file!.path);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VoicePlaybackState>(
      valueListenable: VoicePlayer.instance,
      builder: (context, playback, _) {
        final mine = playback.isFor(widget.message.id);
        final playing = mine && playback.playing;
        final progress = playback.progressFor(widget.message.id);
        final elapsed = mine ? playback.position : null;
        final clipLength = VoicePlayer.instance.lengthOf(widget.message.id);
        final label = voiceClipLabel(
          loaded: mine,
          elapsed: elapsed,
          total: playback.duration ?? clipLength,
        );

        return GestureDetector(
          onLongPress: widget.onLongPress,
          child: SizedBox(
            width: 214,
            child: Row(
              children: [
                _RoundActionButton(
                  progress: downloadProgress,
                  icon: playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  filled: true,
                  color: widget.accent,
                  onPressed: _toggle,
                  onLongPress: widget.onLongPress,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) => GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (details) => VoicePlayer.instance.seekTo(
                            widget.message.id,
                            details.localPosition.dx / constraints.maxWidth,
                          ),
                          child: SizedBox(
                            height: 28,
                            child: CustomPaint(
                              painter: _WaveformPainter(
                                progress: progress,
                                color: widget.accent,
                                seed: widget.message.id,
                              ),
                              size: Size(constraints.maxWidth, 28),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              label,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ),
                          Tooltip(
                            message: 'Tap to change playback speed',
                            child: Semantics(
                              button: true,
                              label:
                                  'Playback speed ${playback.speed} times. Tap to change.',
                              child: InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () => VoicePlayer.instance.cycleSpeed(),
                                child: Container(
                                  key: const Key('voice-speed-control'),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: widget.accent.withValues(
                                      alpha: 0.12,
                                    ),
                                    border: Border.all(
                                      color: widget.accent.withValues(
                                        alpha: 0.45,
                                      ),
                                    ),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    formatPlaybackSpeed(playback.speed),
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: widget.accent,
                                          fontWeight: FontWeight.w800,
                                        ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Circular button that turns into a progress ring while downloading.
class _RoundActionButton extends StatelessWidget {
  const _RoundActionButton({
    required this.icon,
    required this.onPressed,
    this.onLongPress,
    this.progress,
    this.filled = false,
    this.color,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final double? progress;
  final bool filled;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = color ?? scheme.primary;
    final busy = progress != null;

    return SizedBox(
      width: 38,
      height: 38,
      child: Material(
        color: filled ? accent : accent.withValues(alpha: 0.10),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : onPressed,
          onLongPress: onLongPress,
          child: Center(
            child: busy
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      value: progress == 0 ? null : progress,
                      color: filled ? scheme.onPrimary : accent,
                    ),
                  )
                : Icon(
                    icon,
                    size: 20,
                    color: filled ? scheme.onPrimary : accent,
                  ),
          ),
        ),
      ),
    );
  }
}

/// Deterministic fake waveform so every voice note looks distinct without
/// decoding PCM on the UI thread.
class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.progress,
    required this.color,
    required this.seed,
  });

  final double progress;
  final Color color;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    const bars = 28;
    final gap = size.width / bars;
    final played = Paint()..color = color;
    final rest = Paint()..color = color.withValues(alpha: 0.28);
    for (var i = 0; i < bars; i++) {
      final t = ((seed * 37 + i * 17) % 100) / 100.0;
      final h = 4.0 + t * (size.height - 4);
      final x = i * gap + gap * 0.2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, (size.height - h) / 2, gap * 0.55, h),
        const Radius.circular(2),
      );
      canvas.drawRRect(rect, i / bars <= progress ? played : rest);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) =>
      old.progress != progress || old.color != color || old.seed != seed;
}
