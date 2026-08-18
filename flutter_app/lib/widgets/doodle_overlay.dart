import 'package:flutter/material.dart';

import '../doodle_stroke.dart';
import '../services/doodle_controller.dart';
import '../services/doodle_export.dart';
import '../theme.dart';

/// Interactive transparent drawing layer above the chat transcript.
class DoodleOverlay extends StatefulWidget {
  const DoodleOverlay({
    super.key,
    required this.draw,
    required this.incoming,
    required this.relayAvailable,
    required this.onCancel,
    required this.onSend,
    required this.onClose,
    this.sending = false,
    this.onCanvasSize,
  });

  final DoodleDrawController draw;
  final DoodleIncomingController incoming;
  final bool relayAvailable;
  final VoidCallback onCancel;
  final Future<void> Function() onSend;
  final VoidCallback onClose;
  final bool sending;
  final ValueChanged<Size>? onCanvasSize;

  @override
  State<DoodleOverlay> createState() => _DoodleOverlayState();
}

class _DoodleOverlayState extends State<DoodleOverlay> {
  @override
  void initState() {
    super.initState();
    widget.incoming.addListener(_repaint);
  }

  @override
  void didUpdateWidget(DoodleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.incoming != widget.incoming) {
      oldWidget.incoming.removeListener(_repaint);
      widget.incoming.addListener(_repaint);
    }
  }

  @override
  void dispose() {
    widget.incoming.removeListener(_repaint);
    super.dispose();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  void _normalize(
    Offset local,
    Size size,
    void Function(double x, double y) fn,
  ) {
    if (size.width <= 0 || size.height <= 0) return;
    final nx = (local.dx / size.width).clamp(0.0, 1.0);
    final ny = (local.dy / size.height).clamp(0.0, 1.0);
    fn(nx, ny);
  }

  @override
  Widget build(BuildContext context) {
    final available = widget.relayAvailable;
    final session = widget.draw.session;
    return Semantics(
      label: available
          ? 'Doodle drawing mode'
          : 'Doodle unavailable, reconnecting',
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.incoming.hasLive)
              IgnorePointer(
                child: CustomPaint(
                  painter: DoodlePainter(
                    strokes: widget.incoming.live!.visibleStrokes(),
                  ),
                ),
              ),
            if (available)
              LayoutBuilder(
                builder: (context, constraints) {
                  final size = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
                  widget.onCanvasSize?.call(size);
                  return Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) {
                      _normalize(e.localPosition, size, (x, y) {
                        widget.draw.pointerDown(
                          x,
                          y,
                          relayAvailable: available,
                        );
                        setState(() {});
                      });
                    },
                    onPointerMove: (e) {
                      _normalize(e.localPosition, size, (x, y) {
                        widget.draw.pointerMove(
                          x,
                          y,
                          relayAvailable: available,
                        );
                        setState(() {});
                      });
                    },
                    onPointerUp: (_) {
                      widget.draw.pointerUp(relayAvailable: available);
                      setState(() {});
                    },
                    child: CustomPaint(
                      painter: DoodlePainter(strokes: session.visibleStrokes()),
                    ),
                  );
                },
              )
            else
              const ColoredBox(color: Color(0x22000000)),
            Positioned(
              left: 12,
              right: 12,
              top: 12,
              child: _DoodleToolbar(
                available: available,
                colorId: session.colorId,
                widthId: session.widthId,
                canUndo: session.canUndo,
                canRedo: session.canRedo,
                onColor: (id) {
                  widget.draw.setColor(id);
                  setState(() {});
                },
                onWidth: (id) {
                  widget.draw.setWidth(id);
                  setState(() {});
                },
                onUndo: () {
                  widget.draw.undo(relayAvailable: available);
                  setState(() {});
                },
                onRedo: () {
                  widget.draw.redo();
                  setState(() {});
                },
                onClear: () {
                  widget.draw.clear(relayAvailable: available);
                  setState(() {});
                },
                onCancel: widget.onCancel,
                onSend: widget.onSend,
                onClose: widget.onClose,
                sending: widget.sending,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DoodleToolbar extends StatelessWidget {
  const _DoodleToolbar({
    required this.available,
    required this.colorId,
    required this.widthId,
    required this.canUndo,
    required this.canRedo,
    required this.onColor,
    required this.onWidth,
    required this.onUndo,
    required this.onRedo,
    required this.onClear,
    required this.onCancel,
    required this.onSend,
    required this.onClose,
    required this.sending,
  });

  final bool available;
  final int colorId;
  final int widthId;
  final bool canUndo;
  final bool canRedo;
  final ValueChanged<int> onColor;
  final ValueChanged<int> onWidth;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onClear;
  final VoidCallback onCancel;
  final Future<void> Function() onSend;
  final VoidCallback onClose;
  final bool sending;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(AppRadius.field),
        boxShadow: softShadow(opacity: 0.08),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    available
                        ? 'Draw on chat'
                        : 'Doodle unavailable — reconnecting',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Close doodle',
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < doodlePalette.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _ColorSwatch(
                        color: Color(doodleColorForId(i)),
                        selected: colorId == i,
                        onTap: available ? () => onColor(i) : null,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < doodleBrushWidths.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _WidthSwatch(
                        width: doodleBrushWidths[i],
                        selected: widthId == i,
                        onTap: available ? () => onWidth(i) : null,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                IconButton(
                  tooltip: 'Undo',
                  onPressed: available && canUndo ? onUndo : null,
                  icon: const Icon(Icons.undo_rounded),
                ),
                IconButton(
                  tooltip: 'Redo',
                  onPressed: available && canRedo ? onRedo : null,
                  icon: const Icon(Icons.redo_rounded),
                ),
                IconButton(
                  tooltip: 'Clear',
                  onPressed: available ? onClear : null,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
                TextButton(
                  onPressed: sending ? null : onCancel,
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: available && !sending ? () => onSend() : null,
                  child: sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Send'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Color',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(
              color: selected ? AppColors.brand : Colors.black26,
              width: selected ? 2.5 : 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _WidthSwatch extends StatelessWidget {
  const _WidthSwatch({
    required this.width,
    required this.selected,
    required this.onTap,
  });

  final double width;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Brush width',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: 36,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? AppColors.brand : Colors.black26,
              width: selected ? 2 : 1,
            ),
          ),
          child: Container(
            width: width.clamp(2, 16),
            height: width.clamp(2, 16),
            decoration: const BoxDecoration(
              color: Colors.black87,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

class DoodlePainter extends CustomPainter {
  DoodlePainter({required this.strokes});

  final List<DoodleStroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    paintDoodleStrokes(
      canvas,
      size,
      strokes,
      sourceWidth: size.width,
      sourceHeight: size.height,
    );
  }

  @override
  bool shouldRepaint(covariant DoodlePainter oldDelegate) {
    return !identical(oldDelegate.strokes, strokes);
  }
}
