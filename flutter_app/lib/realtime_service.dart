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
  int _attempt = 0;
  final _handlers = <RealtimeHandler>[];

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

  void _open() {
    final url = api.wsUrl;
    if (url == null) return;
    _sub?.cancel();
    _sub = null;
    _active = true;
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      _sub = _channel!.stream.listen(
        (data) {
          _attempt = 0; // A live connection resets the backoff.
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
