/// Pure doodle stroke/session models: normalized coords, caps, undo/redo,
/// and quadratic smoothing helpers (no Flutter imports).
library;

import 'dart:math' as math;

/// Stable palette ids exchanged over the wire (ARGB ints).
const doodlePalette = <int>[
  0xFF000000,
  0xFFE53935,
  0xFF1E88E5,
  0xFF43A047,
  0xFFFDD835,
  0xFF8E24AA,
  0xFFFF7043,
  0xFFFFFFFF,
];

/// Brush width ids map to logical stroke widths in device pixels after scaling.
const doodleBrushWidths = <double>[2, 4, 8, 12, 18];

const maxDoodleStrokes = 200;
const maxPointsPerStroke = 2000;
const maxPointsPerSession = 10000;
const maxPointsPerBatch = 128;
const doodleBatchMinMs = 50;
const doodleBatchMaxMs = 100;

/// Normalized point in 0..1 canvas space.
class DoodlePoint {
  const DoodlePoint(this.x, this.y);

  final double x;
  final double y;

  List<double> toJson() => [x, y];

  static DoodlePoint? fromJson(Object? raw) {
    if (raw is! List || raw.length != 2) return null;
    final x = raw[0];
    final y = raw[1];
    if (x is! num || y is! num) return null;
    final xf = x.toDouble();
    final yf = y.toDouble();
    if (xf < 0 || xf > 1 || yf < 0 || yf > 1) return null;
    return DoodlePoint(xf, yf);
  }
}

class DoodleStroke {
  DoodleStroke({
    required this.id,
    required this.colorId,
    required this.widthId,
    List<DoodlePoint>? points,
  }) : points = points ?? [];

  final String id;
  final int colorId;
  final int widthId;
  final List<DoodlePoint> points;

  bool get atPointCap => points.length >= maxPointsPerStroke;

  bool appendPoint(DoodlePoint point) {
    if (atPointCap) return false;
    points.add(point);
    return true;
  }

  bool appendPoints(Iterable<DoodlePoint> batch) {
    var ok = true;
    for (final p in batch) {
      if (!appendPoint(p)) {
        ok = false;
        break;
      }
    }
    return ok;
  }

  DoodleStroke copyWith({List<DoodlePoint>? points}) {
    return DoodleStroke(
      id: id,
      colorId: colorId,
      widthId: widthId,
      points: points ?? List.of(this.points),
    );
  }
}

/// Local interactive session with undo/redo stacks.
class DoodleSession {
  DoodleSession({required this.sessionId, this.colorId = 0, this.widthId = 1});

  final String sessionId;
  int colorId;
  int widthId;

  final List<DoodleStroke> strokes = [];
  final List<List<DoodleStroke>> _undoStack = [];
  final List<List<DoodleStroke>> _redoStack = [];

  DoodleStroke? _active;

  int get totalPoints =>
      strokes.fold<int>(0, (sum, s) => sum + s.points.length) +
      (_active?.points.length ?? 0);

  bool get canUndo => strokes.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  bool get atStrokeCap => strokes.length >= maxDoodleStrokes;
  bool get atSessionPointCap => totalPoints >= maxPointsPerSession;

  bool beginStroke(String strokeId) {
    if (_active != null || atStrokeCap || atSessionPointCap) return false;
    _active = DoodleStroke(id: strokeId, colorId: colorId, widthId: widthId);
    return true;
  }

  bool addActivePoint(DoodlePoint point) {
    final stroke = _active;
    if (stroke == null || atSessionPointCap) return false;
    if (!stroke.appendPoint(point)) return false;
    return true;
  }

  bool finishStroke() {
    final stroke = _active;
    if (stroke == null || stroke.points.isEmpty) {
      _active = null;
      return false;
    }
    _pushUndo();
    strokes.add(stroke);
    _active = null;
    _redoStack.clear();
    return true;
  }

  void cancelActiveStroke() {
    _active = null;
  }

  bool undo() {
    if (_active != null) {
      _active = null;
      return true;
    }
    if (strokes.isEmpty) return false;
    _pushUndo();
    final removed = strokes.removeLast();
    _redoStack.add([removed]);
    return true;
  }

  bool redo() {
    if (_redoStack.isEmpty) return false;
    _pushUndo();
    final restored = _redoStack.removeLast();
    strokes.addAll(restored);
    return true;
  }

  void clear() {
    if (strokes.isEmpty && _active == null) return;
    _pushUndo();
    strokes.clear();
    _active = null;
    _redoStack.clear();
  }

