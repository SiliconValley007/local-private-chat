import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';

typedef RealtimeHandler = void Function(Map<String, dynamic> event);

/// Close code the server uses when the token is missing, expired or invalid.
const int wsUnauthorizedCode = 4401;

class RealtimeService {
  RealtimeService(this.api);

  final ApiClient api;
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnect;
  Timer? _ping;
  bool _manualClose = false;

  /// A socket is open or being opened. Guards against stacking connections when
  /// several code paths (login, resume, health check) all ask to connect.
  bool _active = false;
  bool _connected = false;
  int _attempt = 0;
  final _handlers = <RealtimeHandler>[];

  /// True once the WebSocket is open and delivering events.
  bool get isConnected => _connected;

  /// Fired whenever [isConnected] flips (connect, drop, reconnect).
  void Function(bool connected)? onConnectionChanged;

  /// Called when the server rejects our token, so the app can ask for a sign-in
  /// instead of reconnecting forever.
  void Function()? onAuthFailure;

  void addHandler(RealtimeHandler handler) => _handlers.add(handler);
  void removeHandler(RealtimeHandler handler) => _handlers.remove(handler);

  void connect() {
    _manualClose = false;
    _attempt = 0;
    if (_active) return;
    _open();
  }

  void disconnect() {
    _manualClose = true;
    _active = false;
    _reconnect?.cancel();
    _ping?.cancel();
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    _setConnected(false);
  }

  void send(Map<String, dynamic> event) {
    _channel?.sink.add(jsonEncode(event));
  }

  void sendTyping(int conversationId, bool isTyping) {
    send({
      'type': 'typing',
      'conversation_id': conversationId,
      'is_typing': isTyping,
    });
  }

  void ackDelivered(int messageId) {
    send({'type': 'ack.delivered', 'message_id': messageId});
  }

  /// Fire an ephemeral poke; the server fans it out and drops it if throttled.
  void sendNudge(
    int conversationId, {
    String variant = 'wave',
    required String nudgeId,
  }) {
    send({
      'type': 'chat.nudge',
      'conversation_id': conversationId,
      'variant': variant,
      'nudge_id': nudgeId,
    });
  }

  /// Relays a call-signaling frame (invite/offer/answer/ice/reject/end/busy).
  void sendCallSignal(Map<String, dynamic> payload) => send(payload);

  /// Relays an end-to-end key-exchange frame for a DM.
  void sendE2eSignal(Map<String, dynamic> payload) => send(payload);

  void _setConnected(bool value) {
    if (_connected == value) return;
    _connected = value;
    onConnectionChanged?.call(value);
  }

  void _open() {
    final url = api.wsUrl;
    if (url == null) return;
    _sub?.cancel();
    _sub = null;
    _active = true;
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _channel = channel;
      // The handshake, not the first inbound event, is what proves we are
      // online. Waiting for traffic left the UI claiming "reconnecting" for as
      // long as the server had nothing to say.
      channel.ready.then(
        (_) {
          if (_channel != channel) {
            return; // A newer socket already replaced us.
          }
          _attempt = 0;
          _setConnected(true);
        },
        onError: (_) {
          if (_channel != channel) return;
          _scheduleReconnect();
        },
      );
      _sub = channel.stream.listen(
        (data) {
          _attempt = 0; // A live connection resets the backoff.
          _setConnected(true);
          try {
            final event = jsonDecode(data as String) as Map<String, dynamic>;
            for (final h in List.of(_handlers)) {
              h(event);
            }
          } catch (_) {}
        },
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
      );
      _ping?.cancel();
      _ping = Timer.periodic(const Duration(seconds: 25), (_) {
        send({'type': 'ping'});
      });
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _ping?.cancel();
    _active = false;
    _setConnected(false);
    final closeCode = _channel?.closeCode;
    _channel = null;
    if (_manualClose) return;
    if (closeCode == wsUnauthorizedCode) {
      // Retrying with a rejected token would loop forever and stay silent.
      _manualClose = true;
      onAuthFailure?.call();
      return;
    }
    _reconnect?.cancel();
    _attempt = (_attempt + 1).clamp(1, 5);
    final delay = Duration(seconds: 1 << _attempt); // 2s, 4s … up to 32s
    _reconnect = Timer(delay, _open);
  }
}
