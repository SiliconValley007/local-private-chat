import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../doodle_stroke.dart';

/// Maximum exported edge length for persistent doodle PNGs.
const maxDoodleExportEdge = 2048;

/// Client-side byte cap matching server validation.
const maxDoodleExportBytes = 2 * 1024 * 1024;

class DoodleExportException implements Exception {
  DoodleExportException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Target raster size preserving aspect ratio within [maxDoodleExportEdge].
({int width, int height}) computeDoodleExportSize({
  required double canvasWidth,
  required double canvasHeight,
}) {
  if (canvasWidth <= 0 || canvasHeight <= 0) {
    return (width: maxDoodleExportEdge, height: maxDoodleExportEdge);
  }
  final longest = math.max(canvasWidth, canvasHeight);
  if (longest <= maxDoodleExportEdge) {
    return (
      width: canvasWidth.round().clamp(1, maxDoodleExportEdge),
      height: canvasHeight.round().clamp(1, maxDoodleExportEdge),
    );
  }
  final scale = maxDoodleExportEdge / longest;
  final w = (canvasWidth * scale).round().clamp(1, maxDoodleExportEdge);
  final h = (canvasHeight * scale).round().clamp(1, maxDoodleExportEdge);
  return (width: w, height: h);
}

/// Flatten [strokes] drawn on [canvasWidth]×[canvasHeight] to a transparent PNG.
Future<Uint8List> exportDoodlePng({
  required List<DoodleStroke> strokes,
  required double canvasWidth,
  required double canvasHeight,
}) async {
  if (strokes.isEmpty) {
    throw DoodleExportException('Draw something before sending.');
  }
  var size = computeDoodleExportSize(
    canvasWidth: canvasWidth,
    canvasHeight: canvasHeight,
  );
  for (var attempt = 0; attempt < 8; attempt++) {
    final bytes = await _renderPng(
      strokes: strokes,
      pixelWidth: size.width,
      pixelHeight: size.height,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
    );
    if (bytes.length <= maxDoodleExportBytes) return bytes;
    size = (
      width: (size.width * 0.85).round().clamp(1, maxDoodleExportEdge),
      height: (size.height * 0.85).round().clamp(1, maxDoodleExportEdge),
    );
  }
  throw DoodleExportException(
    'This drawing is too large to send. Try clearing and drawing less.',
  );
}

Future<Uint8List> _renderPng({
  required List<DoodleStroke> strokes,
  required int pixelWidth,
  required int pixelHeight,
  required double canvasWidth,
  required double canvasHeight,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  paintDoodleStrokes(
    canvas,
    Size(pixelWidth.toDouble(), pixelHeight.toDouble()),
    strokes,
    sourceWidth: canvasWidth,
    sourceHeight: canvasHeight,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(pixelWidth, pixelHeight);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  if (byteData == null) {
    throw DoodleExportException('Could not export the drawing.');
  }
  return byteData.buffer.asUint8List();
}

/// Shared stroke renderer for overlay and PNG export.
void paintDoodleStrokes(
  Canvas canvas,
  Size targetSize,
  List<DoodleStroke> strokes, {
  required double sourceWidth,
  required double sourceHeight,
}) {
  final scaleX = targetSize.width / sourceWidth;
  final scaleY = targetSize.height / sourceHeight;
  for (final stroke in strokes) {
    if (stroke.points.isEmpty) continue;
    final paint = Paint()
      ..color = Color(doodleColorForId(stroke.colorId))
      ..strokeWidth =
          doodleWidthForId(stroke.widthId) * math.min(scaleX, scaleY)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    final pts = denormalizePoints(
      stroke.points,
      width: sourceWidth,
      height: sourceHeight,
    );
    final scaled = [
      for (final p in pts) OffsetLike(p.dx * scaleX, p.dy * scaleY),
    ];
    final smoothed = smoothStrokePoints(scaled);
    if (smoothed.length == 1) {
      canvas.drawPoints(ui.PointMode.points, [
        Offset(smoothed.first.dx, smoothed.first.dy),
      ], paint);
      continue;
    }
    final path = Path()..moveTo(smoothed.first.dx, smoothed.first.dy);
    for (var i = 1; i < smoothed.length; i++) {
      path.lineTo(smoothed[i].dx, smoothed[i].dy);
    }
    canvas.drawPath(path, paint);
  }
}
