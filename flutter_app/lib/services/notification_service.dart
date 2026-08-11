import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../navigation.dart';
import 'contacts_store.dart';

const _channelId = 'local_chat_messages';
const _channelName = 'Messages';
const _channelDescription = 'New chat messages';

/// Runs in its own isolate when a push arrives while the app is backgrounded or
/// killed, so everything it needs must be initialised here from scratch.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await NotificationService.instance.showFromPushData(message.data);
}

class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _localReady = false;
  bool firebaseReady = false;

  void Function(int conversationId)? _onOpenConversation;

  /// Called when FCM rotates our token, so the server can be told the new one.
  void Function(String token)? onTokenRefresh;

  /// Sets up local notifications. Safe to call from a background isolate: it
  /// never asks for permission and never touches the UI.
  Future<void> _ensureLocalNotifications() async {
    if (_localReady) return;
    const android = AndroidInitializationSettings('ic_stat_notification');
    await _plugin.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: (resp) {
        final id = int.tryParse(resp.payload ?? '');
        if (id != null) _routeToConversation(id);
      },
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDescription,
            importance: Importance.high,
          ),
        );
    _localReady = true;
  }

  Future<void> init({
    void Function(int conversationId)? onOpenConversation,
  }) async {
    _onOpenConversation = onOpenConversation;
    await _ensureLocalNotifications();

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.requestNotificationsPermission();

    // Opened from a notification while the app was not running.
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      final id = int.tryParse(launch?.notificationResponse?.payload ?? '');
      if (id != null) pendingOpenConversationId = id;
    }

    try {
      await Firebase.initializeApp();
      firebaseReady = true;

      await FirebaseMessaging.instance.requestPermission();

      // In the foreground Android shows nothing, so we draw it ourselves. The
      // app is alive here, so it can use the real message it already has.
      FirebaseMessaging.onMessage.listen((msg) => showFromPushData(msg.data));

      FirebaseMessaging.onMessageOpenedApp.listen(_openFromPush);
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        final cid = _conversationIdFrom(initial.data);
        if (cid != null) pendingOpenConversationId = cid;
      }

      FirebaseMessaging.instance.onTokenRefresh.listen((token) {
        if (token.isNotEmpty) onTokenRefresh?.call(token);
      });
    } catch (e) {
      debugPrint('Firebase optional init skipped: $e');
      firebaseReady = false;
    }
  }

  void _openFromPush(RemoteMessage msg) {
    final cid = _conversationIdFrom(msg.data);
    if (cid != null) _routeToConversation(cid);
  }

  void _routeToConversation(int conversationId) {
    pendingOpenConversationId = conversationId;
    _onOpenConversation?.call(conversationId);
  }

  int? _conversationIdFrom(Map<String, dynamic> data) =>
      int.tryParse('${data['conversation_id'] ?? ''}');

  Future<String?> fcmToken() async {
    if (!firebaseReady) return null;
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (_) {
      return null;
    }
  }

  /// Shows a message notification. [body] stays on this device, so it may hold
  /// a real preview; pushes from the server never carry message content.
  Future<void> showIncomingMessage({
    required int conversationId,
    required String title,
    String body = 'New message',
  }) async {
    await _ensureLocalNotifications();
    await _plugin.show(
      conversationId,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          groupKey: 'local_chat_$conversationId',
          styleInformation: BigTextStyleInformation(body),
        ),
      ),
      payload: '$conversationId',
    );
  }

  /// Removes the tray notification for one chat.
  ///
  /// The notification id is the conversation id, so opening a chat can dismiss
  /// exactly its own alert and leave other chats' notifications alone.
  Future<void> clearConversation(int conversationId) async {
    try {
      await _ensureLocalNotifications();
      await _plugin.cancel(conversationId);
    } catch (e) {
      debugPrint('Could not clear notification for $conversationId: $e');
    }
  }

  Future<void> showFromPushData(Map<String, dynamic> data) async {
    final cid = _conversationIdFrom(data);
    if (cid == null) return;
    final sender = await notificationTitleFromData(data);
    await showIncomingMessage(
      conversationId: cid,
      title: sender,
    );
  }

  /// Resolves the push sender through this phone's private address book.
  /// Public for a focused unit test; no UI or Firebase instance is required.
  Future<String> notificationTitleFromData(Map<String, dynamic> data) async {
    final username = '${data['sender_username'] ?? ''}'.trim();
    final serverName = '${data['sender_name'] ?? ''}'.trim();
    var sender = serverName;
    if (username.isNotEmpty) {
      // This works in the background isolate too: aliases are deliberately
      // device-local and are available without the UI or chat server.
      final aliases = await ContactsStore().aliases();
      sender = aliases[username] ?? serverName;
    }
    return sender.isEmpty ? 'Local Chat' : sender;
  }
}
