import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../navigation.dart';
import '../call_identity.dart';
import '../nudge_log.dart';
import 'conversation_prefs_store.dart';
import 'pending_call_store.dart';

const _channelId = 'local_chat_messages';
const _channelName = 'Messages';
const _channelDescription = 'New chat messages';

const _callChannelId = 'local_chat_calls';
const _callChannelName = 'Calls';
const _callChannelDescription = 'Incoming voice and video calls';

/// Stable notification id for the active incoming call alert.
const incomingCallNotificationId = 900001;

/// All chat alerts share one group so Android bundles them under a single
/// header instead of listing each chat separately.
const _groupKey = 'local_chat_messages';

/// Id of the separate badge notification used by builds up to 1.3.x. Kept only
/// so an upgrade can clear the leftover.
const _legacyBadgeId = 0;

/// Chat alerts in the shade that no longer stand for anything unread.
///
/// A chat alert's id *is* its conversation id, so the unread counts from the
/// inbox are enough to tell which entries have been overtaken by the user
/// reading the chat. Ids that belong to something other than a chat — the call
/// alert, the badge notification older builds left behind — are never touched.
Set<int> staleChatNotificationIds({
  required Iterable<int> active,
  required Set<int> conversationsWithUnread,
}) {
  return active
      .where(
        (id) =>
            id != incomingCallNotificationId &&
            id != _legacyBadgeId &&
            id > 0 &&
            !conversationsWithUnread.contains(id),
      )
      .toSet();
}

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

  /// Unread total shown as the launcher badge on the next chat alert.
  int _badgeCount = 0;

  bool _legacyBadgeCleared = false;

  void Function(int conversationId)? _onOpenConversation;

  /// Opens the call UI for a pending incoming call notification tap.
  void Function(PendingCall call)? _onOpenCall;

  /// Foreground/background push arrived; app should restore the call session.
  void Function(PendingCall call)? onIncomingCallPush;

  /// Called when FCM rotates our token, so the server can be told the new one.
  void Function(String token)? onTokenRefresh;

  /// Foreground message push arrived; reconcile the transcript from the server.
  void Function(int conversationId)? onForegroundMessagePush;

  /// Sets up local notifications. Safe to call from a background isolate: it
  /// never asks for permission and never touches the UI.
  Future<void> _ensureLocalNotifications() async {
    if (_localReady) return;
    const android = AndroidInitializationSettings('ic_stat_notification');
    await _plugin.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: (resp) {
        final payload = resp.payload ?? '';
        if (payload.startsWith('call:')) {
          _routeToPendingCall(payload.substring(5));
          return;
        }
        final id = int.tryParse(payload);
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
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _callChannelId,
            _callChannelName,
            description: _callChannelDescription,
            importance: Importance.max,
            playSound: true,
            enableVibration: true,
          ),
        );
    _localReady = true;
  }

  Future<void> init({
    void Function(int conversationId)? onOpenConversation,
    void Function(PendingCall call)? onOpenCall,
  }) async {
    _onOpenConversation = onOpenConversation;
    _onOpenCall = onOpenCall;
    await _ensureLocalNotifications();

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.requestNotificationsPermission();

    // Opened from a notification while the app was not running.
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      final payload = launch?.notificationResponse?.payload ?? '';
      if (payload.startsWith('call:')) {
        pendingOpenCallId = payload.substring(5);
      } else {
        final id = int.tryParse(payload);
        if (id != null) pendingOpenConversationId = id;
      }
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
    final data = msg.data;
    if ('${data['type'] ?? ''}' == 'call.incoming') {
      final callId = '${data['call_id'] ?? ''}';
      if (callId.isNotEmpty) {
        _routeToPendingCall(callId);
      }
      return;
    }
    final cid = _conversationIdFrom(data);
    if (cid != null) _routeToConversation(cid);
  }

  Future<void> _routeToPendingCall(String callId) async {
    pendingOpenCallId = callId;
    final stored = await PendingCallStore.instance.load();
    if (stored != null && stored.callId == callId) {
      _onOpenCall?.call(stored);
    }
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

  Future<String> _callTitleFromData(Map<String, dynamic> data) async {
    return resolveCallerDisplayName(
      username: '${data['caller_username'] ?? ''}',
      serverName: '${data['caller_name'] ?? ''}',
    );
  }

  /// High-priority incoming call alert (notification-only, no full-screen intent).
  Future<void> showIncomingCall({
    required String callId,
    required int conversationId,
    required String title,
    required bool isVideo,
  }) async {
    await _ensureLocalNotifications();
    final body = isVideo ? 'Incoming video call' : 'Incoming voice call';
    await _plugin.show(
      incomingCallNotificationId,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _callChannelId,
          _callChannelName,
          channelDescription: _callChannelDescription,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: false,
          ongoing: true,
          autoCancel: false,
          playSound: true,
          enableVibration: true,
          ticker: body,
        ),
      ),
      payload: 'call:$callId',
    );
  }

  Future<void> cancelIncomingCall() async {
    try {
      await _ensureLocalNotifications();
      await _plugin.cancel(incomingCallNotificationId);
    } catch (e) {
      debugPrint('Could not clear call notification: $e');
    }
  }

  /// Posts the one notification a chat is allowed to have.
  ///
  /// Deliberately private and deliberately narrow: callers choose a fixed
  /// phrase, never free text. That is what keeps message content out of the
  /// notification shade no matter which code path raises the alert.
  Future<void> _showChatAlert({
    required int conversationId,
    required String title,
    required String body,
  }) async {
    await _ensureLocalNotifications();
    // The launcher badge rides on this notification's number, so there is no
    // second "N unread messages" notification competing with it.
    final badge = _badgeCount;
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
          // One shared group so several chats bundle under a single header,
          // the way WhatsApp stacks its chats.
          groupKey: _groupKey,
          number: badge > 0 ? badge : null,
        ),
      ),
      payload: '$conversationId',
    );
  }

  /// Alerts that a chat has a new message, without ever saying what it says.
  ///
  /// There is no parameter for the text on purpose. The body is always the
  /// fixed phrase "New message": message content never leaves the chat screen,
  /// so a notification cannot leak it on a lock screen or in a screenshot.
  Future<void> showIncomingMessage({
    required int conversationId,
    required String title,
  }) => _showChatAlert(
    conversationId: conversationId,
    title: title,
    body: 'New message',
  );

  /// Alerts that someone sent a nudge. [action] is one of the app's own fixed
  /// phrases ("waved at you"), never anything a person typed.
  Future<void> showNudge({
    required int conversationId,
    required String title,
    String action = 'nudged you',
  }) => _showChatAlert(
    conversationId: conversationId,
    title: title,
    body: action,
  );

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

  /// Takes down chat alerts for conversations that have nothing unread left.
  ///
  /// Opening a chat used to be the only thing that cleared its notification, so
  /// reading on one device, marking read on resume, or catching up from the
  /// inbox all left a stale "New message" sitting in the shade. The shade is now
  /// reconciled against the unread counts the server just reported, which also
  /// clears alerts raised by the background push isolate — those were posted by
  /// a different isolate and are invisible to anything this one remembers.
  Future<void> reconcileTray(Set<int> conversationsWithUnread) async {
    try {
      await _ensureLocalNotifications();
      final active = await _plugin.getActiveNotifications();
      final stale = staleChatNotificationIds(
        active: active.map((n) => n.id).whereType<int>(),
        conversationsWithUnread: conversationsWithUnread,
      );
      for (final id in stale) {
        await _plugin.cancel(id);
      }
    } catch (e) {
      // Listing active notifications is unsupported on some Android builds;
      // an unread badge that lingers is better than a crash on refresh.
      debugPrint('Could not reconcile notifications: $e');
    }
  }

  Future<void> showFromPushData(Map<String, dynamic> data) async {
    if ('${data['type'] ?? ''}' == 'call.incoming') {
      final pending = PendingCall.fromPushData(data);
      if (pending.callId.isEmpty || pending.conversationId <= 0) return;
      await PendingCallStore.instance.save(pending);
      final prefs = await ConversationPrefsStore.load();
      if (prefs[pending.conversationId]?.muted ?? false) return;
      final title = await _callTitleFromData(data);
      await showIncomingCall(
        callId: pending.callId,
        conversationId: pending.conversationId,
        title: title,
        isVideo: pending.media == 'video',
      );
      onIncomingCallPush?.call(pending);
      return;
    }
    final cid = _conversationIdFrom(data);
    if (cid == null) return;
    final prefs = await ConversationPrefsStore.load();
    if (prefs[cid]?.muted ?? false) return;
    final sender = await notificationTitleFromData(data);
    // A nudge is an attention poke, not a message, so it says so rather than
    // the generic "New message" a real message falls back to.
    if ('${data['type'] ?? ''}' == 'chat.nudge') {
      final variant = NudgeVariant.parse(data['variant'] as String?);
      await showNudge(
        conversationId: cid,
        title: sender,
        action: '${variant.verb} you',
      );
      return;
    }
    if ('${data['type'] ?? ''}' == 'message.new') {
      onForegroundMessagePush?.call(cid);
    }
    await showIncomingMessage(conversationId: cid, title: sender);
  }

  /// Resolves the push sender through this phone's private address book.
  /// Public for a focused unit test; no UI or Firebase instance is required.
  Future<String> notificationTitleFromData(Map<String, dynamic> data) async {
    return resolveCallerDisplayName(
      username: '${data['sender_username'] ?? ''}',
      serverName: '${data['sender_name'] ?? ''}',
      fallback: 'Local Chat',
    );
  }

  /// Records the unread total for the launcher badge.
  ///
  /// This posts nothing of its own. Earlier builds raised a second, silent
  /// "N unread messages" notification for the badge, which meant one incoming
  /// message produced two entries in the shade. The count now rides as the
  /// `number` on the chat's own notification instead, so a message is always
  /// exactly one notification. Launchers that cannot read a number simply show
  /// their usual dot.
  Future<void> setAppBadgeCount(int count) async {
    _badgeCount = count < 0 ? 0 : count;
    try {
      await _ensureLocalNotifications();
      // Clear the standalone badge notification left behind by an older
      // install, otherwise it would linger forever with a stale count.
      if (!_legacyBadgeCleared) {
        _legacyBadgeCleared = true;
        await _plugin.cancel(_legacyBadgeId);
      }
    } catch (e) {
      debugPrint('Badge update skipped: $e');
    }
  }
}
