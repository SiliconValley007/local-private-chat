import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/media_store.dart';

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
    const maxHeight = 360.0;

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
                    maxHeight: maxHeight,
                    minHeight: 120,
                  ),
                  child: Image.network(
                    state.api.mediaUrl(widget.message.id),
                    key: ValueKey(_reloadKey),
                    headers: {'Authorization': 'Bearer ${state.api.token}'},
                    fit: BoxFit.contain,
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) return child;
                      final expected = progress.expectedTotalBytes;
                      return _DoodlePlaceholder(
                        width: width,
                        progress: expected == null
                            ? null
                            : progress.cumulativeBytesLoaded / expected,
                      );
                    },
                    errorBuilder: (context, _, _) => _DoodleFailed(
                      width: width,
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
  const _DoodlePlaceholder({required this.width, this.progress});

  final double width;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      height: 160,
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
  const _DoodleFailed({required this.width, required this.onRetry});

  final double width;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onRetry,
      child: SizedBox(
        width: width,
        height: 160,
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
              child: Image.network(
                state.api.mediaUrl(message.id),
                headers: {'Authorization': 'Bearer ${state.api.token}'},
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
