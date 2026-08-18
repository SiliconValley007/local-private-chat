import 'package:flutter/material.dart';

/// Widest a preview is allowed to lie, as height over width.
///
/// A panorama would otherwise be a letterbox slit two lines tall.
const double chatMediaWidestRatio = 0.56;

/// Tallest a preview is allowed to stand, as height over width.
///
/// A phone screenshot is nearly 1:2 and would eat the whole viewport, so past
/// this it is cropped from the bottom — the same bargain WhatsApp strikes.
const double chatMediaTallestRatio = 1.45;

/// Shape a preview holds until the picture's own shape is known.
///
/// Also the shape of the placeholder and of anything that fails to load, so a
/// row does not resize when a retry finally succeeds.
const double chatMediaFallbackRatio = 0.72;

/// Height for a preview [width] wide showing media of [source] pixel size.
///
/// Forcing every attachment into one box was cheap for layout and wrong for
/// everything else: a tall screenshot came out squashed, because a decode told
/// to produce exactly that box does not keep the picture's proportions.
double chatMediaPreviewHeight({required double width, Size? source}) {
  final ratio = chatMediaRatio(source);
  return width * ratio;
}

/// Clamped height-over-width for [source], or the fallback when it is unknown.
double chatMediaRatio(Size? source) {
  if (source == null || source.width <= 0 || source.height <= 0) {
    return chatMediaFallbackRatio;
  }
  final ratio = source.height / source.width;
  return ratio.clamp(chatMediaWidestRatio, chatMediaTallestRatio);
}

/// Which part of an over-tall picture to keep.
///
/// Screenshots and portraits carry their subject up top — a chat window's title,
/// a face — so a crop takes from the bottom rather than around the middle.
Alignment chatMediaAlignment(Size? source) {
  if (source == null || source.width <= 0) return Alignment.center;
  return source.height / source.width > chatMediaTallestRatio
      ? Alignment.topCenter
      : Alignment.center;
}

/// Pixel sizes of media already decoded, so a preview keeps its shape.
///
/// Without this a row would settle twice: once at the fallback shape while the
/// bytes arrive, then again on every later visit to the same photo.
class MediaShapeCache {
  MediaShapeCache._();

  static final Map<int, Size> _sizes = {};

  static Size? of(int messageId) => _sizes[messageId];

  static void remember(int messageId, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    // Bounded so a long afternoon of browsing cannot grow this without end.
    if (_sizes.length >= 400 && !_sizes.containsKey(messageId)) {
      _sizes.remove(_sizes.keys.first);
    }
    _sizes[messageId] = size;
  }

  static void clear() => _sizes.clear();
}

/// Measures [image] as it decodes and hands its builder the box to draw in.
///
/// The listener attaches to the very same provider the caller draws with, so
/// learning the shape costs no extra request and no second decode.
class MediaShape extends StatefulWidget {
  const MediaShape({
    required this.messageId,
    required this.image,
    required this.width,
    required this.builder,
    this.source,
    super.key,
  });

  final int messageId;
  final ImageProvider image;
  final double width;

  /// Pixel size the sender's media is known to have, when the server could read
  /// it. Given this, a row is the right height from its first frame and never
  /// resizes under the reader.
  final Size? source;

  /// Given the box the preview should occupy and how to crop inside it.
  final Widget Function(BuildContext context, Size box, Alignment alignment)
  builder;

  @override
  State<MediaShape> createState() => _MediaShapeState();
}

class _MediaShapeState extends State<MediaShape> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _source;

  /// True once the shape came from a decoded picture rather than a hint.
  bool _decoded = false;

  @override
  void initState() {
    super.initState();
    _adopt(widget.messageId);
  }

  void _adopt(int messageId) {
    final known = MediaShapeCache.of(messageId);
    _decoded = known != null;
    _source = known ?? _hint;
  }

  /// The declared size, ignored when it is not a usable pair of numbers.
  Size? get _hint {
    final hint = widget.source;
    if (hint == null || hint.width <= 0 || hint.height <= 0) return null;
    return hint;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listen();
  }

  @override
  void didUpdateWidget(MediaShape old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image || old.messageId != widget.messageId) {
      _adopt(widget.messageId);
      _detach();
      _listen();
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _listen() {
    // A hint still gets checked against the picture itself, so a stale or
    // mis-rotated size cannot leave a preview cropped for good.
    if (_decoded || _stream != null) return;
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener(_measured, onError: (_, _) {});
    _stream = stream..addListener(listener);
    _listener = listener;
  }

  void _detach() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  void _measured(ImageInfo info, bool synchronous) {
    final size = Size(
      info.image.width.toDouble(),
      info.image.height.toDouble(),
    );
    // This listener shares the frame with the Image widget below. Disposing the
    // shared ImageInfo here can force a second decode on slower devices.
    MediaShapeCache.remember(widget.messageId, size);
    if (!mounted) return;
    _decoded = true;
    if (_source == size) return;
    if (synchronous) {
      _source = size;
      return;
    }
    setState(() => _source = size);
  }

  @override
  Widget build(BuildContext context) {
    final box = Size(
      widget.width,
      chatMediaPreviewHeight(width: widget.width, source: _source),
    );
    return widget.builder(context, box, chatMediaAlignment(_source));
  }
}
