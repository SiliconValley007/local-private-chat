import 'dart:async';
import 'dart:io';

// material.dart (not widgets.dart) for ThemeMode, which lives in Material.
import 'package:flutter/material.dart';

import 'api_client.dart';
import 'errors.dart';
import 'models.dart';
import 'navigation.dart';
import 'realtime_service.dart';
import 'screens/chat_screen.dart';
import 'services/backup_service.dart';
import 'services/connectivity_service.dart';
import 'services/contacts_store.dart';
import 'services/media_store.dart';
import 'services/notification_service.dart';
import 'services/theme_store.dart';
import 'time_format.dart';

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState(this.api, {this.themeMode = ThemeMode.system})
    : realtime = RealtimeService(api),
      connectivity = ConnectivityService(baseUrlProvider: () => api.baseUrl),
      backup = BackupService(api),
      media = MediaStore(api) {
    realtime.addHandler(_onEvent);
    realtime.onAuthFailure = _onSessionRejected;
    WidgetsBinding.instance.addObserver(this);
  }

  final ApiClient api;
  final RealtimeService realtime;
  final ConnectivityService connectivity;
  final BackupService backup;

  /// Shared attachment cache, so a photo is downloaded once per device.
  final MediaStore media;
  final ContactsStore contactsStore = ContactsStore();

  /// Appearance the user picked: system, light, or dark.
  ThemeMode themeMode;

  bool ready = false;
  bool serverReachable = false;
  bool checkingConnectivity = false;
  ServerCheck? serverCheck;
  String? error;
  List<Conversation> conversations = [];
  List<ChatUser> users = [];
  List<LocalContact> localContacts = [];

  /// username -> the name you gave that person on this phone.
  Map<String, String> contactAliases = {};
  final Map<int, List<ChatMessage>> messagesByConv = {};
  final Map<int, Set<int>> typingUsers = {};
  final Map<int, bool> onlineByUser = {};

  /// Freshest "last seen" heard over the socket. More current than the value
  /// that arrived with the last inbox refresh.
  final Map<int, DateTime> lastSeenByUser = {};
  int? activeConversationId;
  Timer? _healthTimer;

  ChatUser? get me => api.currentUser;
  bool get isLoggedIn => api.token != null && api.currentUser != null;
  bool get hasServer => api.baseUrl != null && api.baseUrl!.isNotEmpty;

  /// Applies an appearance choice and remembers it for future launches.
  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == themeMode) return;
    themeMode = mode;
    notifyListeners();
    await ThemeStore.save(mode);
  }

  Future<void> bootstrap() async {
    error = null;
    await api.loadPersisted();
    contactAliases = await contactsStore.aliases();
    NotificationService.instance.onTokenRefresh = _onFcmTokenRefreshed;
    await NotificationService.instance.init(
      onOpenConversation: (id) => openConversationById(id),
    );
    await refreshConnectivity();
    _startHealthChecks();
    ready = true;
    notifyListeners();

    if (!isLoggedIn || !serverReachable) return;
    await _afterLogin();
  }

  /// Polls the server so the gate screen reacts when it comes back up. Paused
  /// while the app is in the background to spare battery and mobile data.
  void _startHealthChecks() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      refreshConnectivity();
    });
  }

  Future<void> _afterLogin() async {
    realtime.connect();
    try {
      await api.fetchMe();
      await refreshInbox();
      await refreshLocalContacts();
      await _registerFcm();
      _consumePendingOpen();
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        await logout();
      } else {
        error = e.message;
        notifyListeners();
      }
    } catch (e) {
      error = friendlyMessage(e);
      notifyListeners();
    }
  }

  Future<void> _onSessionRejected() async {
    await logout();
    error = 'Your session has expired. Please sign in again.';
    notifyListeners();
  }

  void clearError() {
    if (error == null) return;
    error = null;
    notifyListeners();
  }

  Future<void> refreshConnectivity() async {
    checkingConnectivity = true;
    notifyListeners();
    final check = await connectivity.check();
    final wasDown = !serverReachable;
    serverCheck = check;
    serverReachable = check.isReachable;
    checkingConnectivity = false;
    notifyListeners();
    if (serverReachable && wasDown && isLoggedIn) {
      await _afterLogin();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _onResumed();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // Let the socket go while the app is away. Android can freeze our
        // isolate at any moment, and a socket that looks alive to the server
        // means it skips the push notification — so nothing would be shown.
        _healthTimer?.cancel();
        realtime.disconnect();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }

  Future<void> _onResumed() async {
    _startHealthChecks();
    await refreshConnectivity();
    if (isLoggedIn && serverReachable) {
      realtime.connect();
      await refreshInbox();
    }
  }

  Future<void> _registerFcm() async {
    final token = await NotificationService.instance.fcmToken();
    if (token == null || token.isEmpty) return;
    try {
      await api.registerDeviceToken(token);
    } catch (e) {
      debugPrint('FCM register skipped: $e');
    }
  }

  /// FCM rotates tokens; a stale one on the server means no notifications.
  Future<void> _onFcmTokenRefreshed(String token) async {
    if (!isLoggedIn || !serverReachable) return;
    try {
      await api.registerDeviceToken(token);
    } catch (e) {
      debugPrint('FCM token refresh not saved: $e');
    }
  }

  Future<void> saveServerUrl(String url) async {
    await api.setBaseUrl(url.trim());
    notifyListeners();
    await refreshConnectivity();
  }

  Future<void> resetServerUrlToDefault() async {
    await api.resetServerUrlToDefault();
    notifyListeners();
    await refreshConnectivity();
  }

  Future<void> register(
    String username,
    String password,
    String displayName,
  ) async {
    error = null;
    await api.register(username, password, displayName: displayName);
    await _afterLogin();
    notifyListeners();
  }

  Future<void> login(String username, String password) async {
    error = null;
    await api.login(username, password);
    await _afterLogin();
    notifyListeners();
  }

  Future<void> logout() async {
    final token = await NotificationService.instance.fcmToken();
    if (token != null) {
      try {
        await api.unregisterDeviceToken(token);
      } catch (_) {}
    }
    realtime.disconnect();
    await api.logout();
    conversations = [];
    messagesByConv.clear();
    localContacts = [];
    notifyListeners();
  }

  Future<void> refreshInbox() async {
    conversations = await api.listConversations();
    for (final c in conversations) {
      if (c.peer != null) {
        onlineByUser[c.peer!.id] = c.peer!.isOnline;
      }
      for (final m in c.members) {
        onlineByUser[m.userId] = m.isOnline;
      }
    }
    notifyListeners();
  }

  Future<void> refreshUsers({String? q}) async {
    users = await api.listUsers(q: q);
    for (final u in users) {
      onlineByUser[u.id] = u.isOnline;
    }
    notifyListeners();
  }

  Future<void> refreshLocalContacts() async {
    localContacts = await contactsStore.list();
    contactAliases = await contactsStore.aliases();
    notifyListeners();
  }

  /// Renames a person on this phone only. Pass null or blank to go back to the
  /// name they chose for themselves.
  Future<void> renameContact(String username, String? newName) async {
    contactAliases = await contactsStore.setAlias(username, newName);
    notifyListeners();
  }

  /// The name to show for a username: your nickname if you set one, otherwise
  /// the display name that came from the server.
  String nameFor(String username, String serverName) {
    final alias = contactAliases[username];
    if (alias != null && alias.isNotEmpty) return alias;
    return serverName.isEmpty ? username : serverName;
  }

  /// True when this person is showing under a name you picked.
  bool hasCustomName(String? username) =>
      username != null && (contactAliases[username]?.isNotEmpty ?? false);

  /// Conversation heading, honouring any nickname for the other person.
  String titleFor(Conversation conv) {
    if (conv.type == 'dm') {
      final peer = conv.peer;
      if (peer != null) return nameFor(peer.username, peer.displayName);
      return conv.displayTitle;
    }
    return conv.displayTitle;
  }

  /// Sender name inside a group bubble or the member list.
  String nameForMember(ConversationMember member) =>
      nameFor(member.username, member.displayName);

  Future<void> saveLocalContact(ChatUser user) async {
    await contactsStore.upsert(
      LocalContact(
        userId: user.id,
        username: user.username,
        displayName: user.displayName,
      ),
    );
    await refreshLocalContacts();
  }

  Future<ChatUser> resolveUsername(String username) async {
    final user = await api.getUserByUsername(username);
    await saveLocalContact(user);
    return user;
  }

  Future<Conversation> openDm(int userId) async {
    final conv = await api.createDm(userId);
    await refreshInbox();
    return conversations.firstWhere((c) => c.id == conv.id, orElse: () => conv);
  }

  Future<Conversation> openDmWithUser(ChatUser user) async {
    await saveLocalContact(user);
    return openDm(user.id);
  }

  Future<Conversation> createGroup(String title, List<int> memberIds) async {
    final conv = await api.createGroup(title, memberIds);
    await refreshInbox();
    return conversations.firstWhere((c) => c.id == conv.id, orElse: () => conv);
  }

  Future<void> loadMessages(int conversationId, {bool initial = false}) async {
    final list = await api.listMessages(conversationId);
    messagesByConv[conversationId] = list;
    if (initial || activeConversationId == conversationId) {
      await api.markRead(conversationId);
      await refreshInbox();
    }
    notifyListeners();
  }

  Future<void> loadOlder(int conversationId) async {
    final current = messagesByConv[conversationId];
    if (current == null || current.isEmpty) return;
    final oldestId = current.first.id;
    if (oldestId <= 0) return;
    final older = await api.listMessages(conversationId, beforeId: oldestId);
    if (older.isEmpty) return;
    messagesByConv[conversationId] = [...older, ...current];
    notifyListeners();
  }

  /// Sends a text message, optionally quoting [replyTo].
  ///
  /// The message is added to the transcript before the request goes out, so the
  /// chat shows it — quote included — without waiting for the server.
  Future<void> sendText(
    int conversationId,
    String text, {
    ChatMessage? replyTo,
  }) async {
    final clientId = DateTime.now().microsecondsSinceEpoch.toString();
    final meId = me!.id;
    final optimistic = ChatMessage(
      id: -DateTime.now().millisecondsSinceEpoch,
      conversationId: conversationId,
      senderId: meId,
      type: 'text',
      body: text,
      clientId: clientId,
      createdAt: DateTime.now().toUtc(),
      replyTo: replyTo == null ? null : QuotedMessage.fromMessage(replyTo),
      pending: true,
    );
    messagesByConv.putIfAbsent(conversationId, () => []);
    messagesByConv[conversationId] = [
      ...messagesByConv[conversationId]!,
      optimistic,
    ];
    notifyListeners();
    try {
      final msg = await api.sendText(
        conversationId,
        text,
        clientId: clientId,
        replyToMessageId: replyTo?.id,
      );
      _upsertMessage(msg);
      await refreshInbox();
    } catch (e) {
      error = friendlyMessage(e);
      notifyListeners();
      rethrow;
    }
  }

  Future<ChatMessage> uploadFile({
    required int conversationId,
    required File file,
    required String type,
    String? caption,
    ChatMessage? replyTo,
  }) async {
    final msg = await api.uploadMedia(
      conversationId: conversationId,
      file: file,
      type: type,
      caption: caption,
      replyToMessageId: replyTo?.id,
    );
    _upsertMessage(msg);
    await refreshInbox();
    return msg;
  }

  void setActiveConversation(int? id) {
    activeConversationId = id;
    if (id != null) {
      // Reading the chat is the same signal WhatsApp uses: once you are looking
      // at it, its notification has served its purpose.
      NotificationService.instance.clearConversation(id);
    }
  }

  void setTyping(int conversationId, bool isTyping) {
    realtime.sendTyping(conversationId, isTyping);
  }

  Future<void> openConversationById(int conversationId) async {
    pendingOpenConversationId = conversationId;
    if (!isLoggedIn || !serverReachable) return;
    Conversation? conv;
    try {
      await refreshInbox();
      conv = conversations.cast<Conversation?>().firstWhere(
        (c) => c?.id == conversationId,
        orElse: () => null,
      );
    } catch (_) {}
    if (conv == null) return;
    pendingOpenConversationId = null;
    final nav = appNavigatorKey.currentState;
    if (nav == null) return;
    nav.push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            ChatScreen(conversation: conv!),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  void _consumePendingOpen() {
    final id = pendingOpenConversationId;
    if (id != null) {
      Future.microtask(() => openConversationById(id));
    }
  }

  Future<void> prefetchAllMessagesForBackup() async {
    for (final c in conversations) {
      try {
        await loadMessages(c.id);
      } catch (_) {}
    }
  }

  Future<Map<String, dynamic>> applyRestoredBackup(
    Map<String, dynamic> data,
  ) async {
    var contactsRestored = 0;
    final rawContacts = data['local_contacts'] as List<dynamic>? ?? [];
    for (final raw in rawContacts) {
      final c = LocalContact.fromJson(raw as Map<String, dynamic>);
      await contactsStore.upsert(c);
      contactsRestored++;
    }

    final rawAliases = data['contact_aliases'] as Map<String, dynamic>? ?? {};
    var aliasesRestored = 0;
    if (rawAliases.isNotEmpty) {
      final incoming = <String, String>{};
      for (final entry in rawAliases.entries) {
        final name = '${entry.value}'.trim();
        if (name.isNotEmpty) incoming[entry.key] = name;
      }
      contactAliases = await contactsStore.mergeAliases(incoming);
      aliasesRestored = incoming.length;
    }
    await refreshLocalContacts();

    final rawMessages = data['messages'] as List<dynamic>? ?? [];
    final byConv = <int, List<ChatMessage>>{};
    for (final raw in rawMessages) {
      final m = raw as Map<String, dynamic>;
      final msg = ChatMessage(
        id: m['id'] as int,
        conversationId: m['conversation_id'] as int,
        senderId: m['sender_id'] as int,
        type: m['type'] as String? ?? 'text',
        body: m['body'] as String?,
        mediaName: m['media_name'] as String?,
        createdAt:
            tryParseServerTime(m['created_at'] as String?) ??
            DateTime.now().toUtc(),
      );
      byConv.putIfAbsent(msg.conversationId, () => []).add(msg);
    }
    for (final entry in byConv.entries) {
      entry.value.sort((a, b) => a.id.compareTo(b.id));
      messagesByConv[entry.key] = entry.value;
    }

    var dmsOpened = 0;
    final convs = data['conversations'] as List<dynamic>? ?? [];
    if (serverReachable && isLoggedIn) {
      for (final raw in convs) {
        final c = raw as Map<String, dynamic>;
        final peer = c['peer'] as Map<String, dynamic>?;
        final username = peer?['username'] as String?;
        if (username == null) continue;
        try {
          final user = await api.getUserByUsername(username);
          await saveLocalContact(user);
          await openDm(user.id);
          dmsOpened++;
        } catch (_) {}
      }
      await refreshInbox();
    }

    notifyListeners();
    return {
      'contacts': contactsRestored,
      'messages': rawMessages.length,
      'dms': dmsOpened,
      'names': aliasesRestored,
    };
  }

  void _upsertMessage(ChatMessage msg) {
    final list = List<ChatMessage>.from(
      messagesByConv[msg.conversationId] ?? [],
    );
    final byClient = msg.clientId == null
        ? -1
        : list.indexWhere((m) => m.clientId == msg.clientId);
    if (byClient >= 0) {
      list[byClient] = msg;
    } else {
      final byId = list.indexWhere((m) => m.id == msg.id);
      if (byId >= 0) {
        list[byId] = msg;
      } else {
        list.add(msg);
      }
    }
    list.sort((a, b) => a.id.compareTo(b.id));
    messagesByConv[msg.conversationId] = list;
    notifyListeners();
  }

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    switch (type) {
      case 'message.new':
        final msg = ChatMessage.fromJson(
          event['message'] as Map<String, dynamic>,
        );
        _upsertMessage(msg);
        if (msg.senderId != me?.id) {
          realtime.ackDelivered(msg.id);
          api.markDelivered(msg.id);
          if (activeConversationId == msg.conversationId) {
            api.markRead(msg.conversationId);
          } else {
            final title =
                _titleForConversation(msg.conversationId) ?? 'New message';
            NotificationService.instance.showIncomingMessage(
              conversationId: msg.conversationId,
              title: title,
              body: messagePreview(msg),
            );
          }
        }
        refreshInbox();
        break;
      case 'receipt.delivered':
      case 'receipt.read':
        _applyReceipt(event, type == 'receipt.read');
        break;
      case 'typing':
        final cid = event['conversation_id'] as int;
        final uid = event['user_id'] as int;
        final isTyping = event['is_typing'] as bool? ?? false;
        final set = typingUsers.putIfAbsent(cid, () => <int>{});
        if (isTyping) {
          set.add(uid);
        } else {
          set.remove(uid);
        }
        notifyListeners();
        break;
      case 'presence':
        final uid = event['user_id'] as int;
        onlineByUser[uid] = event['online'] as bool? ?? false;
        final seen = tryParseServerTime(event['last_seen_at'] as String?);
        if (seen != null) lastSeenByUser[uid] = seen;
        notifyListeners();
        break;
      case 'conversation.updated':
        refreshInbox();
        break;
    }
  }

  /// One-line summary of a message, for the inbox and local notifications.
  static String messagePreview(ChatMessage msg) {
    switch (msg.type) {
      case 'image':
        final caption = msg.body?.trim() ?? '';
        return caption.isEmpty ? 'Photo' : 'Photo · $caption';
      case 'voice':
        return 'Voice message';
      case 'file':
        return msg.mediaName?.trim().isNotEmpty == true
            ? msg.mediaName!.trim()
            : 'File';
      default:
        final text = msg.body?.trim() ?? '';
        return text.isEmpty ? 'New message' : text;
    }
  }

  String? _titleForConversation(int conversationId) {
    for (final c in conversations) {
      if (c.id == conversationId) return titleFor(c);
    }
    return null;
  }

  void _applyReceipt(Map<String, dynamic> event, bool read) {
    final messageId = event['message_id'] as int;
    final conversationId = event['conversation_id'] as int;
    final userId = event['user_id'] as int;
    final at = tryParseServerTime(event['at'] as String?);
    final list = messagesByConv[conversationId];
    if (list == null) return;
    final idx = list.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    final msg = list[idx];
    final receipts = List<Receipt>.from(msg.receipts);
    final rIdx = receipts.indexWhere((r) => r.userId == userId);
    if (rIdx < 0) {
      receipts.add(
        Receipt(userId: userId, deliveredAt: at, readAt: read ? at : null),
      );
    } else {
      final r = receipts[rIdx];
      receipts[rIdx] = Receipt(
        userId: userId,
        deliveredAt: r.deliveredAt ?? at,
        readAt: read ? (at ?? r.readAt) : r.readAt,
      );
    }
    list[idx] = msg.copyWith(receipts: receipts);
    messagesByConv[conversationId] = list;
    notifyListeners();
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    realtime.disconnect();
    super.dispose();
  }
}
