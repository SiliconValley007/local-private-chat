import 'dart:async';
import 'dart:io';

// material.dart (not widgets.dart) for ThemeMode, which lives in Material.
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'api_client.dart';
import 'app_config.dart';
import 'chat_navigation.dart';
import 'doodle_stroke.dart';
import 'errors.dart';
import 'media_review.dart';
import 'message_merge.dart';
import 'message_preview.dart';
import 'models.dart';
import 'navigation.dart';
import 'nudge_log.dart';
import 'realtime_service.dart';
import 'screens/call_screen.dart';
import 'services/backup_service.dart';
import 'services/call_service.dart';
import 'services/connectivity_service.dart';
import 'services/contacts_store.dart';
import 'services/conversation_prefs_store.dart';
import 'services/e2e_service.dart';
import 'services/incoming_share_service.dart';
import 'services/media_prefs_store.dart';
import 'services/media_store.dart';
import 'services/notification_service.dart';
import 'services/pending_call_store.dart';
import 'services/tailscale_assist.dart';
import 'services/tailscale_prefs_store.dart';
import 'services/theme_store.dart';
import 'services/video_thumbnail_service.dart';
import 'time_format.dart';

/// Formats typing indicator copy for DM/group chats.
///
/// Empty [typerNames] yields null. DMs and single typers use "typing…";
/// groups with multiple typers name them.
String? formatTypingLabel({
  required bool isGroup,
  required List<String> typerNames,
}) {
  if (typerNames.isEmpty) return null;
  if (!isGroup || typerNames.length == 1) return 'typing…';
  if (typerNames.length == 2) {
    return '${typerNames[0]} and ${typerNames[1]} are typing…';
  }
  return '${typerNames[0]} and ${typerNames.length - 1} others are typing…';
}

