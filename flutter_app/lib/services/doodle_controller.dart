import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../doodle_stroke.dart';
import '../realtime_service.dart';

typedef DoodleSendFrame = void Function(Map<String, dynamic> payload);

/// Outgoing doodle session: local strokes, undo/redo, and batched relay.
class DoodleDrawController {
  DoodleDrawController({
    required this.conversationId,
    required this.send,
    this.batchMinMs = doodleBatchMinMs,
    this.batchMaxMs = doodleBatchMaxMs,
  }) : session = DoodleSession(
         sessionId: const Uuid().v4().replaceAll('-', ''),
       );

  final int conversationId;
  final DoodleSendFrame send;
  final int batchMinMs;
  final int batchMaxMs;

  final DoodleSession session;
  String? _activeStrokeId;
  final List<DoodlePoint> _pending = [];
  Timer? _batchTimer;

  bool get isActive => _started;
  bool _started = false;

  void start({required bool relayAvailable}) {
    if (_started || !relayAvailable) return;
    _started = true;
    send({
      'type': 'chat.doodle.begin',
      'conversation_id': conversationId,
      'session_id': session.sessionId,
      'color_id': session.colorId,
      'width_id': session.widthId,
    });
  }

  void setColor(int colorId) {
    session.colorId = colorId;
  }

  void setWidth(int widthId) {
    session.widthId = widthId;
  }

  void pointerDown(double nx, double ny, {required bool relayAvailable}) {
    if (!relayAvailable || session.atSessionPointCap) return;
    if (!_started) start(relayAvailable: relayAvailable);
    _activeStrokeId = const Uuid().v4().replaceAll('-', '');
    session.beginStroke(_activeStrokeId!);
    _appendPoint(DoodlePoint(nx, ny));
  }

  void pointerMove(double nx, double ny, {required bool relayAvailable}) {
    if (!relayAvailable || _activeStrokeId == null) return;
    _appendPoint(DoodlePoint(nx, ny));
  }

  void pointerUp({required bool relayAvailable}) {
    if (_activeStrokeId == null) return;
    _flushBatch(force: true, relayAvailable: relayAvailable);
    session.finishStroke();
    _activeStrokeId = null;
  }

  void undo({required bool relayAvailable}) {
    if (!session.undo()) return;
    if (relayAvailable) {
      send({
        'type': 'chat.doodle.undo',
        'conversation_id': conversationId,
        'session_id': session.sessionId,
      });
    }
  }

  void redo() {
    session.redo();
  }

  void clear({required bool relayAvailable}) {
    session.clear();
    if (relayAvailable) {
      send({
        'type': 'chat.doodle.clear',
        'conversation_id': conversationId,
        'session_id': session.sessionId,
      });
    }
  }

  void cancel({required bool relayAvailable}) {
    _end(reason: 'cancel', relayAvailable: relayAvailable);
  }

  void sendDrawing({required bool relayAvailable}) {
    _end(reason: 'send', relayAvailable: relayAvailable);
  }

  void dispose({required bool relayAvailable}) {
    _end(reason: 'disconnect', relayAvailable: relayAvailable);
  }

  void _appendPoint(DoodlePoint point) {
    if (!session.addActivePoint(point)) return;
    _pending.add(point);
    _scheduleBatch();
  }

  void _scheduleBatch() {
    _batchTimer ??= Timer(Duration(milliseconds: batchMinMs), () {
      _batchTimer = null;
      _flushBatch(relayAvailable: true);
    });
  }

  void _flushBatch({bool force = false, required bool relayAvailable}) {
    if (!relayAvailable || _pending.isEmpty || _activeStrokeId == null) {
      if (force) _pending.clear();
      return;
    }
    final batch = List<DoodlePoint>.from(_pending);
    _pending.clear();
    send({
      'type': 'chat.doodle.stroke',
      'conversation_id': conversationId,
      'session_id': session.sessionId,
      'stroke_id': _activeStrokeId,
      'color_id': session.colorId,
      'width_id': session.widthId,
      'points': batch.map((p) => p.toJson()).toList(),
    });
  }

  void _end({required String reason, required bool relayAvailable}) {
    _batchTimer?.cancel();
    _batchTimer = null;
    session.cancelActiveStroke();
    _flushBatch(force: true, relayAvailable: relayAvailable);
    if (_started && relayAvailable) {
      send({
        'type': 'chat.doodle.end',
        'conversation_id': conversationId,
        'session_id': session.sessionId,
        'reason': reason,
      });
    }
    _started = false;
    _activeStrokeId = null;
    _pending.clear();
  }
}

/// Tracks one peer's ephemeral doodle for read-only overlay rendering.
class DoodleIncomingController extends ChangeNotifier {
  DoodleIncomingController({required this.conversationId});

  final int conversationId;
  DoodleLiveSession? _live;

  DoodleLiveSession? get live => _live;
  bool get hasLive => _live != null;

  void apply(DoodleRelayUpdate update) {
    if (update.conversationId != conversationId) return;
    _live ??= DoodleLiveSession(
      sessionId: update.sessionId,
      fromUserId: update.fromUserId,
    );
    if (_live!.sessionId != update.sessionId) {
      _live = DoodleLiveSession(
        sessionId: update.sessionId,
        fromUserId: update.fromUserId,
      );
    }
    final keep = applyDoodleRelay(_live!, update);
    if (!keep) {
      _live = null;
    }
    notifyListeners();
  }

  void clearOnDisconnect() {
    if (_live == null) return;
    _live = null;
    notifyListeners();
  }
}

/// Thin adapter so tests can inject a fake sender.
class RealtimeDoodleSender {
  RealtimeDoodleSender(this.realtime);

  final RealtimeService realtime;

  DoodleSendFrame get send => realtime.send;
}
