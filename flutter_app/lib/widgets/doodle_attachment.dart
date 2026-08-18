import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/media_store.dart';

/// Tallest and shortest a drawing may be drawn in a chat row.
const double doodleMaxHeight = 360;
const double doodleMinHeight = 120;

/// Height a drawing of pixel size [source] will settle at in a [width] row.
///
/// Null while the size is unknown, which is the only case where the row has to
/// guess and then correct itself once the drawing arrives.
double? doodlePreviewHeight({required double width, Size? source}) {
  if (source == null || source.width <= 0 || source.height <= 0) return null;
  final height = width * source.height / source.width;
  return height.clamp(doodleMinHeight, doodleMaxHeight);
}

/// Bubble-free persistent doodle: transparent PNG with [BoxFit.contain].
class DoodleAttachment extends StatefulWidget {
  const DoodleAttachment({
    super.key,
    required this.message,
    required this.maxWidth,
    this.footer,
    this.onLongPress,
  });

  final ChatMessage message;
  final double maxWidth;
  final Widget? footer;
  final VoidCallback? onLongPress;

  @override
  State<DoodleAttachment> createState() => _DoodleAttachmentState();
}

class _DoodleAttachmentState extends State<DoodleAttachment> {
  int _reloadKey = 0;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final width = math.min(widget.maxWidth, 280.0);
    // Reserving the settled height keeps the row still: without it a drawing
    // scrolling into view grew out of the placeholder and pushed the chat along
    // with it.
    final settled = doodlePreviewHeight(
      width: width,
      source: widget.message.mediaShape,
    );
    final image = ResizeImage(
      CachedNetworkImageProvider(
        state.api.mediaUrl(widget.message.id),
        headers: state.api.imageAuthHeaders,
      ),
      width: (width * MediaQuery.devicePixelRatioOf(context)).round(),
      policy: ResizeImagePolicy.fit,
    );

    return Semantics(
      label: 'Drawing',
      image: true,
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DoodleViewerScreen(message: widget.message),
          ),
        ),
        onLongPress: widget.onLongPress,
        child: SizedBox(
          width: width,
          child: Stack(
            children: [
              Hero(
                tag: 'media-hero-${widget.message.id}',
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: width,
                    maxHeight: doodleMaxHeight,
                    minHeight: settled ?? doodleMinHeight,
                  ),
                  child: Image(
                    image: image,
                    key: ValueKey(_reloadKey),
                    fit: BoxFit.contain,
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) return child;
                      final expected = progress.expectedTotalBytes;
                      return _DoodlePlaceholder(
                        width: width,
                        height: settled,
                        progress: expected == null
                            ? null
                            : progress.cumulativeBytesLoaded / expected,
                      );
                    },
                    errorBuilder: (context, _, _) => _DoodleFailed(
                      width: width,
                      height: settled,
                      onRetry: () => setState(() => _reloadKey++),
                    ),
                  ),
                ),
              ),
              if (widget.footer != null)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(
                      color: Colors.white,
                      shadows: [
                        Shadow(color: Color(0x99000000), blurRadius: 4),
                      ],
                    ),
                    child: IconTheme(
                      data: const IconThemeData(color: Colors.white),
                      child: widget.footer!,
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

class _DoodlePlaceholder extends StatelessWidget {
  const _DoodlePlaceholder({required this.width, this.height, this.progress});

  final double width;

  /// Height the finished drawing will take, when it is already known.
  final double? height;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      height: height ?? 160,
      child: ColoredBox(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.4, value: progress),
          ),
        ),
      ),
    );
  }
}

class _DoodleFailed extends StatelessWidget {
  const _DoodleFailed({
    required this.width,
    required this.onRetry,
    this.height,
  });

  final double width;
  final double? height;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onRetry,
      child: SizedBox(
        width: width,
        height: height ?? 160,
        child: ColoredBox(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.draw_outlined, color: scheme.outline),
              const SizedBox(height: 6),
              Text(
                'Tap to retry',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-screen doodle viewer with save/share like photos.
class DoodleViewerScreen extends StatelessWidget {
  const DoodleViewerScreen({
    super.key,
    required this.message,
    this.onShowInChat,
  });

  final ChatMessage message;
  final VoidCallback? onShowInChat;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        title: const Text('Drawing', style: TextStyle(fontSize: 15)),
        actions: [
          if (onShowInChat != null)
            IconButton(
              tooltip: 'Show in chat',
              onPressed: onShowInChat,
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
      body: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
        ),
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: Center(
            child: Hero(
              tag: 'media-hero-${message.id}',
              child: Image(
                image: CachedNetworkImageProvider(
                  state.api.mediaUrl(message.id),
                  headers: state.api.imageAuthHeaders,
                ),
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _save(BuildContext context) async {
    final store = context.read<AppState>().media;
    try {
      final outcome = await store.saveToDevice(message);
      if (outcome == SaveOutcome.saved && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Saved to your phone')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _share(BuildContext context) async {
    final store = context.read<AppState>().media;
    try {
      await store.share(message);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }
}