/// Fixed height ratio for chat image bubbles so async decode does not grow
/// the list and yank the bottom anchor upward.
const double chatImageHeightRatio = 0.72;

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState(
    this.api, {
    this.themeMode = ThemeMode.system,
    TailscaleAssist? tailscale,
    IncomingShareService? incomingShares,
    E2EService? e2e,
  }) : e2e = e2e ?? E2EService(),
       realtime = RealtimeService(api),
       connectivity = ConnectivityService(baseUrlProvider: () => api.baseUrl),
       backup = BackupService(api),
       media = MediaStore(api),
       incomingShares = incomingShares ?? IncomingShareService(),
       tailscale = tailscale ?? TailscaleAssist() {
    calls = CallService(api, realtime)..bind();
    calls.peerNameFor = (cid) => _titleForConversation(cid) ?? 'Incoming call';
    calls.resolveCallerName = (username, displayName) =>
        nameFor(username, displayName);
    calls.isConversationMuted = (cid) => conversationPrefs[cid]?.muted ?? false;
    calls.onIncoming = (session) {
      unawaited(_presentIncomingCall(session));
    };
    calls.onIncomingEnded = (_) {
      unawaited(NotificationService.instance.cancelIncomingCall());
      unawaited(PendingCallStore.instance.clear());
    };
    calls.addListener(notifyListeners);
    realtime.addHandler(_onEvent);
    realtime.onAuthFailure = _onSessionRejected;
    realtime.onConnectionChanged = _onRealtimeConnectionChanged;
    WidgetsBinding.instance.addObserver(this);
  }

  final ApiClient api;
  final RealtimeService realtime;
  final ConnectivityService connectivity;
  final BackupService backup;
  final TailscaleAssist tailscale;

  /// Shares and `localchat://` links handed over by Android.
  final IncomingShareService incomingShares;
  late final CallService calls;

  /// Shared attachment cache, so a photo is downloaded once per device.
  final MediaStore media;
  final ContactsStore contactsStore = ContactsStore();

  /// End-to-end encryption for DMs (auto key exchange, transparent to the UI).
  final E2EService e2e;

  /// DM conversations we've already sent a handshake into this session, so the
  /// key swap fires once per open rather than on every inbox refresh.
  final Set<int> _handshakeSent = {};

  /// conversationId -> decrypted preview of its last DM message, for the inbox.
  final Map<int, String> _dmPreview = {};

  /// Appearance the user picked: system, light, or dark.
  ThemeMode themeMode;

  bool ready = false;
  bool serverReachable = false;
  bool checkingConnectivity = false;

  /// True while the gate screen is actively asking Tailscale to connect.
  bool connectingTailscale = false;

  /// True while the link is still expected to come up on its own, so the gate
  /// shows "connecting" instead of guessing at a reason.
  bool settling = false;

  /// This phone's rules for driving the Tailscale app.
  TailscalePrefs tailscalePrefs = const TailscalePrefs();

  /// Local media download behaviour (Wi‑Fi-only video, etc.).
  MediaPrefs mediaPrefs = const MediaPrefs();

  /// Durable phase of who may switch Tailscale off on exit (native is authority).
  TailscaleOwnershipPhase _tailscalePhase = TailscaleOwnershipPhase.unowned;

  /// When we last asked Tailscale to connect — mirrored from native when present.
  DateTime? _connectRequestedAt;

  /// Set when the user disconnects Tailscale from inside the app. Without it the
  /// health poll would reconnect within seconds and the tap would do nothing.
  bool _autoConnectPaused = false;

  /// Whether the previous check could actually route through Tailscale.
  ///
  /// Interface presence alone is not enough: Android exposes the 100.x address
  /// before the VPN can carry traffic, which used to consume the transition
  /// that proves Local Chat raised the tunnel.
  bool? _lastTunnelRouting;

  int _healthTicks = 0;
  bool _checkInFlight = false;

  /// How long [TailscaleOwnershipPhase.pendingConnect] may wait before routing
  /// that appears is treated as someone else's tunnel.
  static const _connectClaimWindow = TailscaleAssist.connectClaimWindow;

  /// Live WebSocket link to the server (false while reconnecting).
  bool realtimeConnected = false;

  /// Whether the inbox should warn about the dropped socket.
  ///
  /// Separate from [realtimeConnected] so a routine reconnect — including the
  /// one on every cold start and resume — never flashes a warning at someone
  /// whose chat is working fine.
  bool showReconnecting = false;
  Timer? _reconnectNotice;
  ServerCheck? serverCheck;
  String? error;
  List<Conversation> conversations = [];
  List<ChatUser> users = [];
  List<LocalContact> localContacts = [];

  /// username -> the name you gave that person on this phone.
  Map<String, String> contactAliases = {};

  /// conversationId -> pin/mute prefs for this phone only.
  Map<int, ConversationPrefs> conversationPrefs = {};
  final Map<int, List<ChatMessage>> messagesByConv = {};

  /// Sticky-pinned messages per conversation (Telegram-style banner).
  final Map<int, List<ChatMessage>> pinsByConv = {};

  /// Message ids this account has starred (private bookmarks).
  final Set<int> starredIds = {};

  /// Newest-starred-first list backing the starred-messages screen.
  final List<ChatMessage> starredMessages = [];
  bool starredLoading = false;
  bool starredLoadingMore = false;
  String? starredError;
  bool starredHasMore = true;

  /// Nudge history for the screen currently open (newest first).
  final List<NudgeRecord> nudgeHistory = [];
  int? nudgeHistoryConversationId;
  bool nudgeHistoryLoading = false;
  bool nudgeHistoryLoadingMore = false;
  String? nudgeHistoryError;
  bool nudgeHistoryHasMore = true;

  /// Live nudge rows per conversation (newest first) for quick lookup.
  final Map<int, List<NudgeRecord>> nudgesByConv = {};

  /// conversationId -> userIds currently typing.
  ///
  /// Auto-expires so a dropped socket cannot leave "typing…" forever.
  final Map<int, Map<int, Timer>> _typingExpiry = {};

  /// conversationId -> userId -> how far that person has read and been delivered.
  ///
  /// Receipts are monotonic inside a chat: reading a message means everything
  /// sent before it has been seen too. Holding the high-water mark separately
  /// from the messages makes the ticks survive the two races that used to leave
  /// an older bubble on one tick while newer ones showed two: a `receipt.read`
  /// frame that lands before the message it refers to exists locally, and a
  /// server copy of a message replacing a bubble whose receipt we already knew.
  final Map<int, Map<int, ReceiptWatermark>> receiptMarks = {};
  final Map<int, Set<int>> typingUsers = {};
  final Map<int, bool> onlineByUser = {};

  /// Freshest "last seen" heard over the socket. More current than the value
  /// that arrived with the last inbox refresh.
  final Map<int, DateTime> lastSeenByUser = {};

  /// userId -> avatar cache-busting version. A present entry means the user has
  /// a picture; the value changes whenever they replace it, which busts the
  /// image cache. Absence means no picture (fall back to initials).
  final Map<int, int> avatarVersionByUser = {};

  /// Last time we sent a nudge into a conversation, so the UI can hold the same
  /// 5s cooldown the server enforces and not fire haptics that go nowhere.
  final Map<int, DateTime> _lastNudgeSentAt = {};
  static const nudgeCooldown = Duration(seconds: 5);

  /// Incoming nudges. The active chat screen listens to raise a wave + haptic;
  /// broadcast so opening a second screen never steals the subscription.
  final _nudges = StreamController<NudgeEvent>.broadcast();
  Stream<NudgeEvent> get nudges => _nudges.stream;

  /// Ephemeral doodle relay frames for the active chat overlay.
  final _doodleRelay = StreamController<DoodleRelayUpdate>.broadcast();
  Stream<DoodleRelayUpdate> get doodleRelay => _doodleRelay.stream;

  int? activeConversationId;
  Timer? _healthTimer;

  ChatUser? get me => api.currentUser;
  bool get isLoggedIn => api.token != null && api.currentUser != null;
  bool get hasServer => api.baseUrl != null && api.baseUrl!.isNotEmpty;

  int get totalUnread => conversations.fold(0, (sum, c) => sum + c.unreadCount);

  /// How long the socket may be down before the inbox says anything about it.
  static const _reconnectGrace = Duration(seconds: 6);

  void _onRealtimeConnectionChanged(bool connected) {
    realtimeConnected = connected;
    _reconnectNotice?.cancel();
    if (connected) {
      showReconnecting = false;
      final active = activeConversationId;
      if (active != null && isLoggedIn) {
        unawaited(syncConversation(active, markRead: true));
      }
    } else {
      clearAllTyping();
      _reconnectNotice = Timer(_reconnectGrace, () {
        if (realtimeConnected || !isLoggedIn) return;
        showReconnecting = true;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  /// Remember (or forget) a user's avatar so every avatar on screen can show it.
  void _rememberAvatar(int userId, {required bool hasAvatar, int? version}) {
    if (hasAvatar) {
      avatarVersionByUser[userId] = version ?? 0;
    } else {
      avatarVersionByUser.remove(userId);
    }
  }

  /// Profile-picture URL for a user, or null when they have none. Callers pair
  /// this with [ApiClient.imageAuthHeaders] on the Avatar widget.
  String? avatarUrlFor(int? userId) {
    if (userId == null) return null;
    final version = avatarVersionByUser[userId];
    if (version == null) return null;
    return api.avatarUrl(userId, version: version);
  }

  bool isPinned(int conversationId) =>
      conversationPrefs[conversationId]?.pinned ?? false;

  bool isMuted(int conversationId) =>
      conversationPrefs[conversationId]?.muted ?? false;

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
    await e2e.init();
    contactAliases = await contactsStore.aliases();
    conversationPrefs = await ConversationPrefsStore.load();
    tailscalePrefs = await TailscalePrefsStore.load();
    mediaPrefs = await MediaPrefsStore.load();
    await _restoreTailscaleSessionFromNative();
    NotificationService.instance.onTokenRefresh = _onFcmTokenRefreshed;
    NotificationService.instance.onForegroundMessagePush = (conversationId) {
      unawaited(
        syncConversation(
          conversationId,
          markRead: activeConversationId == conversationId,
        ),
      );
    };
    NotificationService.instance.onIncomingCallPush = (pending) {
      unawaited(openPendingCall(pending));
    };
    await NotificationService.instance.init(
      onOpenConversation: (id) => openConversationById(id),
      onOpenCall: (pending) => openPendingCall(pending),
    );
    await _startIncomingShares();
    // Check before nudging: when the tunnel is already up this both skips a
    // pointless broadcast and records that someone else switched Tailscale on,
    // so closing the app must not take their tunnel down.
    await refreshConnectivity(nudgeTailscale: false, quick: true);
    _startHealthChecks();
    ready = true;
    notifyListeners();

    if (!serverReachable) {
      // Never awaited: the gate shows a calm "connecting" state meanwhile, and
      // _afterLogin runs from refreshConnectivity the moment the link appears.
      unawaited(settleConnection());
      return;
    }
    if (!isLoggedIn) return;
    await _afterLogin();
  }

  /// Polls the server so the gate screen reacts when it comes back up.
  ///
  /// Deliberately faster while the link is down — a 12s wait after Tailscale
  /// connects felt like the app had not noticed. Paused while the app is in the
  /// background to spare battery and mobile data.
  void _startHealthChecks() {
    _healthTimer?.cancel();
    _healthTicks = 0;
    _healthTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _healthTicks++;
      if (serverReachable && _healthTicks % 4 != 0) return;
      refreshConnectivity();
    });
  }

  bool get _autoConnectAllowed =>
      tailscalePrefs.autoConnect && !_autoConnectPaused;

  Future<bool> _nudgeTailscale({bool force = false}) async {
    if (!_autoConnectAllowed && !force) return false;
    final sent = await tailscale.nudgeIfNeeded(
      serverUrl: api.baseUrl,
      lastCheck: serverCheck,
      force: force,
    );
    if (sent) {
      await _syncTailscalePhaseFromNative();
    }
    return sent;
  }

  /// Loads native ownership, retries an interrupted owned disconnect, and syncs
  /// the exit rule without discarding a durable [owned] claim from a prior run.
  Future<void> _restoreTailscaleSessionFromNative() async {
    _lastTunnelRouting = null;
    await tailscale.retryInterruptedDisconnect();
    await _syncTailscalePhaseFromNative();
    await tailscale.setExitPolicy(
      enabled: tailscalePrefs.autoDisconnectOnExit,
      phase: _tailscalePhase,
    );
  }

  Future<void> _syncTailscalePhaseFromNative() async {
    final snap = await tailscale.readOwnershipSnapshot();
    _tailscalePhase = snap.phase;
    _connectRequestedAt = snap.connectRequestedAt;
    await TailscalePrefsStore.savePhase(_tailscalePhase);
  }

  Future<void> _applyTailscalePhase(TailscaleOwnershipPhase phase) async {
    if (_tailscalePhase == phase &&
        phase != TailscaleOwnershipPhase.pendingConnect) {
      return;
    }
    _tailscalePhase = phase;
    if (phase != TailscaleOwnershipPhase.pendingConnect) {
      if (phase != TailscaleOwnershipPhase.owned) {
        _connectRequestedAt = null;
      }
    }
    notifyListeners();
    await TailscalePrefsStore.savePhase(phase);
    await tailscale.setExitPolicy(
      enabled: tailscalePrefs.autoDisconnectOnExit,
      phase: phase,
    );
    if (phase == TailscaleOwnershipPhase.owned) {
      await tailscale.markOwnedNative();
    } else if (phase == TailscaleOwnershipPhase.unowned) {
      await tailscale.releaseOwnershipNative(reason: 'phase-unowned');
    }
  }

  /// Keeps polling briefly after a connect request, so the gate never blames
  /// the wrong thing while the tunnel is still coming up.
  ///
  /// A VPN interface can exist a second before it actually routes, which is
  /// exactly when a health check fails and the old code declared "server is not
  /// running". [settling] keeps the UI honest for that window.
  Future<void> settleConnection({
    Duration budget = const Duration(seconds: 14),
  }) async {
    if (serverReachable || settling) return;
    // Nothing is coming up on its own if we are not allowed to ask, so show the
    // real reason immediately instead of a hopeful spinner.
    if (!_autoConnectAllowed) return;
    settling = true;
    notifyListeners();
    final deadline = DateTime.now().add(budget);
    try {
      await _nudgeTailscale();
      while (!serverReachable && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        // Cheap probes here: this loop only needs to spot the moment the tunnel
        // starts routing, and a slow path gets a full hearing below.
        await refreshConnectivity(nudgeTailscale: false, quick: true);
      }
      // Do not append another 20-second multi-probe after this bounded loop.
      // The background health timer will continue patient checks if needed.
    } finally {
      settling = false;
      notifyListeners();
    }
  }

  Future<void> _afterLogin() async {
    realtime.connect();
    try {
      await api.fetchMe();
      await refreshInbox();
      await refreshLocalContacts();
      await refreshStarred();
      await _registerFcm();
      _consumePendingOpen();
      _consumePendingCall();
      unawaited(calls.recoverPendingCalls());
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

  /// Re-checks the server.
  ///
  /// [quick] takes a single short probe, for the polling that runs while a
  /// tunnel is still coming up: it notices success fast and costs almost
  /// nothing. Everything else uses the careful multi-attempt check, so a
  /// failure is only ever reported once repeated probes agree on it.
  Future<void> refreshConnectivity({
    bool nudgeTailscale = true,
    bool quick = false,
  }) async {
    if (nudgeTailscale && !serverReachable) {
      await _nudgeTailscale();
    }
    if (_checkInFlight) return; // Timer ticks must not stack up on each other.
    _checkInFlight = true;
    checkingConnectivity = true;
    notifyListeners();
    final ServerCheck check;
    try {
      check = quick
          ? await connectivity.check(
              timeout: const Duration(seconds: 3),
              attempts: 1,
            )
          : await connectivity.check();
    } finally {
      _checkInFlight = false;
    }
    final wasDown = !serverReachable;
    serverCheck = check;
    serverReachable = check.isReachable;
    checkingConnectivity = false;
    _updateTailscaleOwnership(check);
    notifyListeners();
    if (serverReachable && wasDown && isLoggedIn) {
      await _afterLogin();
    }
  }

  /// Re-reads who owns the tunnel from what this check actually observed.
  ///
  /// Doing it here, on evidence, is what stops a stale claim from surviving: an
  /// in-app disconnect, or the user turning Tailscale off, releases ownership on
  /// the very next check, so whatever they connect afterwards stays theirs.
  void _updateTailscaleOwnership(ServerCheck check) {
    final routingUp = TailscaleAssist.tunnelRoutingIsUp(check);
    final next = TailscaleAssist.transitionOnConnectivityCheck(
      phase: _tailscalePhase,
      check: check,
      previousRouting: _lastTunnelRouting,
      connectRequestedAt: _connectRequestedAt,
      now: DateTime.now(),
      claimWindow: _connectClaimWindow,
    );
    _lastTunnelRouting = routingUp;
    if (next == TailscaleOwnershipPhase.owned) {
      _connectRequestedAt = null;
    }
    if (next != _tailscalePhase) {
      unawaited(_applyTailscalePhase(next));
    } else if (_tailscalePhase == TailscaleOwnershipPhase.pendingConnect) {
      // Native may have persisted connect time while Dart was stale.
      unawaited(_syncTailscalePhaseFromNative());
    }
  }

  /// Gate-screen action: send CONNECT_VPN and poll until the server answers.
  Future<bool> connectTailscaleAndWait() async {
    connectingTailscale = true;
    // An explicit tap is also the way back from an in-app disconnect.
    _autoConnectPaused = false;
    notifyListeners();
    try {
      final installed = await tailscale.isInstalled();
      if (!installed) return false;
      final sent = await tailscale.requestConnect(
        force: true,
        lastCheck: serverCheck,
      );
      if (sent) await _syncTailscalePhaseFromNative();
      // A second nudge helps when the first landed while the receiver was waking.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await tailscale.requestConnect(force: true, lastCheck: serverCheck);
      await _syncTailscalePhaseFromNative();
      for (var i = 0; i < 15; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await refreshConnectivity(nudgeTailscale: false, quick: true);
        if (serverReachable) return true;
      }
      return false;
    } finally {
      connectingTailscale = false;
      notifyListeners();
    }
  }

  Future<bool> openTailscaleApp() => tailscale.openApp();

  /// True when Local Chat is what switched the tunnel on, so closing the app is
  /// allowed to switch it back off. Surfaced in settings because the rule is
  /// otherwise invisible when nothing happens on exit.
  bool get tailscaleStartedByApp => _tailscalePhase.isOwned;

  /// True while an in-app disconnect is holding auto-connect back.
  bool get tailscaleAutoConnectPaused => _autoConnectPaused;

  /// Settings action: drop the tunnel now and hand ownership back.
  ///
  /// Auto-connect is paused for the rest of this session, because the health
  /// poll would otherwise ask Tailscale to reconnect a couple of seconds later
  /// and the tap would appear to do nothing at all.
  Future<bool> disconnectTailscaleNow() async {
    _autoConnectPaused = true;
    _connectRequestedAt = null;
    final sent = await tailscale.requestDisconnect();
    await _applyTailscalePhase(TailscaleOwnershipPhase.unowned);
    await refreshConnectivity(nudgeTailscale: false, quick: true);
    return sent;
  }

  /// Applies and persists the Tailscale automation switches.
  Future<void> setTailscalePrefs(TailscalePrefs value) async {
    // Turning auto-connect back on is an explicit request for it to work again.
    if (value.autoConnect && !tailscalePrefs.autoConnect) {
      _autoConnectPaused = false;
    }
    tailscalePrefs = value;
    notifyListeners();
    await TailscalePrefsStore.save(value);
    await tailscale.setExitPolicy(
      enabled: value.autoDisconnectOnExit,
      phase: _tailscalePhase,
    );
  }

  /// Applies and persists local media download prefs.
  Future<void> setMediaPrefs(MediaPrefs value) async {
    mediaPrefs = value;
    notifyListeners();
    await MediaPrefsStore.save(value);
  }

  /// Whether a video download should proceed under the Wi‑Fi-only preference.
  Future<bool> allowVideoDownload({bool userConfirmed = false}) async {
    if (!mediaPrefs.wifiOnlyVideoDownload || userConfirmed) return true;
    return connectivity.looksLikeWifiOrLan();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _onResumed();
        unawaited(calls.syncActiveCallAudio());
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(calls.onAppLifecycleBackground());
        // Let the socket go while the app is away. Android can freeze our
        // isolate at any moment, and a socket that looks alive to the server
        // means it skips the push notification — so nothing would be shown.
        _healthTimer?.cancel();
        realtime.disconnect();
        // This drop is deliberate, so it must not leave a warning waiting to
        // appear on the next resume.
        _reconnectNotice?.cancel();
        showReconnecting = false;
        if (state == AppLifecycleState.detached) _onDetached();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }

  Future<void> _onResumed() async {
    _startHealthChecks();
    // Notification taps and returning from Tailscale both land here.
    await refreshConnectivity(nudgeTailscale: false, quick: true);
    if (!serverReachable) {
      unawaited(settleConnection());
      return;
    }
    if (isLoggedIn) {
      realtime.connect();
      await refreshInbox();
      final active = activeConversationId;
      if (active != null) {
        unawaited(syncConversation(active, markRead: true));
      }
      unawaited(calls.recoverPendingCalls());
      _consumePendingCall();
    }
  }

  /// Best-effort tunnel shutdown on the way out.
  ///
  /// Android usually kills the isolate before this finishes, which is why the
  /// native side holds the same rule and sends the broadcast on task removal.
  void _onDetached() {
    if (!TailscaleAssist.shouldDisconnectOnExit(
      enabled: tailscalePrefs.autoDisconnectOnExit,
      phase: _tailscalePhase,
    )) {
      return;
    }
    // Native keeps [owned] until disconnect succeeds so a kill mid-flight retries.
    unawaited(tailscale.requestDisconnect(force: false));
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

  /// Change the signed-in account password (requires the current password).
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await api.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
  }

  Future<void> logout() async {
    final token = await NotificationService.instance.fcmToken();
    if (token != null) {
      try {
        await api.unregisterDeviceToken(token);
      } catch (_) {}
    }
    realtime.disconnect();
    _reconnectNotice?.cancel();
    showReconnecting = false;
    await api.logout();
    conversations = [];
    messagesByConv.clear();
    pinsByConv.clear();
    localContacts = [];
    notifyListeners();
  }

  /// In-flight inbox fetch, so overlapping callers share one request.
  Future<void>? _inboxFetch;

  /// Set when a refresh was asked for while one was already running, so a
  /// single catch-up pass runs afterwards.
  bool _inboxRefetchWanted = false;

  /// Reloads the inbox, collapsing a burst of requests into one fetch.
  ///
  /// A busy moment asks for this several times over: the arriving message, its
  /// receipt, and the reply being sent each used to pull the whole inbox again.
  /// Overlapping requests now share one response, with at most one extra pass
  /// afterwards for anything that changed meanwhile. Nothing is missed, and a
  /// weak connection carries a fraction of the traffic.
  Future<void> refreshInbox() {
    final running = _inboxFetch;
    if (running != null) {
      _inboxRefetchWanted = true;
      return running;
    }
    final fetch = _refreshInboxOnce().whenComplete(() {
      _inboxFetch = null;
      if (!_inboxRefetchWanted) return;
      _inboxRefetchWanted = false;
      // Not awaited: the caller has already been served by the pass that just
      // finished, and this one only catches up on what changed during it. A
      // failure here is no worse than a slightly stale inbox, which the next
      // event or the health poll will correct.
      unawaited(refreshInbox().catchError((_) {}));
    });
    _inboxFetch = fetch;
    return fetch;
  }

  Future<void> _refreshInboxOnce() async {
    final list = await api.listConversations();
    list.sort((a, b) {
      final ap = isPinned(a.id) ? 1 : 0;
      final bp = isPinned(b.id) ? 1 : 0;
      if (ap != bp) return bp.compareTo(ap);
      return b.updatedAt.compareTo(a.updatedAt);
    });
    conversations = list;
    for (final c in conversations) {
      if (c.peer != null) {
        onlineByUser[c.peer!.id] = c.peer!.isOnline;
        _rememberAvatar(
          c.peer!.id,
          hasAvatar: c.peer!.hasAvatar,
          version: c.peer!.avatarVersion,
        );
      }
      for (final m in c.members) {
        onlineByUser[m.userId] = m.isOnline;
        _rememberAvatar(
          m.userId,
          hasAvatar: m.hasAvatar,
          version: m.avatarVersion,
        );
      }
    }
    _rememberSelfAvatar();
    // Decrypt each DM's last-message preview for the inbox. The server only has
    // the ciphertext token; the plaintext lives only on this phone.
    for (final c in conversations) {
      final body = c.lastMessage?.body;
      if (c.type == 'dm' && E2EService.isCipherText(body)) {
        final peerId = c.peer?.id;
        if (peerId != null) {
          final clear = await e2e.decryptFrom(peerId, body);
          if (clear != null) {
            _dmPreview[c.id] = clear;
          } else {
            _dmPreview.remove(c.id);
          }
        }
      } else {
        _dmPreview.remove(c.id);
      }
    }
    notifyListeners();
    await NotificationService.instance.setAppBadgeCount(totalUnread);
  }

  /// The inbox subtitle for a chat, with DM last messages decrypted and a
  /// "You:" prefix for your own. Falls back to a locked note if a token can't
  /// be read yet (keys still being exchanged).
  String previewFor(Conversation conv) {
    final last = conv.lastMessage;
    if (last == null) return 'No messages yet';
    String summary;
    if (E2EService.isCipherText(last.body)) {
      final clear = _dmPreview[conv.id];
      summary = clear != null
          ? chatMessagePreview(last.copyWith(body: clear), viewerUserId: me?.id)
          : '\u{1F512} Encrypted message';
    } else {
      summary = chatMessagePreview(last, viewerUserId: me?.id);
    }
    final fromMe = last.senderId == me?.id;
    return fromMe ? 'You: $summary' : summary;
  }

  Future<void> togglePin(int conversationId) async {
    final current =
        conversationPrefs[conversationId] ?? const ConversationPrefs();
    conversationPrefs = {
      ...conversationPrefs,
      conversationId: current.copyWith(pinned: !current.pinned),
    };
    await ConversationPrefsStore.save(conversationPrefs);
    await refreshInbox();
  }

  Future<void> toggleMute(int conversationId) async {
    final current =
        conversationPrefs[conversationId] ?? const ConversationPrefs();
    conversationPrefs = {
      ...conversationPrefs,
      conversationId: current.copyWith(muted: !current.muted),
    };
    await ConversationPrefsStore.save(conversationPrefs);
    notifyListeners();
  }

  /// The conversation in the inbox list, or null if it isn't loaded.
  Conversation? conversationById(int conversationId) {
    for (final c in conversations) {
      if (c.id == conversationId) return c;
    }
    return null;
  }

  /// Replaces one conversation in the inbox with a fresher copy (e.g. after a
  /// wallpaper or disappearing change) and re-sorts so pins stay on top.
  void _replaceConversation(Conversation updated) {
    final idx = conversations.indexWhere((c) => c.id == updated.id);
    if (idx < 0) {
      conversations = [...conversations, updated];
    } else {
      final next = [...conversations];
      next[idx] = updated;
      conversations = next;
    }
    conversations.sort((a, b) {
      final ap = isPinned(a.id) ? 1 : 0;
      final bp = isPinned(b.id) ? 1 : 0;
      if (ap != bp) return bp.compareTo(ap);
      return b.updatedAt.compareTo(a.updatedAt);
    });
    notifyListeners();
  }

  /// The shared wallpaper's authenticated URL for a chat, or null when none is
  /// set. The URL is cache-busted by the server-side version so a wallpaper any
  /// member changes is refetched on every phone.
  String? wallpaperUrlFor(int conversationId) {
    final conv = conversationById(conversationId);
    if (conv == null || !conv.hasWallpaper) return null;
    return api.wallpaperUrl(conversationId, version: conv.wallpaperVersion);
  }

  /// How much to darken the wallpaper behind messages (0 when none is set).
  double wallpaperDimFor(int conversationId) =>
      conversationById(conversationId)?.wallpaperDim ?? 0.25;

  /// Uploads a shared wallpaper for the chat. Everyone in it sees the new image
  /// on their next inbox refresh (pushed immediately over the socket).
  Future<void> setChatWallpaper(int conversationId, File image) async {
    final updated = await api.uploadWallpaper(conversationId, image);
    _replaceConversation(updated);
  }

  /// Adjusts the shared darkening of a chat's wallpaper.
  Future<void> setChatWallpaperDim(int conversationId, double dim) async {
    final updated = await api.setWallpaperDim(conversationId, dim);
    _replaceConversation(updated);
  }

  /// Removes the chat's shared wallpaper for everyone.
  Future<void> clearChatWallpaper(int conversationId) async {
    final updated = await api.deleteWallpaper(conversationId);
    _replaceConversation(updated);
  }

  /// Sets the disappearing-message timer for a chat; null turns it off.
  Future<void> setDisappearing(int conversationId, int? seconds) async {
    final updated = await api.setDisappearing(conversationId, seconds);
    _replaceConversation(updated);
  }

  /// Sets a DM's anniversary date (`YYYY-MM-DD`); null clears it.
  Future<void> setAnniversary(int conversationId, String? isoDate) async {
    final updated = await api.setAnniversary(conversationId, isoDate);
    _replaceConversation(updated);
  }

  /// Updates the signed-in user's private mood (shown only to DM partners).
  Future<void> setMyMood(String? mood) async {
    await api.setMood(mood);
    notifyListeners();
  }

  /// Updates the display name everyone on the server sees for you.
  Future<void> setMyDisplayName(String displayName) async {
    final updated = await api.setDisplayName(displayName);
    api.currentUser = updated;
    notifyListeners();
    await refreshInbox();
  }

  /// Receipt ticks for the inbox preview of [conv], or null when not applicable.
  ///
  /// Merges the server's cold-start level with fresher websocket watermarks and
  /// any loaded transcript row for the same message id.
  int? inboxReceiptLevelFor(Conversation conv) {
    final meId = me?.id;
    if (meId == null) return null;

    final local = messagesByConv[conv.id];
    if (local != null && local.isNotEmpty) {
      final pendingLast = local.last;
      if (pendingLast.pending && pendingLast.senderId == meId) {
        return -1;
      }
    }

    final last = conv.lastMessage;
    if (last == null || last.senderId != meId) return null;

    final transcript = local?.where((m) => m.id == last.id).firstOrNull;
    if (transcript != null) {
      if (transcript.pending) return -1;
      return transcript.receiptLevel();
    }

    final marks = receiptMarks[conv.id];
    if (marks != null && marks.isNotEmpty) {
      final merged = _withReceiptMarks(last, marks, isDm: conv.type == 'dm');
      if (merged != null) return merged.receiptLevel();

      final recipients = conv.type == 'dm'
          ? {if (conv.peer != null) conv.peer!.id}
          : conv.members.map((m) => m.userId).where((id) => id != meId).toSet();
      final fromMarks = _inboxLevelFromMarks(last, marks, recipients);
      if (fromMarks != null) {
        final server = last.serverReceiptLevel ?? 0;
        return fromMarks > server ? fromMarks : server;
      }
    }

    return last.serverReceiptLevel ?? 0;
  }

  /// Adds, changes, or clears your emoji reaction on a message.
  ///
  /// Tapping the emoji you already used removes it; any other emoji replaces it.
  Future<void> toggleReaction(ChatMessage message, String emoji) async {
    final mine = message.reactions
        .where((r) => r.reactedByMe)
        .map((r) => r.emoji)
        .toList();
    final ChatMessage updated;
    if (mine.contains(emoji)) {
      updated = await api.removeReaction(message.id);
    } else {
      updated = await api.reactToMessage(message.id, emoji);
    }
    await upsertFromWire(updated);
  }

  Future<void> refreshUsers({String? q}) async {
    users = await api.listUsers(q: q);
    for (final u in users) {
      onlineByUser[u.id] = u.isOnline;
      _rememberAvatar(u.id, hasAvatar: u.hasAvatar, version: u.avatarVersion);
    }
    notifyListeners();
  }

  /// Updates peer rows after a profile broadcast.
  void _patchUserInConversations(ChatUser user) {
    conversations = conversations.map((c) {
      final peerMatch = c.peer?.id == user.id;
      final memberMatch = c.members.any((m) => m.userId == user.id);
      if (!peerMatch && !memberMatch) return c;

      final peer = peerMatch ? user : c.peer;
      final members = c.members.map((m) {
        if (m.userId != user.id) return m;
        return ConversationMember(
          userId: m.userId,
          username: user.username,
          displayName: user.displayName,
          role: m.role,
          isOnline: user.isOnline,
          hasAvatar: user.hasAvatar,
          avatarVersion: user.avatarVersion,
        );
      }).toList();

      return Conversation(
        id: c.id,
        type: c.type,
        title: c.type == 'dm' && peer != null ? user.displayName : c.title,
        peer: peer,
        lastMessage: c.lastMessage,
        unreadCount: c.unreadCount,
        updatedAt: c.updatedAt,
        members: members,
        wallpaperVersion: c.wallpaperVersion,
        wallpaperDim: c.wallpaperDim,
        hasWallpaper: c.hasWallpaper,
        disappearAfterSeconds: c.disappearAfterSeconds,
        anniversaryOn: c.anniversaryOn,
        streakDays: c.streakDays,
      );
    }).toList();
  }

  /// Mirror the signed-in user's own avatar into the shared map.
  void _rememberSelfAvatar() {
    final self = me;
    if (self == null) return;
    _rememberAvatar(
      self.id,
      hasAvatar: self.hasAvatar,
      version: self.avatarVersion,
    );
  }

  /// Sets or replaces the signed-in user's profile picture from a local file.
  Future<void> setMyAvatar(File file) async {
    final updated = await api.uploadAvatar(file);
    _rememberAvatar(
      updated.id,
      hasAvatar: updated.hasAvatar,
      version: updated.avatarVersion,
    );
    notifyListeners();
  }

  /// Removes the signed-in user's profile picture.
  Future<void> removeMyAvatar() async {
    final updated = await api.deleteAvatar();
    _rememberAvatar(updated.id, hasAvatar: false);
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

  /// Per-conversation sync generation so stale HTTP responses cannot win.
  final Map<int, int> _syncGeneration = {};
  final Map<int, Future<void>> _syncInFlight = {};
  final Map<int, int> _parseResyncCounts = {};
  static const _maxParseResyncs = 2;

  /// Reconciles the on-device transcript with the server without clobbering
  /// optimistic rows or websocket updates that arrived mid-flight.
  Future<void> syncConversation(
    int conversationId, {
    bool full = false,
    bool markRead = false,
  }) async {
    final generation =
        (_syncGeneration[conversationId] = (_syncGeneration[conversationId] ?? 0) + 1);

    while (true) {
      final inFlight = _syncInFlight[conversationId];
      if (inFlight != null) {
        await inFlight;
        if (_syncGeneration[conversationId] != generation) {
          return syncConversation(
            conversationId,
            full: full,
            markRead: markRead,
          );
        }
      }

      final job = _runSyncConversation(
        conversationId,
        generation,
        full: full,
        markRead: markRead,
      );
      _syncInFlight[conversationId] = job;
      try {
        await job;
      } finally {
        if (_syncInFlight[conversationId] == job) {
          _syncInFlight.remove(conversationId);
        }
      }

      if (_syncGeneration[conversationId] == generation) {
        _parseResyncCounts.remove(conversationId);
        return;
      }
      return syncConversation(
        conversationId,
        full: full,
        markRead: markRead,
      );
    }
  }

  Future<void> _runSyncConversation(
    int conversationId,
    int generation, {
    required bool full,
    required bool markRead,
  }) async {
    final local = List<ChatMessage>.from(
      messagesByConv[conversationId] ?? const [],
    );
    final watermark = full ? null : maxServerMessageId(local);
    final page = watermark == null
        ? await api.listMessages(conversationId)
        : await api.listMessages(conversationId, afterId: watermark);

    if (_syncGeneration[conversationId] != generation) return;

    final incoming = await _decryptList(page);
    if (_syncGeneration[conversationId] != generation) return;

    messagesByConv[conversationId] = mergeConversationMessages(
      local: local,
      incoming: incoming,
    );
    _learnReceiptMarks(conversationId, incoming);
    applyReceiptMarks(conversationId);
    ensureE2eHandshake(conversationId);

    final shouldRead =
        markRead ||
        (activeConversationId == conversationId &&
            incoming.any((m) => m.senderId != me?.id));
    if (shouldRead) {
      await api.markRead(conversationId);
      await refreshInbox();
    } else {
      notifyListeners();
    }
  }

  Future<void> loadMessages(int conversationId, {bool initial = false}) async {
    if (initial) _historyComplete.remove(conversationId);
    await syncConversation(
      conversationId,
      full: true,
      markRead: initial || activeConversationId == conversationId,
    );
    await refreshPins(conversationId);
  }

  Future<void> refreshPins(int conversationId) async {
    try {
      pinsByConv[conversationId] = await _decryptList(
        await api.listPins(conversationId),
      );
      notifyListeners();
    } catch (_) {
      // Pin banner is best-effort; chat still works without it.
    }
  }

  bool isMessagePinned(int conversationId, int messageId) {
    final pins = pinsByConv[conversationId];
    if (pins == null) return false;
    return pins.any((m) => m.id == messageId);
  }

  Future<void> pinMessage(ChatMessage message) async {
    await api.pinMessage(message.id);
    await refreshPins(message.conversationId);
  }

  Future<void> unpinMessage(ChatMessage message) async {
    await api.unpinMessage(message.id);
    await refreshPins(message.conversationId);
  }

  Future<void> refreshStarred() async {
    try {
      final list = await _decryptList(await api.listStarred(limit: 100));
      starredIds.addAll(list.map((m) => m.id));
      _reconcileStarredMessages(list, pageSize: 100);
      notifyListeners();
    } catch (_) {
      // Starred list is best-effort; chat still works without it.
    }
  }

  /// Loads or refreshes the starred-messages screen from the server.
  Future<void> refreshStarredList() async {
    starredLoading = true;
    starredError = null;
    notifyListeners();
    try {
      final list = await _decryptList(await api.listStarred(limit: 50));
      starredIds
        ..clear()
        ..addAll(list.map((m) => m.id));
      starredMessages
        ..clear()
        ..addAll(list);
      starredHasMore = list.length >= 50;
      starredLoading = false;
      notifyListeners();
    } catch (e) {
      starredLoading = false;
      starredError = friendlyMessage(e);
      notifyListeners();
    }
  }

  Future<void> loadMoreStarred() async {
    if (starredLoadingMore || starredMessages.isEmpty || !starredHasMore) {
      return;
    }
    starredLoadingMore = true;
    notifyListeners();
    try {
      final before = starredMessages.last.starId;
      final page = await _decryptList(
        await api.listStarred(beforeStarId: before),
      );
      starredMessages.addAll(page);
      starredIds.addAll(page.map((m) => m.id));
      starredHasMore = page.length >= 50;
    } catch (e) {
      starredError = friendlyMessage(e);
    } finally {
      starredLoadingMore = false;
      notifyListeners();
    }
  }

  Future<void> refreshNudgeHistory(int conversationId) async {
    nudgeHistoryConversationId = conversationId;
    nudgeHistoryLoading = true;
    nudgeHistoryError = null;
    notifyListeners();
    try {
      final list = await api.listNudges(conversationId);
      nudgeHistory
        ..clear()
        ..addAll(list);
      nudgeHistoryHasMore = list.length >= 50;
      _mergeNudgePage(conversationId, list);
      nudgeHistoryLoading = false;
      notifyListeners();
    } catch (e) {
      nudgeHistoryLoading = false;
      nudgeHistoryError = friendlyMessage(e);
      notifyListeners();
    }
  }

  Future<void> loadMoreNudgeHistory() async {
    final convId = nudgeHistoryConversationId;
    if (convId == null ||
        nudgeHistoryLoadingMore ||
        nudgeHistory.isEmpty ||
        !nudgeHistoryHasMore) {
      return;
    }
    nudgeHistoryLoadingMore = true;
    notifyListeners();
    try {
      final tail = nudgeHistory.last;
      final page = await api.listNudges(
        convId,
        before: tail.at.toUtc().toIso8601String(),
        beforeId: tail.nudgeId,
      );
      nudgeHistory.addAll(page);
      nudgeHistoryHasMore = page.length >= 50;
      _mergeNudgePage(convId, page);
    } catch (e) {
      nudgeHistoryError = friendlyMessage(e);
    } finally {
      nudgeHistoryLoadingMore = false;
      notifyListeners();
    }
  }

  void _mergeNudgePage(int conversationId, List<NudgeRecord> page) {
    if (page.isEmpty) return;
    final existing = nudgesByConv.putIfAbsent(conversationId, () => []);
    for (final row in page) {
      final idx = existing.indexWhere((n) => n.nudgeId == row.nudgeId);
      if (idx >= 0) {
        existing[idx] = row.copyWith(pending: false);
      } else {
        existing.add(row);
      }
    }
    existing.sort((a, b) {
      final byTime = b.at.compareTo(a.at);
      if (byTime != 0) return byTime;
      return b.nudgeId.compareTo(a.nudgeId);
    });
  }

  void _upsertNudgeRecord(NudgeRecord record) {
    final list = nudgesByConv.putIfAbsent(record.conversationId, () => []);
    final idx = list.indexWhere((n) => n.nudgeId == record.nudgeId);
    if (idx >= 0) {
      list[idx] = record;
    } else {
      list.insert(0, record);
    }
    if (nudgeHistoryConversationId == record.conversationId) {
      final hIdx = nudgeHistory.indexWhere((n) => n.nudgeId == record.nudgeId);
      if (hIdx >= 0) {
        nudgeHistory[hIdx] = record;
      } else {
        nudgeHistory.insert(0, record);
      }
      nudgeHistory.sort((a, b) {
        final byTime = b.at.compareTo(a.at);
        if (byTime != 0) return byTime;
        return b.nudgeId.compareTo(a.nudgeId);
      });
    }
  }

  Conversation? _conversationById(int conversationId) {
    for (final c in conversations) {
      if (c.id == conversationId) return c;
    }
    return null;
  }

  String nudgeCaptionFor(NudgeRecord record) => formatNudgeOverlayCaption(
        record: record,
        viewerUserId: me?.id,
        conversation: _conversationById(record.conversationId),
        nameFor: nameFor,
        nameForMember: nameForMember,
      );

  @visibleForTesting
  void reconcileNudgesForTest(int conversationId, List<NudgeRecord> page) {
    _mergeNudgePage(conversationId, page);
    notifyListeners();
  }

  @visibleForTesting
  void upsertNudgeForTest(NudgeRecord record) {
    _upsertNudgeRecord(record);
    notifyListeners();
  }

  @visibleForTesting
  void reconcileSentNudgeForTest(NudgeRecord record) {
    _reconcileSentNudge(record);
    notifyListeners();
  }

  @visibleForTesting
  void handleIncomingNudgeForTest(Map<String, dynamic> event) {
    _handleIncomingNudge(event);
  }

  @visibleForTesting
  void Function(NudgeRecord record)? onSentNudgeOptimistic;

  @visibleForTesting
  void Function(NudgeRecord record, {required bool isEcho})?
      onIncomingNudgeHandled;

  @visibleForTesting
  void resetNudgeHistoryForTest() {
    nudgeHistory.clear();
    nudgeHistoryConversationId = null;
    nudgeHistoryLoading = false;
    nudgeHistoryLoadingMore = false;
    nudgeHistoryError = null;
    nudgeHistoryHasMore = true;
    nudgesByConv.clear();
    onSentNudgeOptimistic = null;
    onIncomingNudgeHandled = null;
  }

  @visibleForTesting
  void reconcileStarredMessagesForTest(
    List<ChatMessage> serverPage, {
    required int pageSize,
  }) {
    _reconcileStarredMessages(serverPage, pageSize: pageSize);
  }

  void _reconcileStarredMessages(
    List<ChatMessage> serverPage, {
    required int pageSize,
  }) {
    if (starredMessages.isEmpty) {
      starredMessages
        ..clear()
        ..addAll(serverPage);
      starredHasMore = serverPage.length >= pageSize;
      return;
    }
    final byId = {for (final m in serverPage) m.id: m};
    starredMessages.removeWhere((m) => !starredIds.contains(m.id));
    for (var i = 0; i < starredMessages.length; i++) {
      final updated = byId[starredMessages[i].id];
      if (updated != null) starredMessages[i] = updated;
    }
    for (final m in serverPage) {
      if (!starredMessages.any((existing) => existing.id == m.id)) {
        starredMessages.add(m);
      }
    }
    starredMessages.sort((a, b) {
      final aStar = a.starId ?? 0;
      final bStar = b.starId ?? 0;
      return bStar.compareTo(aStar);
    });
    starredHasMore = serverPage.length >= pageSize;
  }

  bool isMessageStarred(int messageId) => starredIds.contains(messageId);

  Future<void> starMessage(ChatMessage message) async {
    final wasStarred = starredIds.contains(message.id);
    if (!wasStarred) {
      starredIds.add(message.id);
      starredMessages.removeWhere((m) => m.id == message.id);
      starredMessages.insert(0, message);
      notifyListeners();
    }
    try {
      final starred = await _decryptMessage(await api.starMessage(message.id));
      starredIds.add(starred.id);
      final index = starredMessages.indexWhere((m) => m.id == starred.id);
      if (index >= 0) {
        starredMessages[index] = starred;
      } else {
        starredMessages.insert(0, starred);
      }
      notifyListeners();
    } catch (e) {
      if (!wasStarred) {
        starredIds.remove(message.id);
        starredMessages.removeWhere((m) => m.id == message.id);
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> unstarMessage(ChatMessage message) async {
    final wasStarred = starredIds.contains(message.id);
    final snapshot = wasStarred
        ? starredMessages.where((m) => m.id == message.id).toList()
        : const <ChatMessage>[];
    starredIds.remove(message.id);
    starredMessages.removeWhere((m) => m.id == message.id);
    notifyListeners();
    try {
      await api.unstarMessage(message.id);
    } catch (e) {
      if (wasStarred) {
        starredIds.add(message.id);
        if (snapshot.isNotEmpty) {
          starredMessages.insert(0, snapshot.first);
        } else {
          starredMessages.insert(0, message);
        }
        notifyListeners();
      }
      rethrow;
    }
  }

  /// Conversations with a page request in flight, and those whose history has
  /// already been read to the end.
  ///
  /// Scrolling fires many notifications while the oldest message is on screen,
  /// and each one used to start its own request for the same page.
  final Set<int> _loadingOlder = {};
  final Set<int> _historyComplete = {};

  bool historyIsComplete(int conversationId) =>
      _historyComplete.contains(conversationId);

  Future<void> loadOlder(int conversationId) async {
    final current = messagesByConv[conversationId];
    if (current == null || current.isEmpty) return;
    if (_historyComplete.contains(conversationId)) return;
    if (!_loadingOlder.add(conversationId)) return;
    try {
      final oldestId = current.first.id;
      if (oldestId <= 0) return;
      final older = await _decryptList(
        await api.listMessages(conversationId, beforeId: oldestId),
      );
      if (older.isEmpty) {
        _historyComplete.add(conversationId);
        return;
      }
      messagesByConv[conversationId] = mergeConversationMessages(
        local: current,
        incoming: older,
      );
      notifyListeners();
    } finally {
      _loadingOlder.remove(conversationId);
    }
  }

  /// Paginate until [messageId] is in the local transcript, or history ends.
  Future<bool> ensureMessageLoaded(int conversationId, int messageId) async {
    for (var attempt = 0; attempt < 40; attempt++) {
      final messages = messagesByConv[conversationId] ?? const <ChatMessage>[];
      if (messages.any((m) => m.id == messageId)) return true;
      if (messages.isEmpty) {
        await loadMessages(conversationId, initial: true);
        continue;
      }
      final before = messages.length;
      await loadOlder(conversationId);
      final after = (messagesByConv[conversationId] ?? const []).length;
      if (after == before) return false;
    }
    return false;
  }

  Future<List<SharedItem>> listShared(
    int conversationId, {
    int? beforeId,
  }) async {
    return api.listShared(conversationId, beforeId: beforeId);
  }

  Future<List<ChatMessage>> searchMessages(
    String query, {
    int? conversationId,
    int? senderId,
    String? mediaType,
    DateTime? before,
    DateTime? after,
  }) async {
    // A DM's bodies are ciphertext on the server, so the server can't match
    // them. Search the decrypted transcript this phone already holds instead.
    if (conversationId != null && _dmPeerId(conversationId) != null) {
      return _localSearch(
        conversationId,
        query,
        senderId: senderId,
        mediaType: mediaType,
        before: before,
        after: after,
      );
    }
    // Global search: merge server hits for groups with local E2E DM transcripts.
    if (conversationId == null) {
      final server = await api.searchMessages(
        query,
        senderId: senderId,
        mediaType: mediaType,
        before: before,
        after: after,
      );
      final local = <ChatMessage>[];
      for (final conv in conversations) {
        if (conv.type != 'dm') continue;
        local.addAll(
          _localSearch(
            conv.id,
            query,
            senderId: senderId,
            mediaType: mediaType,
            before: before,
            after: after,
          ),
        );
      }
      final byId = <int, ChatMessage>{
        for (final m in [...server, ...local]) m.id: m,
      };
      final merged = byId.values.toList()..sort((a, b) => b.id.compareTo(a.id));
      return merged;
    }
    return api.searchMessages(
      query,
      conversationId: conversationId,
      senderId: senderId,
      mediaType: mediaType,
      before: before,
      after: after,
    );
  }

  List<ChatMessage> _localSearch(
    int conversationId,
    String query, {
    int? senderId,
    String? mediaType,
    DateTime? before,
    DateTime? after,
  }) {
    final needle = query.trim().toLowerCase();
    final kind = mediaType?.trim().toLowerCase();
    final local = messagesByConv[conversationId] ?? const <ChatMessage>[];
    return local.where((m) {
      if (m.isDeleted) return false;
      if (senderId != null && m.senderId != senderId) return false;
      if (before != null && !m.createdAt.isBefore(before)) return false;
      if (after != null && !m.createdAt.isAfter(after)) return false;
      if (kind == null || kind == 'text') {
        if (kind == 'text' && m.type != 'text') return false;
        if (kind == null && m.type != 'text') return false;
        if (needle.isEmpty) return kind == 'text';
        return (m.body ?? '').toLowerCase().contains(needle);
      }
      if (kind == 'link') {
        if (m.type != 'text') return false;
        final body = m.body ?? '';
        if (!body.toLowerCase().contains('http')) return false;
        return needle.isEmpty || body.toLowerCase().contains(needle);
      }
      if (m.type != kind) return false;
      if (needle.isEmpty) return true;
      final hay = '${m.mediaName ?? ''} ${m.body ?? ''}'.toLowerCase();
      return hay.contains(needle);
    }).toList();
  }

  Future<void> editMessage(
    int conversationId,
    ChatMessage message,
    String body,
  ) async {
    // Re-seal the edited text for a DM, exactly as when first sent.
    final wire = await _wireBodyFor(conversationId, body);
    final updated = await api.editMessage(message.id, wire);
    await upsertFromWire(updated);
    await refreshInbox();
  }

  /// The body to put on the wire: an encrypted token for a DM once keys are
  /// exchanged, or the plaintext unchanged for groups / before the handshake.
  Future<String> _wireBodyFor(int conversationId, String plaintext) async {
    final peerId = _dmPeerId(conversationId);
    if (peerId == null) return plaintext;
    final sealed = await e2e.encryptFor(peerId, plaintext);
    return sealed ?? plaintext;
  }

  /// Seals a media caption for upload; groups and pre-handshake DMs stay plain.
  Future<String?> _wireCaptionFor(int conversationId, String? caption) async {
    final trimmed = caption?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    return _wireBodyFor(conversationId, trimmed);
  }

  @visibleForTesting
  Future<String?> wireCaptionFor(int conversationId, String? caption) =>
      _wireCaptionFor(conversationId, caption);

  /// Deletes a message. [scope] is `everyone` (tombstone shown to all) or `me`
  /// (removed from this account's view only).
  Future<void> deleteMessage(
    int conversationId,
    ChatMessage message, {
    String scope = 'everyone',
  }) async {
    final updated = await api.deleteMessage(message.id, scope: scope);
    if (scope == 'me') {
      // Hidden for this account only: drop it from the local transcript. The
      // server already excludes it from future fetches.
      final list = messagesByConv[conversationId];
      if (list != null) {
        messagesByConv[conversationId] = list
            .where((m) => m.id != message.id)
            .toList();
        notifyListeners();
      }
    } else {
      await media.evict(message.id);
      await upsertFromWire(updated);
    }
    await refreshInbox();
  }

  Future<List<OwnedMedia>> listMyMedia() => api.listMyMedia();

  Future<MediaCleanupResult> deleteMyMedia(Iterable<int> messageIds) async {
    final ids = messageIds.toSet();
    final result = await api.deleteMyMedia(ids);
    for (final id in ids) {
      await media.evict(id);
    }
    await refreshInbox();
    return result;
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
      // The wire carries ciphertext for a DM; the local echo below is decrypted
      // back to [text] so the sender keeps reading plain text.
      final wire = await _wireBodyFor(conversationId, text);
      final msg = await api.sendText(
        conversationId,
        wire,
        clientId: clientId,
        replyToMessageId: replyTo?.id,
      );
      await upsertFromWire(msg);
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
    final preview = await _previewFor(file, type);
    final wireCaption = await _wireCaptionFor(conversationId, caption);
    late final ChatMessage msg;
    try {
      msg = await api.uploadMedia(
        conversationId: conversationId,
        file: file,
        type: type,
        thumbnail: preview.file,
        durationMs: preview.durationMs,
        caption: wireCaption,
        replyToMessageId: replyTo?.id,
      );
    } finally {
      await _removeGeneratedThumbnail(preview.file);
    }
    await upsertFromWire(msg);
    await refreshInbox();
    return msg;
  }

  /// Max attachments in one send, matching WhatsApp's album cap. Beyond this the
  /// UI trims the selection and tells the user.
  static const maxAttachmentsPerSend = 50;

  static const _imageExtensions = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'heic',
    'heif',
    'bmp',
  };

  static const _videoExtensions = {
    'mp4',
    'mov',
    'm4v',
    '3gp',
    'mkv',
    'webm',
    'avi',
  };

  /// Whether a picked file travels as a photo, a video, or a plain document.
  ///
  /// The kind decides how the other side renders it, so a video picked from the
  /// gallery becomes a playable clip rather than a file card to download.
  static String attachmentTypeFor(String path) {
    final dot = path.lastIndexOf('.');
    if (dot <= 0 || dot == path.length - 1) return 'file';
    final ext = path.substring(dot + 1).toLowerCase();
    if (_imageExtensions.contains(ext)) return 'image';
    if (_videoExtensions.contains(ext)) return 'video';
    return 'file';
  }

  /// How many files are left to upload in the current batch, for the progress
  /// chip in the composer. Zero means nothing is uploading.
  int mediaUploadTotal = 0;
  int mediaUploadDone = 0;

  bool get isUploadingMedia => mediaUploadTotal > 0;

  /// Uploads several attachments as an ordered album.
  ///
  /// Files go up **sequentially** so their message ids — and therefore the
  /// transcript order — match the order they were picked; a parallel burst would
  /// let faster (smaller) files overtake. Each carries a unique client id so a
  /// retry cannot duplicate it, and only the first inherits the reply, the way
  /// WhatsApp attaches a single quote to an album. One failure does not abort
  /// the rest; the user is told which count did not make it.
  ///
  /// [typeOf] lets one batch mix kinds, which is what a gallery pick of photos
  /// and videos together produces. Without it every file uses [type].
  Future<void> uploadFiles({
    required int conversationId,
    required List<File> files,
    required String type,
    String Function(File file)? typeOf,
    String? caption,
    ChatMessage? replyTo,
  }) async {
    if (files.isEmpty) return;
    mediaUploadTotal = files.length;
    mediaUploadDone = 0;
    notifyListeners();

    var failures = 0;
    try {
      for (var i = 0; i < files.length; i++) {
        final clientId = '${DateTime.now().microsecondsSinceEpoch}_$i';
        final actualType = typeOf?.call(files[i]) ?? type;
        final preview = await _previewFor(files[i], actualType);
        final wireCaption = await _wireCaptionFor(
          conversationId,
          captionForBatchIndex(index: i, caption: caption),
        );
        try {
          final msg = await api.uploadMedia(
            conversationId: conversationId,
            file: files[i],
            type: actualType,
            thumbnail: preview.file,
            durationMs: preview.durationMs,
            caption: wireCaption,
            clientId: clientId,
            replyToMessageId: i == 0 ? replyTo?.id : null,
          );
          await upsertFromWire(msg);
        } catch (_) {
          failures++;
        } finally {
          await _removeGeneratedThumbnail(preview.file);
          mediaUploadDone = i + 1;
          notifyListeners();
        }
      }
    } finally {
      mediaUploadTotal = 0;
      mediaUploadDone = 0;
      notifyListeners();
    }

    await refreshInbox();
    if (failures > 0) {
      error = failures == files.length
          ? (files.length == 1
                ? "Couldn't send that file."
                : "Couldn't send those ${files.length} files.")
          : "Couldn't send $failures of ${files.length} files.";
      notifyListeners();
    }
  }

  /// Generates one small preview frame and reads the clip length; failure never
  /// blocks the video itself.
  Future<VideoPreview> _previewFor(File file, String type) async {
    if (type != 'video') return const VideoPreview();
    try {
      return await VideoThumbnailService.create(file.path);
    } catch (e) {
      debugPrint('Video preview generation skipped: $e');
      return const VideoPreview();
    }
  }

  Future<void> _removeGeneratedThumbnail(File? thumbnail) async {
    if (thumbnail == null) return;
    try {
      if (await thumbnail.exists()) await thumbnail.delete();
    } catch (_) {
      // Temporary cache cleanup is best effort.
    }
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

  /// Short presence/typing line for an inbox row or chat header.
  ///
  /// Priority: typing → online → last seen. Mood is handled separately so it
  /// never hides whether the person is actually there.
  String? typingLabelFor(Conversation conv) {
    final ids = typingUsers[conv.id];
    if (ids == null || ids.isEmpty) return null;
    final names = <String>[];
    for (final id in ids) {
      if (id == me?.id) continue;
      names.add(_displayNameForUserId(conv, id));
    }
    return formatTypingLabel(isGroup: conv.type == 'group', typerNames: names);
  }

  String _displayNameForUserId(Conversation conv, int userId) {
    for (final m in conv.members) {
      if (m.userId == userId) return nameForMember(m);
    }
    if (conv.peer?.id == userId) {
      return nameFor(conv.peer!.username, conv.peer!.displayName);
    }
    return 'Someone';
  }

  void _setTypingUser(int conversationId, int userId, bool isTyping) {
    final set = typingUsers.putIfAbsent(conversationId, () => <int>{});
    final timers = _typingExpiry.putIfAbsent(conversationId, () => {});
    timers[userId]?.cancel();
    if (isTyping) {
      set.add(userId);
      // A quiet peer whose stop-typing frame never arrives would otherwise leave
      // the subtitle stuck. Four seconds matches common chat apps.
      timers[userId] = Timer(const Duration(seconds: 4), () {
        typingUsers[conversationId]?.remove(userId);
        notifyListeners();
      });
    } else {
      set.remove(userId);
      timers.remove(userId);
    }
    notifyListeners();
  }

  void _clearTypingForUser(int userId) {
    var changed = false;
    for (final entry in typingUsers.entries) {
      if (entry.value.remove(userId)) changed = true;
      _typingExpiry[entry.key]?[userId]?.cancel();
      _typingExpiry[entry.key]?.remove(userId);
    }
    if (changed) notifyListeners();
  }

  void clearAllTyping() {
    for (final timers in _typingExpiry.values) {
      for (final t in timers.values) {
        t.cancel();
      }
    }
    _typingExpiry.clear();
    if (typingUsers.values.any((s) => s.isNotEmpty)) {
      typingUsers.clear();
      notifyListeners();
    } else {
      typingUsers.clear();
    }
  }

  /// Sends a nudge to a conversation, throttled to the server's 5s cooldown.
  ///
  /// Returns true when the nudge actually went out, so the caller can play the
  /// local wave and haptic only when there is a real poke to show — a rapid
  /// second double-tap is swallowed here exactly as the server would drop it.
  bool sendChatNudge(int conversationId, {String variant = 'wave'}) {
    final now = DateTime.now();
    final last = _lastNudgeSentAt[conversationId];
    if (last != null && now.difference(last) < nudgeCooldown) return false;
    _lastNudgeSentAt[conversationId] = now;
    final meUser = me;
    if (meUser == null) return false;
    final nudgeId = const Uuid().v4().replaceAll('-', '');
    final optimistic = NudgeRecord(
      nudgeId: nudgeId,
      conversationId: conversationId,
      senderId: meUser.id,
      senderUsername: meUser.username,
      senderName: meUser.displayName,
      variant: variant,
      at: now.toUtc(),
      pending: true,
    );
    _upsertNudgeRecord(optimistic);
    onSentNudgeOptimistic?.call(optimistic);
    notifyListeners();
    realtime.sendNudge(
      conversationId,
      variant: variant,
      nudgeId: nudgeId,
    );
    return true;
  }

  void _reconcileSentNudge(NudgeRecord record) {
    final existingList = nudgesByConv[record.conversationId];
    final idx =
        existingList?.indexWhere((n) => n.nudgeId == record.nudgeId) ?? -1;
    final reconciled = record.copyWith(pending: false);
    if (idx >= 0 && existingList != null) {
      existingList[idx] = reconciled;
    } else {
      _upsertNudgeRecord(reconciled);
    }
    if (nudgeHistoryConversationId == record.conversationId) {
      final hIdx = nudgeHistory.indexWhere((n) => n.nudgeId == record.nudgeId);
      if (hIdx >= 0) {
        nudgeHistory[hIdx] = reconciled;
      }
    }
  }

  Future<void> openConversationById(int conversationId) async {
    pendingOpenConversationId = conversationId;
    // Notification path: the tunnel may still be coming up, and the chat should
    // open by itself once it does rather than dropping the user on the gate.
    if (!serverReachable) await settleConnection();
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
    await openChatFromRoot(
      nav,
      conversation: conv,
      activeConversationId: activeConversationId,
    );
  }

  void _consumePendingOpen() {
    final id = pendingOpenConversationId;
    if (id != null) {
      Future.microtask(() => openConversationById(id));
    }
  }

  void _consumePendingCall() {
    final callId = pendingOpenCallId;
    if (callId == null || callId.isEmpty) return;
    Future.microtask(() async {
      final stored = await PendingCallStore.instance.load();
      if (stored != null && stored.callId == callId) {
        await openPendingCall(stored);
      } else {
        pendingOpenCallId = callId;
        await calls.recoverPendingCalls();
      }
    });
  }

  Future<void> openPendingCall(PendingCall pending) async {
    pendingOpenCallId = null;
    if (calls.active?.callId == pending.callId) {
      _presentCallScreen();
      return;
    }
    if (!serverReachable) await settleConnection();
    if (!isLoggedIn || !serverReachable) {
      pendingOpenCallId = pending.callId;
      await PendingCallStore.instance.save(pending);
      return;
    }
    realtime.connect();
    final restored = await calls.restorePendingIncoming(pending);
    if (!restored) return;
    _presentCallScreen();
  }

  Future<void> _presentIncomingCall(CallSession session) async {
    if (!(conversationPrefs[session.conversationId]?.muted ?? false)) {
      await NotificationService.instance.showIncomingCall(
        callId: session.callId,
        conversationId: session.conversationId,
        title: session.peerName,
        isVideo: session.isVideo,
      );
    }
    await PendingCallStore.instance.save(
      PendingCall(
        callId: session.callId,
        conversationId: session.conversationId,
        media: session.media,
        callerId: session.peerUserId ?? 0,
        callerName: session.peerName,
        callerUsername: _peerUsernameForConversation(session.conversationId),
      ),
    );
    _presentCallScreen();
  }

  void _presentCallScreen() {
    final nav = appNavigatorKey.currentState;
    if (nav == null) return;
    unawaited(presentCallScreen(nav.context));
  }

  /// An invite tapped before this phone had an account, kept so the DM opens by
  /// itself right after the first sign-in.
  Invite? pendingInvite;

  /// A share from another app waiting for a chat to be picked.
  ///
  /// Parked on the state rather than pushed straight onto the navigator because
  /// a share can arrive while the app is still on the Tailscale gate or the
  /// sign-in screen, where there is no inbox to choose from yet.
  IncomingShare? pendingShare;

  /// Hands over the waiting share, clearing it so it cannot be sent twice.
  IncomingShare? takePendingShare() {
    final share = pendingShare;
    pendingShare = null;
    return share;
  }

  Future<void> _startIncomingShares() async {
    incomingShares.onShare = receiveShare;
    incomingShares.onLink = _handleIncomingLink;
    await incomingShares.start();
  }

  /// Queues a share from Android's share sheet for the inbox to route.
  void receiveShare(IncomingShare share) {
    if (share.isEmpty) return;
    pendingShare = share;
    notifyListeners();
  }

  void _handleIncomingLink(Uri uri) {
    final invite = AppConfig.parseInvite(uri.toString());
    if (invite == null) return;
    // A tapped link can beat the first frame, and acceptInvite needs a context
    // to ask about switching servers, so the UI picks this up when it is ready.
    pendingInvite = invite;
    notifyListeners();
  }

  /// Hands over a waiting invite, clearing it so it is offered once.
  Invite? takePendingInvite() {
    final invite = pendingInvite;
    pendingInvite = null;
    return invite;
  }

  /// Points this phone at the server named in [invite].
  ///
  /// Returns true when the address actually changed, so callers can tell the
  /// user why the app just reconnected.
  Future<bool> applyInviteServer(Invite invite) async {
    final server = invite.serverUrl;
    if (server == null || !invite.pointsElsewhere(api.baseUrl)) return false;
    await api.setBaseUrl(server);
    // The old socket points at the previous server; drop it before probing so a
    // stale connection cannot keep the UI looking healthy.
    realtime.disconnect();
    notifyListeners();
    await refreshConnectivity(quick: true);
    return true;
  }

  /// Resolves an invite into an open DM, remembering it when we cannot yet.
  ///
  /// Without an account (a brand-new phone opening a shared link) the invite is
  /// held and replayed by [_consumePendingOpen] after sign-in.
  Future<Conversation?> openDmFromInvite(Invite invite) async {
    if (!isLoggedIn) {
      pendingInvite = invite;
      notifyListeners();
      return null;
    }
    if (!serverReachable) await settleConnection();
    if (!serverReachable) {
      pendingInvite = invite;
      notifyListeners();
      return null;
    }
    try {
      final user = await resolveUsername(invite.username);
      return openDmWithUser(user);
    } on ApiException catch (e) {
      // Switching to the inviter's server invalidates the old session, so the
      // invite waits for the sign-in that follows instead of being lost.
      if (e.statusCode != 401) rethrow;
      pendingInvite = invite;
      notifyListeners();
      return null;
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

    final rawStarred = data['starred_message_ids'] as List<dynamic>? ?? [];
    var starsRestored = 0;
    if (rawStarred.isNotEmpty && serverReachable && isLoggedIn) {
      for (final raw in rawStarred) {
        final id = raw is int ? raw : int.tryParse('$raw');
        if (id == null) continue;
        try {
          await api.starMessage(id);
          starredIds.add(id);
          starsRestored++;
        } catch (_) {}
      }
      await refreshStarred();
    }

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
      'stars': starsRestored,
    };
  }

  /// The other person in a DM, or null for groups / unknown chats.
  int? _dmPeerId(int conversationId) {
    final conv = conversationById(conversationId);
    if (conv == null || conv.type != 'dm') return null;
    return conv.peer?.id;
  }

  /// Sends this device's public key into a DM so the two sides can derive a
  /// shared key. Fires once per chat per session; the peer answers with theirs.
  void _sendE2eHandshake(int conversationId, {String type = 'e2e.hello'}) {
    final peerId = _dmPeerId(conversationId);
    final pub = e2e.myPublicKeyB64;
    if (peerId == null || pub == null) return;
    realtime.sendE2eSignal({
      'type': type,
      'conversation_id': conversationId,
      'public_key': pub,
    });
  }

  /// Kicks off the key swap when a DM is opened, unless already done this run.
  void ensureE2eHandshake(int conversationId) {
    if (_dmPeerId(conversationId) == null) return;
    if (!_handshakeSent.add(conversationId)) return;
    _sendE2eHandshake(conversationId);
  }

  Future<void> _handleE2eEvent(String type, Map<String, dynamic> event) async {
    final conversationId = event['conversation_id'] as int?;
    final fromUserId = event['from_user_id'] as int?;
    if (conversationId == null || fromUserId == null) return;
    final pub = event['public_key'] as String?;
    switch (type) {
      case 'e2e.hello':
        if (pub != null) await e2e.rememberPeerKey(fromUserId, pub);
        // Answer with our key so the greeter can encrypt to us too.
        _sendE2eHandshake(conversationId, type: 'e2e.reply');
        await _redecryptConversation(conversationId);
      case 'e2e.reply':
        if (pub != null) await e2e.rememberPeerKey(fromUserId, pub);
        await _redecryptConversation(conversationId);
      case 'e2e.need_key':
        _sendE2eHandshake(conversationId, type: 'e2e.reply');
    }
  }

  /// After a key finally arrives, re-run decryption over what we already hold
  /// so any tokens shown as locked turn back into text.
  Future<void> _redecryptConversation(int conversationId) async {
    final list = messagesByConv[conversationId];
    if (list == null) return;
    final decrypted = <ChatMessage>[];
    var changed = false;
    for (final m in list) {
      final d = await _decryptMessage(m);
      if (!identical(d, m)) changed = true;
      decrypted.add(d);
    }
    if (changed) {
      messagesByConv[conversationId] = decrypted;
      notifyListeners();
    }
  }

  /// Returns a copy of [m] with its DM body (and quoted body) decrypted, or the
  /// same message when nothing needed decrypting.
  Future<ChatMessage> _decryptMessage(ChatMessage m) async {
    final peerId = _dmPeerId(m.conversationId);
    if (peerId == null) return m;
    var body = m.body;
    var reply = m.replyTo;
    if (E2EService.isCipherText(body)) {
      final clear = await e2e.decryptFrom(peerId, body);
      if (clear != null) body = clear;
    }
    if (reply != null && E2EService.isCipherText(reply.body)) {
      final clear = await e2e.decryptFrom(peerId, reply.body);
      if (clear != null) {
        reply = QuotedMessage(
          id: reply.id,
          senderId: reply.senderId,
          type: reply.type,
          body: clear,
          mediaName: reply.mediaName,
          deleted: reply.deleted,
        );
      }
    }
    if (body == m.body && identical(reply, m.replyTo)) return m;
    return m.copyWith(body: body, replyTo: reply);
  }

  /// Decrypts every message in [list] (a no-op for groups / plaintext).
  Future<List<ChatMessage>> _decryptList(List<ChatMessage> list) async {
    final out = <ChatMessage>[];
    for (final m in list) {
      out.add(await _decryptMessage(m));
    }
    return out;
  }

  /// Upserts a message that came straight off the wire.
  ///
  /// Every REST reply and socket frame carries the *stored* body, which for a DM
  /// is ciphertext. Going through here means a bubble can never end up showing
  /// its own `e2e1:…` token because a call site forgot to decrypt — reacting to
  /// a message used to do exactly that.
  @visibleForTesting
  Future<void> upsertFromWire(ChatMessage msg) async {
    _upsertMessage(await _decryptMessage(msg));
  }

  void _upsertMessage(ChatMessage msg) {
    final list = List<ChatMessage>.from(
      messagesByConv[msg.conversationId] ?? [],
    );
    // A server copy of one of our messages is authoritative about its receipts,
    // so anything it reports joins the marks before it lands. Without this, the
    // reply to our own POST would silently drop a read we already knew about.
    _learnReceiptMarks(msg.conversationId, [msg]);
    final marks = receiptMarks[msg.conversationId];
    final incoming = marks == null
        ? msg
        : (_withReceiptMarks(
                msg,
                marks,
                isDm: conversationById(msg.conversationId)?.type == 'dm',
              ) ??
              msg);

    final byClient = msg.clientId == null
        ? -1
        : list.indexWhere((m) => m.clientId == msg.clientId);
    if (byClient >= 0) {
      list[byClient] = incoming;
    } else {
      final byId = list.indexWhere((m) => m.id == incoming.id);
      if (byId >= 0) {
        list[byId] = incoming;
      } else {
        list.add(incoming);
      }
    }
    list.sort((a, b) => a.id.compareTo(b.id));
    messagesByConv[msg.conversationId] = list;
    _syncStarredEntry(incoming);
    notifyListeners();
  }

  /// Keeps the starred-messages screen in sync with transcript edits/deletes.
  void _syncStarredEntry(ChatMessage msg) {
    if (!starredIds.contains(msg.id)) return;
    final index = starredMessages.indexWhere((m) => m.id == msg.id);
    if (index >= 0) {
      starredMessages[index] = msg;
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    switch (type) {
      case 'message.new':
        unawaited(_handleIncomingMessage(event));
        break;
      case 'message.updated':
        unawaited(_handleUpdatedMessage(event));
        break;
      case 'reaction.updated':
        _applyReactionUpdate(event);
        break;
      case 'receipt.delivered':
      case 'receipt.read':
        applyReceiptEvent(event, type == 'receipt.read');
        break;
      case 'typing':
        final cid = event['conversation_id'] as int;
        final uid = event['user_id'] as int;
        final isTyping = event['is_typing'] as bool? ?? false;
        _setTypingUser(cid, uid, isTyping);
        break;
      case 'presence':
        final uid = event['user_id'] as int;
        final online = event['online'] as bool? ?? false;
        onlineByUser[uid] = online;
        final seen = tryParseServerTime(event['last_seen_at'] as String?);
        if (seen != null) lastSeenByUser[uid] = seen;
        // Going offline mid-typing must not leave a stuck indicator.
        if (!online) _clearTypingForUser(uid);
        notifyListeners();
        break;
      case 'conversation.updated':
        final cid = event['conversation_id'] as int?;
        unawaited(refreshInbox());
        if (cid != null && cid == activeConversationId) {
          unawaited(syncConversation(cid, markRead: true));
        }
        break;
      case 'pins.changed':
        final cid = event['conversation_id'] as int?;
        if (cid != null) unawaited(refreshPins(cid));
        break;
      case 'stars.changed':
        if (starredMessages.isNotEmpty) {
          unawaited(refreshStarredList());
        } else {
          unawaited(refreshStarred());
        }
        break;
      case 'user.updated':
        final u = ChatUser.fromJson(event['user'] as Map<String, dynamic>);
        onlineByUser[u.id] = u.isOnline;
        _rememberAvatar(u.id, hasAvatar: u.hasAvatar, version: u.avatarVersion);
        _patchUserInConversations(u);
        if (u.id == me?.id) {
          api.currentUser = u;
        }
        notifyListeners();
        break;
      case 'chat.nudge':
        _handleIncomingNudge(event);
        break;
      case 'chat.doodle.begin':
      case 'chat.doodle.stroke':
      case 'chat.doodle.undo':
      case 'chat.doodle.clear':
      case 'chat.doodle.end':
        _handleIncomingDoodle(event);
        break;
      case 'e2e.hello':
      case 'e2e.reply':
      case 'e2e.need_key':
        unawaited(_handleE2eEvent(type!, event));
        break;
    }
  }

  Future<void> _handleIncomingMessage(Map<String, dynamic> event) async {
    int? conversationId;
    try {
      final raw = ChatMessage.fromJson(
        event['message'] as Map<String, dynamic>,
        meId: me?.id,
      );
      conversationId = raw.conversationId;
      final msg = await _decryptMessage(raw);
      _upsertMessage(msg);
      if (msg.senderId != me?.id) {
        realtime.ackDelivered(msg.id);
        api.markDelivered(msg.id);
        if (activeConversationId == msg.conversationId) {
          api.markRead(msg.conversationId);
        } else if (!isMuted(msg.conversationId)) {
          // Only who it is from, never what it says. A socket delivery must look
          // exactly like a push one, or a message would be readable in the shade
          // whenever the app happened to be running.
          final title =
              _titleForConversation(msg.conversationId) ?? 'New message';
          NotificationService.instance.showIncomingMessage(
            conversationId: msg.conversationId,
            title: title,
          );
        }
      }
      await refreshInbox();
    } catch (e, stack) {
      debugPrint('message.new parse/decrypt failed: $e\n$stack');
      conversationId ??= (event['message'] as Map?)?['conversation_id'] as int?;
      if (conversationId != null) {
        _scheduleBoundedResync(conversationId);
      }
    }
  }

  void _scheduleBoundedResync(int conversationId) {
    final count = (_parseResyncCounts[conversationId] ?? 0) + 1;
    if (count > _maxParseResyncs) {
      debugPrint('message sync resync cap reached for conversation $conversationId');
      return;
    }
    _parseResyncCounts[conversationId] = count;
    unawaited(syncConversation(conversationId));
  }

  Future<void> _handleUpdatedMessage(Map<String, dynamic> event) async {
    final raw = ChatMessage.fromJson(
      event['message'] as Map<String, dynamic>,
      meId: me?.id,
    );
    if (raw.isDeleted) await media.evict(raw.id);
    await upsertFromWire(raw);
    await refreshInbox();
  }

  /// Applies a live reaction change to a message already in the transcript.
  void _applyReactionUpdate(Map<String, dynamic> event) {
    final messageId = event['message_id'] as int?;
    final conversationId = event['conversation_id'] as int?;
    if (messageId == null || conversationId == null) return;
    final list = messagesByConv[conversationId];
    if (list == null) return;
    final idx = list.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    final raw = event['reactions'] as List<dynamic>? ?? const [];
    final reactions = raw
        .map(
          (e) => ReactionAgg.fromJson(e as Map<String, dynamic>, meId: me?.id),
        )
        .toList();
    list[idx] = list[idx].copyWith(reactions: reactions);
    messagesByConv[conversationId] = list;
    notifyListeners();
  }

  void _handleIncomingNudge(Map<String, dynamic> event) {
    final cid = event['conversation_id'] as int?;
    final senderId = event['sender_id'] as int?;
    final nudgeId = event['nudge_id'] as String?;
    if (cid == null || senderId == null || nudgeId == null || nudgeId.isEmpty) {
      return;
    }
    final record = NudgeRecord.fromWire(event);
    final variant = NudgeVariant.parse(record.variant);
    final isOwn = senderId == me?.id;

    if (isOwn) {
      _reconcileSentNudge(record);
      onIncomingNudgeHandled?.call(record, isEcho: true);
      notifyListeners();
      return;
    }

    _upsertNudgeRecord(record);
    onIncomingNudgeHandled?.call(record, isEcho: false);
    // A physical buzz is the whole point of a nudge; the wave is for whoever is
    // looking at the chat right now. Each variant buzzes differently.
    variant.playHaptic();
    final caption = nudgeCaptionFor(record);
    _nudges.add(
      NudgeEvent(
        conversationId: cid,
        senderId: senderId,
        senderName: record.senderName,
        variant: variant,
        caption: caption,
      ),
    );
    if (activeConversationId != cid && !isMuted(cid)) {
      NotificationService.instance.showNudge(
        conversationId: cid,
        title: _titleForConversation(cid) ?? caption.split(' ').first,
        action: '${variant.verb} you',
      );
    }
    notifyListeners();
  }

  void _handleIncomingDoodle(Map<String, dynamic> event) {
    final update = parseDoodleRelay(event);
    if (update == null) return;
    if (update.fromUserId == me?.id) return;
    _doodleRelay.add(update);
  }

  /// One-line summary of a message, for the inbox and local notifications.
  static String messagePreview(ChatMessage msg) => chatMessagePreview(msg);

  String? _titleForConversation(int conversationId) {
    for (final c in conversations) {
      if (c.id == conversationId) return titleFor(c);
    }
    return null;
  }

  String _peerUsernameForConversation(int conversationId) {
    for (final c in conversations) {
      if (c.id != conversationId || c.type != 'dm') continue;
      return c.peer?.username ?? '';
    }
    return '';
  }

  void applyReceiptEvent(Map<String, dynamic> event, bool read) {
    final messageId = event['message_id'] as int;
    final conversationId = event['conversation_id'] as int;
    final userId = event['user_id'] as int;
    // A frame with an unreadable timestamp still proves the state changed, so
    // "now" stands in rather than dropping the receipt.
    final at =
        tryParseServerTime(event['at'] as String?) ?? DateTime.now().toUtc();
    rememberReceiptMark(
      conversationId: conversationId,
      userId: userId,
      messageId: messageId,
      read: read,
      at: at,
    );
    applyReceiptMarks(conversationId);
    notifyListeners();
  }

  /// Records how far [userId] has got in a conversation.
  ///
  /// Only ever moves forward: an out-of-order frame for an older message cannot
  /// pull the mark back and un-tick newer bubbles.
  void rememberReceiptMark({
    required int conversationId,
    required int userId,
    required int messageId,
    required bool read,
    required DateTime at,
  }) {
    if (messageId <= 0) return;
    final marks = receiptMarks.putIfAbsent(conversationId, () => {});
    final mark = marks.putIfAbsent(userId, ReceiptWatermark.new);
    // Read implies delivered, even if that frame never arrived.
    if (messageId > mark.deliveredUpTo) {
      mark.deliveredUpTo = messageId;
      mark.deliveredAt = mark.deliveredAt ?? at;
    }
    if (read && messageId > mark.readUpTo) {
      mark.readUpTo = messageId;
      mark.readAt = at;
    }
  }

  /// Folds a conversation's watermarks into its transcript. Returns whether any
  /// bubble changed, so callers can skip a needless rebuild.
  bool applyReceiptMarks(int conversationId) {
    final marks = receiptMarks[conversationId];
    final list = messagesByConv[conversationId];
    if (marks == null || marks.isEmpty || list == null) return false;
    final isDm = conversationById(conversationId)?.type == 'dm';
    final next = List<ChatMessage>.from(list);
    var changed = false;
    for (var i = 0; i < next.length; i++) {
      final merged = _withReceiptMarks(next[i], marks, isDm: isDm);
      if (merged != null) {
        next[i] = merged;
        changed = true;
      }
    }
    if (changed) messagesByConv[conversationId] = next;
    return changed;
  }

  /// Folds websocket watermarks into an inbox preview when the preview row
  /// carries no per-recipient receipt list (typical for group chats).
  int? _inboxLevelFromMarks(
    ChatMessage msg,
    Map<int, ReceiptWatermark> marks,
    Set<int> recipientIds,
  ) {
    if (recipientIds.isEmpty) return null;
    final delivered = <int, DateTime?>{};
    final read = <int, DateTime?>{};
    for (final uid in recipientIds) {
      final mark = marks[uid];
      if (mark == null) continue;
      if (mark.deliveredUpTo >= msg.id) {
        delivered[uid] = mark.deliveredAt;
      }
      if (mark.readUpTo >= msg.id) {
        read[uid] = mark.readAt;
      }
    }
    if (delivered.isEmpty && read.isEmpty) return null;
    if (recipientIds.every((uid) => read[uid] != null)) return 2;
    if (recipientIds.every((uid) => delivered[uid] != null)) return 1;
    if (recipientIds.any((uid) => delivered[uid] != null)) return 1;
    return 0;
  }

  /// [msg] with any receipt implied by the watermarks filled in, or null when it
  /// already says everything the marks know.
  ChatMessage? _withReceiptMarks(
    ChatMessage msg,
    Map<int, ReceiptWatermark> marks, {
    required bool isDm,
  }) {
    // Ticks belong to messages we sent and the server has accepted; a pending
    // echo carries a placeholder id that no watermark can describe.
    if (msg.id <= 0 || msg.pending || msg.senderId != me?.id) return null;

    List<Receipt>? updated;
    for (final entry in marks.entries) {
      final userId = entry.key;
      final mark = entry.value;
      final wasRead = mark.readUpTo >= msg.id;
      if (!wasRead && mark.deliveredUpTo < msg.id) continue;

      final current = updated ?? msg.receipts;
      final idx = current.indexWhere((r) => r.userId == userId);
      if (idx < 0) {
        // In a group the server's receipt list names every member, so a missing
        // row means this person is not a recipient. A DM has exactly one peer,
        // where an absent row is simply one we have not been told about yet.
        if (!isDm) continue;
        updated = [
          ...current,
          Receipt(
            userId: userId,
            deliveredAt: mark.deliveredAt ?? mark.readAt,
            readAt: wasRead ? mark.readAt : null,
          ),
        ];
        continue;
      }

      final existing = current[idx];
      final deliveredAt =
          existing.deliveredAt ?? mark.deliveredAt ?? mark.readAt;
      final readAt = existing.readAt ?? (wasRead ? mark.readAt : null);
      if (existing.deliveredAt == deliveredAt && existing.readAt == readAt) {
        continue;
      }
      final next = List<Receipt>.from(current);
      next[idx] = Receipt(
        userId: userId,
        deliveredAt: deliveredAt,
        readAt: readAt,
      );
      updated = next;
    }
    if (updated == null) return null;
    return msg.copyWith(receipts: updated);
  }

  /// Learns watermarks from a server-supplied transcript, so a receipt the
  /// socket missed still repairs every older bubble after a refresh.
  void _learnReceiptMarks(int conversationId, List<ChatMessage> list) {
    for (final msg in list) {
      if (msg.id <= 0 || msg.senderId != me?.id) continue;
      for (final r in msg.receipts) {
        if (r.deliveredAt == null && r.readAt == null) continue;
        rememberReceiptMark(
          conversationId: conversationId,
          userId: r.userId,
          messageId: msg.id,
          read: r.readAt != null,
          at: r.readAt ?? r.deliveredAt!,
        );
      }
    }
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _reconnectNotice?.cancel();
    _nudges.close();
    _doodleRelay.close();
    WidgetsBinding.instance.removeObserver(this);
    calls.dispose();
    incomingShares.dispose();
    realtime.disconnect();
    connectivity.dispose();
    super.dispose();
  }
}

/// How far one person has got in one conversation.
///
/// Ids only ever move forward, so a late or duplicated frame cannot undo a tick
/// that has already been earned.
class ReceiptWatermark {
  ReceiptWatermark();

  int deliveredUpTo = 0;
  int readUpTo = 0;
  DateTime? deliveredAt;
  DateTime? readAt;
}
