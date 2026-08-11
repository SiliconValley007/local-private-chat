import 'package:flutter/material.dart';

import '../models.dart';

/// One-line summary of a quoted message, e.g. "Photo", a filename, or its text.
String quotedSummary(QuotedMessage quote) {
  final text = quote.body?.trim() ?? '';
  switch (quote.type) {
    case 'image':
      return text.isEmpty ? 'Photo' : 'Photo · $text';
    case 'voice':
      return 'Voice message';
    case 'file':
      final name = quote.mediaName?.trim() ?? '';
      return name.isEmpty ? 'File' : name;
    default:
      return text.isEmpty ? 'Message' : text;
  }
}

IconData? quotedIcon(QuotedMessage quote) => switch (quote.type) {
  'image' => Icons.photo_camera_rounded,
  'voice' => Icons.mic_rounded,
  'file' => Icons.insert_drive_file_rounded,
  _ => null,
};

/// The quote block shown inside a reply bubble and above the composer.
class QuotedMessageCard extends StatelessWidget {
  const QuotedMessageCard({
    super.key,
    required this.quote,
    required this.senderName,
    required this.accent,
    this.onTap,
    this.trailing,
  });

  final QuotedMessage quote;
  final String senderName;
  final Color accent;

  /// Tapping jumps to the original message, as in WhatsApp.
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = quotedIcon(quote);

    return Material(
      color: accent.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 4, color: accent),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        senderName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (icon != null) ...[
                            Icon(
                              icon,
                              size: 13,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              quotedSummary(quote),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                height: 1.25,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// Drag a bubble to the right to reply, the way WhatsApp does.
///
/// The row springs back on release: the swipe is a shortcut, never a dismissal.
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({
    super.key,
    required this.child,
    required this.onReply,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onReply;
  final bool enabled;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  static const _triggerAt = 56.0;
  static const _maxDrag = 84.0;

  late final AnimationController _spring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  double _offset = 0;
  bool _fired = false;

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  void _onUpdate(DragUpdateDetails details) {
    if (!widget.enabled) return;
    final next = (_offset + details.delta.dx).clamp(0.0, _maxDrag);
    // Fire once while the finger is still down, like WhatsApp's haptic tick.
    if (!_fired && next >= _triggerAt) {
      _fired = true;
      widget.onReply();
    }
    setState(() => _offset = next);
  }

  void _onEnd(DragEndDetails _) {
    _fired = false;
    if (_offset == 0) return;
    final from = _offset;
    final animation = Tween<double>(begin: from, end: 0).animate(
      CurvedAnimation(parent: _spring, curve: Curves.easeOutCubic),
    );
    void tick() => setState(() => _offset = animation.value);
    animation.addListener(tick);
    _spring.forward(from: 0).whenComplete(() {
      animation.removeListener(tick);
      if (mounted) setState(() => _offset = 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    final progress = (_offset / _triggerAt).clamp(0.0, 1.0);

    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onHorizontalDragUpdate: _onUpdate,
      onHorizontalDragEnd: _onEnd,
      onHorizontalDragCancel: () => _onEnd(DragEndDetails()),
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          if (_offset > 0)
            Opacity(
              opacity: progress,
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.reply_rounded,
                    size: 18,
                    color: scheme.primary,
                  ),
                ),
              ),
            ),
          Transform.translate(
            offset: Offset(_offset, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

/// The bar above the composer showing what you are replying to.
class ReplyDraftBar extends StatelessWidget {
  const ReplyDraftBar({
    super.key,
    required this.quote,
    required this.senderName,
    required this.accent,
    required this.onCancel,
  });

  final QuotedMessage quote;
  final String senderName;
  final Color accent;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      child: QuotedMessageCard(
        quote: quote,
        senderName: senderName,
        accent: accent,
        trailing: IconButton(
          tooltip: 'Cancel reply',
          icon: const Icon(Icons.close_rounded, size: 18),
          onPressed: onCancel,
        ),
      ),
    );
  }
}