  List<DoodleStroke> visibleStrokes() {
    if (_active == null) return List.unmodifiable(strokes);
    return List.unmodifiable([...strokes, _active!]);
  }

  void _pushUndo() {
    _undoStack.add(strokes.map((s) => s.copyWith()).toList());
    if (_undoStack.length > 50) {
      _undoStack.removeAt(0);
    }
  }
}

/// Incoming peer doodle keyed by session id (read-only overlay).
class DoodleLiveSession {
  DoodleLiveSession({required this.sessionId, required this.fromUserId});

  final String sessionId;
  final int fromUserId;
  final Map<String, DoodleStroke> strokes = {};
  int? colorId;
  int? widthId;

  List<DoodleStroke> visibleStrokes() => strokes.values.toList();

  void applyBegin({required int colorId, required int widthId}) {
    this.colorId = colorId;
    this.widthId = widthId;
  }

  void applyStrokeBatch({
    required String strokeId,
    required List<DoodlePoint> points,
  }) {
    final colorId = this.colorId ?? 0;
    final widthId = this.widthId ?? 1;
    final existing = strokes[strokeId];
    if (existing == null) {
      final stroke = DoodleStroke(
        id: strokeId,
        colorId: colorId,
        widthId: widthId,
      );
      stroke.appendPoints(points);
      strokes[strokeId] = stroke;
    } else {
      existing.appendPoints(points);
    }
  }

  void undoLast() {
    if (strokes.isEmpty) return;
    strokes.remove(strokes.keys.last);
  }

  void clearAll() {
    strokes.clear();
  }
}

int doodleColorForId(int colorId) {
  if (colorId < 0 || colorId >= doodlePalette.length) {
    return doodlePalette.first;
  }
  return doodlePalette[colorId];
}

double doodleWidthForId(int widthId) {
  if (widthId < 0 || widthId >= doodleBrushWidths.length) {
    return doodleBrushWidths[1];
  }
  return doodleBrushWidths[widthId];
}

/// Convert normalized points to device coordinates.
List<OffsetLike> denormalizePoints(
  Iterable<DoodlePoint> points, {
  required double width,
  required double height,
}) {
  return [for (final p in points) OffsetLike(p.x * width, p.y * height)];
}

/// Lightweight offset for pure tests (mirrors dart:ui Offset).
class OffsetLike {
  const OffsetLike(this.dx, this.dy);
  final double dx;
  final double dy;
}

