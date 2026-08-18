import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/video_thumbnail_service.dart';
import '../theme.dart';

/// What the user settled on: the framed image, and how dark it should sit.
class WallpaperChoice {
  const WallpaperChoice({required this.image, required this.dim});

  final File image;
  final double dim;
}

/// Pixel density used when the framed wallpaper is rendered to a file.
///
/// The capture is the preview, so its size is the preview's size times this.
/// Three keeps a phone-sized wallpaper sharp (a 360×760 canvas becomes roughly
/// 1080×2280) without writing a needlessly large upload to a private server.
const double wallpaperCaptureScale = 3;

/// Frames a picked photo before it becomes the chat wallpaper.
///
/// Uploading the raw photo meant the chat decided the framing on everyone's
/// behalf: a wide shot arrived cropped to its middle, and a portrait was blown
/// up past the part that mattered. Here the picture can be pinched, dragged, and
/// dimmed against a live preview of the chat, and what is uploaded is exactly
/// what was on screen.
class WallpaperCropScreen extends StatefulWidget {
  const WallpaperCropScreen({
    super.key,
    required this.source,
    this.initialDim = wallpaperDimDefault,
  });

  final File source;
  final double initialDim;

  @override
  State<WallpaperCropScreen> createState() => _WallpaperCropScreenState();
}

class _WallpaperCropScreenState extends State<WallpaperCropScreen> {
  final _boundary = GlobalKey();
  final _controller = TransformationController();
  late double _dim;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _dim = widget.initialDim.clamp(wallpaperDimFloor, 0.8);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final captured = await captureFramedWallpaper(_boundary);
      final compressed = await VideoThumbnailService.createImage(captured.path);
      final file = compressed.file ?? captured;
      if (compressed.file != null) {
        await captured.delete().catchError((_) => captured);
      }
      if (!mounted) return;
      Navigator.of(context).pop(WallpaperChoice(image: file, dim: _dim));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not prepare that image. Try another one.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Decode to the width the capture will write, not the camera's full 12 MP:
    // a raw decode of a modern photo costs tens of MB on a 3 GB phone.
    final decodeWidth =
        (MediaQuery.sizeOf(context).width * wallpaperCaptureScale).round();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Frame wallpaper'),
        actions: [
          TextButton(
            onPressed: _saving
                ? null
                : () => _controller.value = Matrix4.identity(),
            child: const Text('Reset'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Only the photo is captured: the dim is a separate setting the
                  // chat applies when it paints, so baking it in would darken the
                  // wallpaper twice and could never be undone.
                  RepaintBoundary(
                    key: _boundary,
                    child: ColoredBox(
                      color: Colors.black,
                      child: InteractiveViewer(
                        transformationController: _controller,
                        minScale: 1,
                        maxScale: 6,
                        clipBehavior: Clip.hardEdge,
                        child: Image.file(
                          widget.source,
                          fit: BoxFit.cover,
                          cacheWidth: decodeWidth,
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
                    ),
                  ),
                  IgnorePointer(
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: _dim),
                    ),
                  ),
                  IgnorePointer(child: _PreviewBubbles(scheme: scheme)),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 12,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          child: const Text(
                            'Pinch to zoom, drag to move',
                            style: TextStyle(color: Colors.white, fontSize: 12),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.brightness_6_rounded, size: 20),
                      const SizedBox(width: 8),
                      const Text('Dim'),
                      Expanded(
                        child: Slider(
                          value: _dim,
                          min: wallpaperDimFloor,
                          max: 0.8,
                          divisions: 8,
                          label: '${(_dim * 100).round()}%',
                          onChanged: _saving
                              ? null
                              : (value) => setState(() => _dim = value),
                        ),
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(color: scheme.error),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _confirm,
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wallpaper_rounded),
                      label: Text(_saving ? 'Preparing…' : 'Set wallpaper'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Where the framed wallpaper is written before it is uploaded.
///
/// Replaceable so tests can capture without a platform plugin behind them.
@visibleForTesting
Future<Directory> Function() wallpaperScratchDirectory = getTemporaryDirectory;

/// Renders whatever [boundary] currently shows to a PNG in the cache directory.
Future<File> captureFramedWallpaper(GlobalKey boundary) async {
  final object = boundary.currentContext?.findRenderObject();
  if (object is! RenderRepaintBoundary) {
    throw StateError('wallpaper preview is not on screen');
  }
  final image = await object.toImage(pixelRatio: wallpaperCaptureScale);
  final ByteData? data;
  try {
    data = await image.toByteData(format: ui.ImageByteFormat.png);
  } finally {
    image.dispose();
  }
  if (data == null) throw StateError('wallpaper could not be encoded');

  final dir = await wallpaperScratchDirectory();
  final file = File(
    p.join(dir.path, 'wallpaper_${DateTime.now().millisecondsSinceEpoch}.png'),
  );
  await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  return file;
}

/// Sample bubbles so the framing can be judged against real chat contrast.
class _PreviewBubbles extends StatelessWidget {
  const _PreviewBubbles({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _bubble(context, 'How does this look?', mine: false),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: _bubble(context, 'Perfect right there', mine: true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(BuildContext context, String text, {required bool mine}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bubbleFillFor(context: context, mine: mine, hasWallpaper: true),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}