/// Build a smoothed polyline using mid-point quadratic curves.
List<OffsetLike> smoothStrokePoints(List<OffsetLike> pts) {
  if (pts.length < 2) return pts;
  if (pts.length == 2) {
    return [pts.first, pts.last];
  }
  final out = <OffsetLike>[pts.first];
  for (var i = 1; i < pts.length - 1; i++) {
    final p0 = pts[i - 1];
    final p1 = pts[i];
    final p2 = pts[i + 1];
    final mid1 = OffsetLike((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
    final mid2 = OffsetLike((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
    out.add(mid1);
    out.add(p1);
    out.add(mid2);
  }
  out.add(pts.last);
  return out;
}

/// Split [points] into wire batches respecting [maxPointsPerBatch].
List<List<DoodlePoint>> batchPoints(List<DoodlePoint> points) {
  if (points.isEmpty) return const [];
  final batches = <List<DoodlePoint>>[];
  for (var i = 0; i < points.length; i += maxPointsPerBatch) {
    final end = math.min(i + maxPointsPerBatch, points.length);
    batches.add(points.sublist(i, end));
  }
  return batches;
}

/// Whether a relay event type belongs to doodle.
bool isDoodleEventType(String? type) {
  return type == 'chat.doodle.begin' ||
      type == 'chat.doodle.stroke' ||
      type == 'chat.doodle.undo' ||
      type == 'chat.doodle.clear' ||
      type == 'chat.doodle.end';
}

/// Parse a relay frame into a structured update (pure).
DoodleRelayUpdate? parseDoodleRelay(Map<String, dynamic> event) {
  final type = event['type'] as String?;
  if (!isDoodleEventType(type)) return null;
  final conversationId = event['conversation_id'];
  final sessionId = event['session_id'];
  final fromUserId = event['from_user_id'];
  if (conversationId is! int || sessionId is! String || fromUserId is! int) {
    return null;
  }
  switch (type) {
    case 'chat.doodle.begin':
      final colorId = event['color_id'];
      final widthId = event['width_id'];
      if (colorId is! int || widthId is! int) return null;
      return DoodleRelayUpdate.begin(
        conversationId: conversationId,
        sessionId: sessionId,
        fromUserId: fromUserId,
        colorId: colorId,
        widthId: widthId,
      );
    case 'chat.doodle.stroke':
      final strokeId = event['stroke_id'];
      final rawPoints = event['points'];
      if (strokeId is! String || rawPoints is! List) return null;
      final points = <DoodlePoint>[];
      for (final raw in rawPoints) {
        final pt = DoodlePoint.fromJson(raw);
        if (pt == null) return null;
        points.add(pt);
      }
      if (points.isEmpty) return null;
      return DoodleRelayUpdate.stroke(
        conversationId: conversationId,
        sessionId: sessionId,
        fromUserId: fromUserId,
        strokeId: strokeId,
        points: points,
      );
    case 'chat.doodle.undo':
      return DoodleRelayUpdate.undo(
        conversationId: conversationId,
        sessionId: sessionId,
        fromUserId: fromUserId,
      );
    case 'chat.doodle.clear':
      return DoodleRelayUpdate.clear(
        conversationId: conversationId,
        sessionId: sessionId,
        fromUserId: fromUserId,
      );
    case 'chat.doodle.end':
      final reason = '${event['reason'] ?? 'cancel'}';
      return DoodleRelayUpdate.end(
        conversationId: conversationId,
        sessionId: sessionId,
        fromUserId: fromUserId,
        reason: reason,
      );
    default:
      return null;
  }
}

sealed class DoodleRelayUpdate {
  const DoodleRelayUpdate({
    required this.conversationId,
    required this.sessionId,
    required this.fromUserId,
  });

  final int conversationId;
  final String sessionId;
  final int fromUserId;

  factory DoodleRelayUpdate.begin({
    required int conversationId,
    required String sessionId,
    required int fromUserId,
    required int colorId,
    required int widthId,
  }) = DoodleRelayBegin;

  factory DoodleRelayUpdate.stroke({
    required int conversationId,
    required String sessionId,
    required int fromUserId,
    required String strokeId,
    required List<DoodlePoint> points,
  }) = DoodleRelayStroke;

  factory DoodleRelayUpdate.undo({
    required int conversationId,
    required String sessionId,
    required int fromUserId,
  }) = DoodleRelayUndo;

  factory DoodleRelayUpdate.clear({
    required int conversationId,
    required String sessionId,
    required int fromUserId,
  }) = DoodleRelayClear;

  factory DoodleRelayUpdate.end({
    required int conversationId,
    required String sessionId,
    required int fromUserId,
    required String reason,
  }) = DoodleRelayEnd;
}

final class DoodleRelayBegin extends DoodleRelayUpdate {
  const DoodleRelayBegin({
    required super.conversationId,
    required super.sessionId,
    required super.fromUserId,
    required this.colorId,
    required this.widthId,
  });

  final int colorId;
  final int widthId;
}

final class DoodleRelayStroke extends DoodleRelayUpdate {
  const DoodleRelayStroke({
    required super.conversationId,
    required super.sessionId,
    required super.fromUserId,
    required this.strokeId,
    required this.points,
  });

  final String strokeId;
  final List<DoodlePoint> points;
}

final class DoodleRelayUndo extends DoodleRelayUpdate {
  const DoodleRelayUndo({
    required super.conversationId,
    required super.sessionId,
    required super.fromUserId,
  });
}

final class DoodleRelayClear extends DoodleRelayUpdate {
  const DoodleRelayClear({
    required super.conversationId,
    required super.sessionId,
    required super.fromUserId,
  });
}

final class DoodleRelayEnd extends DoodleRelayUpdate {
  const DoodleRelayEnd({
    required super.conversationId,
    required super.sessionId,
    required super.fromUserId,
    required this.reason,
  });

  final String reason;
}

/// Apply a relay update to [target]; returns false when the session should close.
bool applyDoodleRelay(DoodleLiveSession target, DoodleRelayUpdate update) {
  switch (update) {
    case DoodleRelayBegin(:final colorId, :final widthId):
      target.applyBegin(colorId: colorId, widthId: widthId);
      return true;
    case DoodleRelayStroke(:final strokeId, :final points):
      target.applyStrokeBatch(strokeId: strokeId, points: points);
      return true;
    case DoodleRelayUndo():
      target.undoLast();
      return true;
    case DoodleRelayClear():
      target.clearAll();
      return true;
    case DoodleRelayEnd():
      return false;
  }
}

/// Whether doodle drawing should be allowed right now.
bool doodleRelayAvailable({required bool realtimeConnected}) =>
    realtimeConnected;
