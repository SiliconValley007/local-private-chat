import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../call_log.dart';
import '../app_state.dart';
import '../chat_navigation.dart';
import '../chat_scroll.dart';
import '../couple_details.dart';
import '../doodle_stroke.dart';
import '../emoji.dart';
import '../errors.dart';
import '../models.dart';
import '../nudge_log.dart';
import '../services/export_service.dart';
import '../services/doodle_controller.dart';
import '../services/doodle_export.dart';
import '../services/media_picker_service.dart';
import 'media_review_screen.dart';
import '../services/reaction_freq_store.dart';
import '../services/voice_player.dart';
import '../services/draft_store.dart';
import '../theme.dart';
import '../time_format.dart';
import '../widgets/animated_emoji.dart';
import '../widgets/attachments.dart';
import '../widgets/avatar.dart';
import '../widgets/avatar_viewer.dart';
import '../widgets/bubble_body.dart';
import '../widgets/chat_background.dart';
import '../widgets/doodle_attachment.dart';
import '../widgets/doodle_overlay.dart';
import '../widgets/rich_message_text.dart';
import '../widgets/nudge_overlay.dart';
import '../widgets/quoted_message.dart';
import '../widgets/reaction_picker.dart';
import '../widgets/receipt_ticks.dart';
import '../widgets/rename_dialog.dart';
import '../widgets/storage_strip.dart';
import '../widgets/video_attachment.dart';
import 'call_screen.dart';
import 'contact_profile_screen.dart';
import 'nudge_history_screen.dart';
import 'shared_media_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.conversation,
    this.initialMessageId,
  });

  final Conversation conversation;

  /// When set, open by jumping to this message instead of anchoring at the end
  /// (starred / search / shared-media "show in chat").
  final int? initialMessageId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  final _searchQuery = TextEditingController();
  final _scroll = ScrollController();
  final _recorder = AudioRecorder();

  /// Held here so replying can raise the keyboard the way WhatsApp does.
  final _composerFocus = FocusNode();

  /// Drives the wave animation when a nudge is sent or received here.
  final _nudgeOverlay = NudgeOverlayController();
  StreamSubscription<NudgeEvent>? _nudgeSub;
  StreamSubscription<DoodleRelayUpdate>? _doodleSub;

  bool _doodleMode = false;
  bool _doodleSending = false;
  Size? _doodleCanvasSize;
  DoodleDrawController? _doodleDraw;
  late final DoodleIncomingController _doodleIncoming;

  Timer? _typingStop;
  Timer? _recordTicker;
  bool _recording = false;
  bool _searching = false;
  Duration _recorded = Duration.zero;
  String? _recordingPath;
  bool _showJumpToLatest = false;
  bool _openingConversation = true;
  late final AppState _appState;

  /// Message being replied to, shown above the composer until sent or cleared.
  ChatMessage? _replyTo;

  /// Briefly tinted after jumping to a quoted message, so it stands out.
  int? _highlightedMessageId;
  Timer? _highlightTimer;

  /// Set once the user closes the anniversary-day banner, so it stays gone for
  /// this visit instead of springing back on every rebuild.
  bool _anniversaryBannerDismissed = false;

  /// Tracks transcript growth so arrivals can be told apart from older pages.
  int _knownMessageCount = 0;

  @override
  void initState() {
    super.initState();
    _appState = context.read<AppState>();
    _appState.setActiveConversation(widget.conversation.id);
    _scroll.addListener(_onScroll);
    // A nudge that lands in this chat while it's open plays the wave here (the
    // haptic already fired in AppState, for every screen).
    _nudgeSub = _appState.nudges.listen((n) {
      if (!mounted || n.conversationId != widget.conversation.id) return;
      _nudgeOverlay.play(
        glyph: n.variant.emoji,
        caption: n.caption,
      );
    });
    _doodleIncoming = DoodleIncomingController(
      conversationId: widget.conversation.id,
    );
    _doodleSub = _appState.doodleRelay.listen(_onDoodleRelay);
    _appState.addListener(_onAppStateChanged);
    _restoreDraft();
    _openConversation();
  }

  Future<void> _restoreDraft() async {
    final draft = await DraftStore.getDraft(widget.conversation.id);
    if (!mounted || draft == null || draft.isEmpty) return;
    _text.text = draft;
    _text.selection = TextSelection.collapsed(offset: draft.length);
  }

  /// Loads history. The transcript is anchored at the newest message by the
  /// reversed list itself, so only a jump to a specific message needs work.
  Future<void> _openConversation() async {
    try {
      await _appState.loadMessages(widget.conversation.id, initial: true);
      if (!mounted) return;
      final target = widget.initialMessageId;
      if (target != null) {
        _openingConversation = false;
        await _goToMessage(target);
      }
    } catch (_) {
      // AppState already exposes load failures through its normal error UI.
    } finally {
      if (mounted) _openingConversation = false;
    }
  }

  @override
  void dispose() {
    _typingStop?.cancel();
    _recordTicker?.cancel();
    _highlightTimer?.cancel();
    _nudgeSub?.cancel();
    _doodleSub?.cancel();
    _appState.removeListener(_onAppStateChanged);
    _endDoodleMode(sendEnd: false);
    _nudgeOverlay.dispose();
    _appState.setActiveConversation(null);
    _appState.setTyping(widget.conversation.id, false);
    VoicePlayer.instance.stop();
    _text.dispose();
    _searchQuery.dispose();
    _composerFocus.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _recorder.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;

    if (!_openingConversation &&
        shouldLoadOlder(
          pixels: position.pixels,
          maxScrollExtent: position.maxScrollExtent,
        )) {
      _appState.loadOlder(widget.conversation.id);
    }
    final shouldShow = shouldShowJumpToLatest(position.pixels);
    if (shouldShow != _showJumpToLatest) {
      setState(() => _showJumpToLatest = shouldShow);
    }
  }

  void _onTypingChanged(String value) {
    final state = context.read<AppState>();
    state.setTyping(widget.conversation.id, value.isNotEmpty);
    _typingStop?.cancel();
    _typingStop = Timer(const Duration(seconds: 2), () {
      state.setTyping(widget.conversation.id, false);
    });
    unawaited(DraftStore.setDraft(widget.conversation.id, value));
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
    );
  }

  /// Runs an action and reports any failure as readable text instead of crashing.
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _showMessage(friendlyMessage(e));
    }
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    final state = context.read<AppState>();
    final replyTo = _replyTo;
    _text.clear();
    setState(() => _replyTo = null);
    state.setTyping(widget.conversation.id, false);
    unawaited(DraftStore.clearDraft(widget.conversation.id));
    HapticFeedback.lightImpact();

    // Not awaited before scrolling: sendText adds the message to the transcript
    // synchronously, so the chat can jump to it now instead of after the round
    // trip to the server.
    final sending = state.sendText(
      widget.conversation.id,
      text,
      replyTo: replyTo,
    );
    _jumpToEnd(animate: false);
    await _guard(() => sending);
  }

  /// Moves to the newest message, which in a reversed list is offset zero.
  void _jumpToEnd({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      if (animate) {
        _scroll.animateTo(
          newestMessageOffset,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scroll.jumpTo(newestMessageOffset);
      }
    });
  }

  bool get _isNearBottom {
    if (!_scroll.hasClients) return true;
    return isAtNewest(_scroll.position.pixels);
  }

  /// Handles a transcript that grew.
  ///
  /// Reading the newest messages follows them down. Reading older history keeps
  /// its place instead: an arrival is added at the anchored end, which pushes
  /// everything else away from it, so the offset is moved by the same amount.
  void _followNewMessages(int messageCount) {
    if (messageCount == _knownMessageCount) return;
    final grew = messageCount > _knownMessageCount;
    _knownMessageCount = messageCount;
    if (!grew || _openingConversation) return;
    if (_isNearBottom) {
      _jumpToEnd(animate: false);
      return;
    }
    if (!_scroll.hasClients) return;
    final extentBefore = _scroll.position.maxScrollExtent;
    final pixelsBefore = _scroll.position.pixels;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      final target = offsetAfterGrowth(
        pixels: pixelsBefore,
        extentDelta: position.maxScrollExtent - extentBefore,
        maxScrollExtent: position.maxScrollExtent,
      );
      if (target != position.pixels) _scroll.jumpTo(target);
    });
  }

  void _jumpToLatestPressed() => _jumpToEnd(animate: true);

  Future<void> _upload(
    File file,
    String type, {
    String? caption,
    ChatMessage? replyTo,
  }) async {
    final quote = replyTo ?? _replyTo;
    if (_replyTo != null) setState(() => _replyTo = null);
    final sending = context.read<AppState>().uploadFile(
      conversationId: widget.conversation.id,
      file: file,
      type: type,
      caption: caption,
      replyTo: quote,
    );
    _jumpToEnd(animate: false);
    await _guard(() => sending);
    _jumpToEnd(animate: false);
  }

  /// Caps a batch, opens the review screen, then uploads with an optional caption.
  Future<void> _reviewAndUpload(
    List<File> files,
    String defaultType, {
    String? initialCaption,
  }) async {
    var batch = files;
    if (batch.length > AppState.maxAttachmentsPerSend) {
      batch = batch.sublist(0, AppState.maxAttachmentsPerSend);
      _showMessage(
        'You can send ${AppState.maxAttachmentsPerSend} at a time; '
        'the first ${AppState.maxAttachmentsPerSend} were queued.',
      );
    }
    final review = await MediaReviewScreen.open(
      context,
      files: batch,
      defaultType: defaultType,
      initialCaption: initialCaption,
    );
    if (review == null || !mounted || review.files.isEmpty) return;

    final replyTo = _replyTo;
    if (replyTo != null) setState(() => _replyTo = null);

    if (review.files.length == 1) {
      final file = review.files.first;
      await _upload(
        file,
        AppState.attachmentTypeFor(file.path),
        caption: review.caption,
        replyTo: replyTo,
      );
      return;
    }

    final sending = _appState.uploadFiles(
      conversationId: widget.conversation.id,
      files: review.files,
      type: defaultType,
      typeOf: (file) => AppState.attachmentTypeFor(file.path),
      caption: review.caption,
      replyTo: replyTo,
    );
    _jumpToEnd(animate: false);
    await _guard(() => sending);
    if (mounted) _jumpToEnd(animate: false);
  }

  void _startReply(ChatMessage message) {
    setState(() => _replyTo = message);
    _raiseKeyboardForReply();
  }

  /// Double-tapping the chat background pokes the other side, Hike-style.
  ///
  /// The wave and buzz only play when the nudge actually goes out; a rapid
  /// second tap is inside the cooldown and is swallowed silently rather than
  /// buzzing for a poke the server will drop.
  void _sendNudge() {
    if (!_appState.sendChatNudge(widget.conversation.id)) return;
    final record = _appState.nudgesByConv[widget.conversation.id]?.firstOrNull;
    final caption = record != null ? _appState.nudgeCaptionFor(record) : null;
    HapticFeedback.mediumImpact();
    _nudgeOverlay.play(caption: caption);
  }

  /// Opens the keyboard for a reply the user started by swiping.
  ///
  /// Focus is asked for after the frame that inserts the draft bar, because the
  /// reply fires mid-swipe and the composer moves down a slot as it appears.
  ///
  /// Focus alone is not enough on Android: the field can hold focus while the
  /// IME stays hidden, which is what left the user tapping the field to type.
  /// requestFocus is also a no-op when the field is already focused — after the
  /// keyboard was dismissed with the back button, say. So the platform is asked
  /// to show the keyboard outright, rather than assuming focus implies it.
  void _raiseKeyboardForReply() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _composerFocus.requestFocus();
      // A beat later, so the field has attached to the platform input first.
      Future<void>.delayed(const Duration(milliseconds: 60), () {
        if (!mounted || !_composerFocus.hasFocus) return;
        SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      });
    });
  }

  /// Scrolls to a quoted message and flashes it.
  ///
  /// Off-screen items are not laid out, so this first moves near the message by
  /// its position in the list, then lets [Scrollable.ensureVisible] settle it
  /// once the row has actually been built.
  Future<void> _goToMessage(int messageId) async {
    final loaded = await _appState.ensureMessageLoaded(
      widget.conversation.id,
      messageId,
    );
    if (!mounted) return;
    if (!loaded) {
      _showMessage('That message is no longer available.');
      return;
    }

    final messages = _appState.messagesByConv[widget.conversation.id] ?? [];
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index < 0) {
      _showMessage('That message is no longer available.');
      return;
    }

    _highlight(messageId);

    if (!await _ensureVisible(messageId)) {
      if (_scroll.hasClients && messages.length > 1) {
        _scroll.jumpTo(
          approximateOffsetForIndex(
            index: index,
            messageCount: messages.length,
            maxScrollExtent: _scroll.position.maxScrollExtent,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 16));
        await _ensureVisible(messageId);
      }
    }
  }

  Future<void> _openSharedMedia(Conversation conv) async {
    final messageId = await Navigator.of(context).push<int>(
      MaterialPageRoute(builder: (_) => SharedMediaScreen(conversation: conv)),
    );
    if (!mounted || messageId == null) return;
    await _goToMessage(messageId);
  }

  Future<bool> _ensureVisible(int messageId) async {
    final target = _messageKeys[messageId]?.currentContext;
    if (target == null) return false;
    await Scrollable.ensureVisible(
      target,
      // Centred, because alignment is measured from the leading edge and this
      // list leads at the bottom; a third of the way up would sit oddly low.
      alignment: 0.5,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    return true;
  }

  void _highlight(int messageId) {
    _highlightTimer?.cancel();
    setState(() => _highlightedMessageId = messageId);
    _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
  }

  /// Keys for messages currently on screen, used to scroll to a quote.
  final Map<int, GlobalKey> _messageKeys = {};

  GlobalKey _keyFor(int messageId) =>
      _messageKeys.putIfAbsent(messageId, GlobalKey.new);

  /// Camera capture — always a single shot, then the review step.
  Future<void> _pickCameraImage() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
      maxWidth: 2048,
    );
    if (picked == null || !mounted) return;
    await _reviewAndUpload([File(picked.path)], 'image');
  }

  /// Recent gallery grid — mixed photos and videos, numbered multi-select.
  Future<void> _pickGalleryMedia() async {
    final picked = await MediaPickerService.pickChatAttachments(context);
    if (picked == null || picked.isEmpty || !mounted) return;
    await _reviewAndUpload(picked, 'image');
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || !mounted) return;
    final files = [
      for (final f in result.files)
        if (f.path != null) File(f.path!),
    ];
    if (files.isEmpty) return;
    await _reviewAndUpload(files, 'file');
  }

  Future<void> _openAttachmentSheet() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Share',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  _ShareOption(
                    icon: Icons.photo_library_rounded,
                    label: 'Gallery',
                    color: const Color(0xFF7C3AED),
                    onTap: () => Navigator.pop(sheetContext, 'gallery'),
                  ),
                  _ShareOption(
                    icon: Icons.photo_camera_rounded,
                    label: 'Camera',
                    color: const Color(0xFFDB2777),
                    onTap: () => Navigator.pop(sheetContext, 'camera'),
                  ),
                  _ShareOption(
                    icon: Icons.insert_drive_file_rounded,
                    label: 'Document',
                    color: const Color(0xFF2563EB),
                    onTap: () => Navigator.pop(sheetContext, 'file'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Space is shown here, at the moment of choosing what to send, so
              // a big video can be reconsidered before it is on its way.
              const StorageStrip(),
            ],
          ),
        ),
      ),
    );

    switch (choice) {
      case 'gallery':
        await _pickGalleryMedia();
      case 'camera':
        await _pickCameraImage();
      case 'file':
        await _pickFiles();
    }
  }

  Future<void> _startRecording() async {
    if (!await _recorder.hasPermission()) {
      _showMessage('Local Chat needs microphone access to record voice notes.');
      return;
    }
    final dir = await getTemporaryDirectory();
    _recordingPath =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: _recordingPath!,
    );
    _recorded = Duration.zero;
    _recordTicker?.cancel();
    _recordTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _recorded += const Duration(seconds: 1));
      }
    });
    setState(() => _recording = true);
  }

  Future<void> _finishRecording({required bool send}) async {
    _recordTicker?.cancel();
    final path = await _recorder.stop();
    if (mounted) setState(() => _recording = false);
    if (path == null) return;
    final file = File(path);
    if (!send) {
      if (await file.exists()) await file.delete();
      return;
    }
    if (mounted) await _upload(file, 'voice');
  }

  void _showGroupMembers(Conversation conv) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final state = sheetContext.read<AppState>();
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  '${conv.members.length} members',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              for (final member in conv.members)
                ListTile(
                  leading: Avatar(
                    name: state.nameForMember(member),
                    seed: member.userId,
                    radius: 20,
                    imageUrl: state.avatarUrlFor(member.userId),
                    imageHeaders: state.api.imageAuthHeaders,
                    online:
                        state.onlineByUser[member.userId] ?? member.isOnline,
                  ),
                  title: Text(state.nameForMember(member)),
                  subtitle: Text(
                    state.hasCustomName(member.username)
                        ? '@${member.username} · really ${member.displayName}'
                        : '@${member.username}',
                  ),
                  trailing: member.role == 'admin'
                      ? const Chip(label: Text('Admin'))
                      : const Icon(
                          Icons.drive_file_rename_outline_rounded,
                          size: 18,
                        ),
                  onTap: member.userId == state.me?.id
                      ? null
                      : () {
                          Navigator.pop(sheetContext);
                          showRenameContactDialog(
                            context,
                            username: member.username,
                            serverName: member.displayName,
                          );
                        },
                ),
            ],
          ),
        );
      },
    );
  }

  String _senderName(AppState state, Conversation conv, int senderId) {
    for (final m in conv.members) {
      if (m.userId == senderId) return state.nameForMember(m);
    }
    return 'User';
  }

  String _subtitleFor(Conversation conv, AppState state) {
    final typing = state.typingLabelFor(conv);
    if (typing != null) return typing;
    if (conv.type == 'group') return '${conv.members.length} members';
    final peer = conv.peer;
    if (peer == null) return '';
    if (state.onlineByUser[peer.id] ?? peer.isOnline) return 'online';
    final seen = state.lastSeenByUser[peer.id] ?? peer.lastSeenAt;
    if (seen == null) return '';
    return formatLastSeen(context, seen);
  }

  String? _moodLine(Conversation conv, AppState state) {
    // Mood is secondary: never replace typing/online/last-seen.
    if (state.typingLabelFor(conv) != null) return null;
    final mood = conv.peer?.mood?.trim();
    if (mood == null || mood.isEmpty) return null;
    return mood;
  }

  /// Shows the other person's (or the group's) photo full screen.
  void _viewAvatar(Conversation conv, String title, AppState state) {
    final isDm = conv.type == 'dm';
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AvatarViewerScreen(
          name: title,
          seed: isDm ? (conv.peer?.id ?? conv.id) : conv.id,
          imageUrl: isDm ? state.avatarUrlFor(conv.peer?.id) : null,
          imageHeaders: state.api.imageAuthHeaders,
        ),
      ),
    );
  }

  Future<void> _openContactProfile(Conversation conv) async {
    if (conv.type == 'group') {
      _showGroupMembers(conv);
      return;
    }
    final action = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ContactProfileScreen(conversation: conv),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'voice') {
      await _startCall(conv, video: false);
    } else if (action == 'video') {
      await _startCall(conv, video: true);
    }
  }

  Future<void> _searchInChat(Conversation conv, String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    try {
      final results = await _appState.searchMessages(
        trimmed,
        conversationId: conv.id,
      );
      if (!mounted) return;
      if (results.isEmpty) {
        _showMessage('No messages match that search.');
        return;
      }
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 16),
            itemCount: results.length,
            itemBuilder: (_, index) {
              final msg = results[index];
              return ListTile(
                title: Text(
                  AppState.messagePreview(msg),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(formatClockTime(context, msg.createdAt)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  setState(() {
                    _searching = false;
                    _searchQuery.clear();
                  });
                  _goToMessage(msg.id);
                },
              );
            },
          ),
        ),
      );
    } catch (e) {
      _showMessage(friendlyMessage(e));
    }
  }

  Future<void> _exportChat(Conversation conv) async {
    try {
      for (var i = 0; i < 5; i++) {
        final before = (_appState.messagesByConv[conv.id] ?? []).length;
        await _appState.loadOlder(conv.id);
        final after = (_appState.messagesByConv[conv.id] ?? []).length;
        if (after == before) break;
      }
      if (!mounted) return;
      final state = context.read<AppState>();
      final messages = state.messagesByConv[conv.id] ?? const <ChatMessage>[];
      final text = formatChatAsText(
        conversation: conv,
        messages: messages,
        nameFor: (id) => _senderName(state, conv, id),
        chatTitle: state.titleFor(conv),
      );
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/chat_export_${conv.id}_${DateTime.now().millisecondsSinceEpoch}.txt',
      );
      await file.writeAsString(text);
      await Share.shareXFiles([XFile(file.path)], text: 'Chat export');
    } catch (e) {
      _showMessage(friendlyMessage(e));
    }
  }

  void _onDoodleRelay(DoodleRelayUpdate update) {
    if (!mounted || update.conversationId != widget.conversation.id) return;
    _doodleIncoming.apply(update);
  }

  void _onAppStateChanged() {
    if (!_appState.realtimeConnected) {
      _doodleIncoming.clearOnDisconnect();
    }
  }

  void _startDoodleMode() {
    if (_doodleMode) return;
    setState(() {
      _doodleMode = true;
      _doodleSending = false;
      _doodleCanvasSize = null;
      _doodleDraw = DoodleDrawController(
        conversationId: widget.conversation.id,
        send: _appState.realtime.send,
      );
    });
  }

  Future<void> _sendDoodle() async {
    final draw = _doodleDraw;
    if (draw == null || _doodleSending) return;
    if (draw.session.visibleStrokes().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Draw something before sending.')),
        );
      }
      return;
    }
    final canvas = _doodleCanvasSize;
    if (canvas == null || canvas.width <= 0 || canvas.height <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not capture the drawing canvas.')),
        );
      }
      return;
    }
    setState(() => _doodleSending = true);
    File? tempFile;
    try {
      final png = await exportDoodlePng(
        strokes: draw.session.visibleStrokes(),
        canvasWidth: canvas.width,
        canvasHeight: canvas.height,
      );
      final dir = await getTemporaryDirectory();
      tempFile = File(
        '${dir.path}/doodle_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await tempFile.writeAsBytes(png, flush: true);
      await _appState.uploadFile(
        conversationId: widget.conversation.id,
        file: tempFile,
        type: 'doodle',
        replyTo: _replyTo,
      );
      if (_replyTo != null && mounted) {
        setState(() => _replyTo = null);
      }
      _endDoodleMode(sendEnd: true, fromSend: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyMessage(e))),
        );
      }
    } finally {
      if (tempFile != null) {
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {}
      }
      if (mounted) setState(() => _doodleSending = false);
    }
  }

  void _endDoodleMode({required bool sendEnd, bool fromSend = false}) {
    final draw = _doodleDraw;
    if (draw != null) {
      final available = doodleRelayAvailable(
        realtimeConnected: _appState.realtimeConnected,
      );
      if (sendEnd) {
        if (fromSend) {
          draw.sendDrawing(relayAvailable: available);
        } else {
          draw.cancel(relayAvailable: available);
        }
      } else {
        draw.dispose(relayAvailable: available);
      }
    }
    _doodleDraw = null;
    _doodleIncoming.clearOnDisconnect();
    if (_doodleMode && mounted) {
      setState(() => _doodleMode = false);
    } else {
      _doodleMode = false;
    }
  }

  Future<void> _onChatMenuSelected(String value, Conversation conv) async {
    final state = context.read<AppState>();
    switch (value) {
      case 'search':
        setState(() => _searching = true);
      case 'media':
        await _openSharedMedia(conv);
      case 'export':
        await _exportChat(conv);
      case 'pin':
        await state.togglePin(conv.id);
      case 'mute':
        await state.toggleMute(conv.id);
      case 'wallpaper':
        await _openWallpaperSheet(conv);
      case 'nudge':
        await _openNudgeSheet(conv);
      case 'nudge_history':
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => NudgeHistoryScreen(conversation: conv),
          ),
        );
      case 'doodle':
        _startDoodleMode();
      case 'disappearing':
        await _openDisappearingSheet(conv);
      case 'anniversary':
        await _pickAnniversary(conv);
      case 'couple':
        await _openCoupleDetails(conv);
      case 'voice_call':
        await _startCall(conv, video: false);
      case 'video_call':
        await _startCall(conv, video: true);
    }
  }

  Future<void> _startCall(Conversation conv, {required bool video}) async {
    final state = context.read<AppState>();
    try {
      await state.calls.startOutgoing(
        conversationId: conv.id,
        media: video ? 'video' : 'audio',
        peerName: state.titleFor(conv),
        peerUserId: conv.peer?.id,
      );
      if (!mounted) return;
      await presentCallScreen(context);
    } catch (e) {
      if (mounted) _showMessage(friendlyMessage(e));
    }
  }

  /// Lets the user pick a nudge flavour (wave, poke, hug, kiss) to send.
  Future<void> _openNudgeSheet(Conversation conv) async {
    final variant = await showModalBottomSheet<NudgeVariant>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final v in NudgeVariant.values)
              ListTile(
                leading: Text(v.emoji, style: const TextStyle(fontSize: 24)),
                title: Text('${v.name[0].toUpperCase()}${v.name.substring(1)}'),
                onTap: () => Navigator.pop(sheetContext, v),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (variant == null || !mounted) return;
    if (_appState.sendChatNudge(conv.id, variant: variant.id)) {
      final record = _appState.nudgesByConv[conv.id]?.firstOrNull;
      final caption = record != null ? _appState.nudgeCaptionFor(record) : null;
      variant.playHaptic();
      _nudgeOverlay.play(glyph: variant.emoji, caption: caption);
    } else {
      _snack('Wait a moment before nudging again.');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// WhatsApp-style disappearing-message presets.
  Future<void> _openDisappearingSheet(Conversation conv) async {
    final live = _appState.conversationById(conv.id) ?? conv;
    final current = live.disappearAfterSeconds;
    final choice = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'New messages will vanish after the chosen time for everyone.',
                ),
              ),
            ),
            for (final option in const [
              (0, 'Off'),
              (86400, '24 hours'),
              (604800, '7 days'),
              (7776000, '90 days'),
            ])
              ListTile(
                title: Text(option.$2),
                trailing: (current ?? 0) == option.$1
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(sheetContext, option.$1),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await _guard(
      () => _appState.setDisappearing(conv.id, choice == 0 ? null : choice),
    );
  }

  /// Sets or clears a DM's anniversary date.
  Future<void> _pickAnniversary(Conversation conv) async {
    final live = _appState.conversationById(conv.id) ?? conv;
    final existing = live.anniversaryOn == null
        ? null
        : DateTime.tryParse(live.anniversaryOn!);
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: existing ?? now,
      firstDate: DateTime(now.year - 100),
      lastDate: DateTime(now.year + 100, 12, 31),
      helpText: 'Select your anniversary',
    );
    if (!mounted) return;
    if (picked == null) return;
    final iso =
        '${picked.year.toString().padLeft(4, '0')}-'
        '${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';
    await _guard(() => _appState.setAnniversary(conv.id, iso));
  }

  /// A gentle, dismissible strip shown only on the anniversary day itself.
  /// Returns null on every other day so the transcript stays uncluttered.
  Widget? _anniversaryBanner(Conversation conv) {
    if (conv.type != 'dm' || _anniversaryBannerDismissed) return null;
    final countdown = anniversaryCountdown(conv.anniversaryOn);
    if (countdown == null || !countdown.isToday) return null;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              const Text('🎉', style: TextStyle(fontSize: 20)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Happy anniversary!',
                  style: TextStyle(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Dismiss',
                icon: Icon(
                  Icons.close_rounded,
                  color: scheme.onPrimaryContainer,
                ),
                onPressed: () =>
                    setState(() => _anniversaryBannerDismissed = true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Sticky header of pinned messages with a tap-to-jump action.
  Widget? _pinsBanner(AppState state, Conversation conv) {
    final pins = state.pinsByConv[conv.id];
    if (pins == null || pins.isEmpty) return null;
    final scheme = Theme.of(context).colorScheme;
    final top = pins.first;
    final preview = AppState.messagePreview(top);
    final extra = pins.length - 1;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: InkWell(
        onTap: () => _goToMessage(top.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Icon(Icons.push_pin_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      extra > 0 ? 'Pinned · +$extra more' : 'Pinned message',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: scheme.onSurface),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openCoupleDetails(Conversation conv) async {
    final live = _appState.conversationById(conv.id) ?? conv;
    final countdown = anniversaryCountdown(live.anniversaryOn);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              leading: Icon(Icons.favorite_outline_rounded),
              title: Text('Couple details'),
            ),
            if (live.streakDays > 0)
              ListTile(
                leading: const Text('🔥', style: TextStyle(fontSize: 22)),
                title: Text('${live.streakDays}-day streak'),
                subtitle: const Text(
                  'A day counts when both of you send a message.',
                ),
              ),
            ListTile(
              leading: const Icon(Icons.event_rounded),
              title: Text(
                live.anniversaryOn == null
                    ? 'Set anniversary'
                    : countdown?.label ?? 'Anniversary',
              ),
              subtitle: live.anniversaryOn == null
                  ? const Text('A private yearly month-and-day reminder')
                  : Text(live.anniversaryOn!),
              onTap: () => Navigator.pop(sheetContext, 'set'),
            ),
            if (live.anniversaryOn != null)
              ListTile(
                leading: const Icon(Icons.event_busy_outlined),
                title: const Text('Clear anniversary'),
                onTap: () => Navigator.pop(sheetContext, 'clear'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'set') {
      await _pickAnniversary(live);
    } else if (action == 'clear') {
      await _guard(() => _appState.setAnniversary(live.id, null));
    }
  }

  /// WhatsApp-style per-chat background: pick a photo, dim it, or clear it.
  Future<void> _openWallpaperSheet(Conversation conv) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      // A Consumer keeps the dim slider and the Remove row in step as the
      // wallpaper changes, so the sheet does not have to close to refresh.
      builder: (sheetContext) => Consumer<AppState>(
        builder: (_, state, _) {
          final live = state.conversationById(conv.id) ?? conv;
          final hasWallpaper = live.hasWallpaper;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.photo_library_rounded),
                    title: Text(
                      hasWallpaper ? 'Change wallpaper' : 'Choose from gallery',
                    ),
                    subtitle: const Text('Shared with everyone in this chat'),
                    onTap: () => Navigator.pop(sheetContext, 'pick'),
                  ),
                  if (hasWallpaper) ...[
                    ListTile(
                      leading: const Icon(Icons.brightness_6_rounded),
                      title: const Text('Dim'),
                      subtitle: Slider(
                        value: (live.wallpaperDim ?? 0.25).clamp(0.0, 0.8),
                        max: 0.8,
                        divisions: 8,
                        label:
                            '${((live.wallpaperDim ?? 0.25) * 100).round()}%',
                        onChanged: (value) =>
                            state.setChatWallpaperDim(conv.id, value),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.delete_outline_rounded),
                      title: const Text('Remove wallpaper'),
                      onTap: () => Navigator.pop(sheetContext, 'remove'),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted) return;
    if (choice == 'remove') {
      await _guard(() => _appState.clearChatWallpaper(conv.id));
      return;
    }
    if (choice != 'pick') return;
    final picked = await MediaPickerService.pickSingleGalleryImage(context);
    if (picked == null || !mounted) return;
    await _guard(() => _appState.setChatWallpaper(conv.id, picked));
  }

  List<PopupMenuEntry<String>> _chatMenuItems(
    AppState state,
    Conversation conv,
  ) {
    final pinned = state.isPinned(conv.id);
    final muted = state.isMuted(conv.id);
    final anniversary = anniversaryCountdown(conv.anniversaryOn);
    return [
      const PopupMenuItem(
        value: 'search',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.search_rounded),
          title: Text('Search in chat'),
        ),
      ),
      const PopupMenuItem(
        value: 'media',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.perm_media_outlined),
          title: Text('Media, links, and docs'),
        ),
      ),
      const PopupMenuItem(
        value: 'export',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.ios_share_rounded),
          title: Text('Export chat'),
        ),
      ),
      PopupMenuItem(
        value: 'pin',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
          ),
          title: Text(pinned ? 'Unpin chat' : 'Pin chat'),
        ),
      ),
      PopupMenuItem(
        value: 'mute',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            muted
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined,
          ),
          title: Text(muted ? 'Unmute' : 'Mute'),
        ),
      ),
      PopupMenuItem(
        value: 'wallpaper',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.wallpaper_rounded),
          title: const Text('Wallpaper'),
        ),
      ),
      PopupMenuItem(
        value: 'nudge',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.waving_hand_rounded),
          title: const Text('Send a nudge'),
        ),
      ),
      PopupMenuItem(
        value: 'nudge_history',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.history_rounded),
          title: const Text('Nudge history'),
        ),
      ),
      const PopupMenuItem(
        value: 'doodle',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.draw_rounded),
          title: Text('Draw on chat'),
        ),
      ),
      PopupMenuItem(
        value: 'disappearing',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Disappearing messages'),
          subtitle: Text(_disappearingLabel(conv.disappearAfterSeconds)),
        ),
      ),
      if (conv.type == 'dm')
        PopupMenuItem(
          value: 'couple',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.favorite_outline_rounded),
            title: Text(
              conv.streakDays > 0
                  ? 'Couple details · ${conv.streakDays}-day streak'
                  : 'Couple details',
            ),
            subtitle: anniversary == null ? null : Text(anniversary.label),
          ),
        ),
    ];
  }

  /// Human label for a disappearing timer, matching WhatsApp's presets.
  static String _disappearingLabel(int? seconds) {
    switch (seconds) {
      case 86400:
        return '24 hours';
      case 604800:
        return '7 days';
      case 7776000:
        return '90 days';
      default:
        return 'Off';
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final conv = state.conversations.cast<Conversation?>().firstWhere(
      (c) => c?.id == widget.conversation.id,
      orElse: () => widget.conversation,
    )!;
    final messages = state.messagesByConv[conv.id] ?? const <ChatMessage>[];
    _followNewMessages(messages.length);
    final online = conv.type == 'dm' && conv.peer != null
        ? (state.onlineByUser[conv.peer!.id] ?? false)
        : null;
    final scheme = Theme.of(context).colorScheme;
    final title = state.titleFor(conv);
    final presence = _subtitleFor(conv, state);
    final mood = _moodLine(conv, state);
    final typing = (state.typingUsers[conv.id] ?? const {}).isNotEmpty;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        popChatToInbox(Navigator.of(context));
      },
      child: Scaffold(
        backgroundColor: AppColors.chatCanvasFor(context),
        appBar: AppBar(
          leading: _searching
              ? IconButton(
                  tooltip: 'Cancel search',
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => setState(() {
                    _searching = false;
                    _searchQuery.clear();
                  }),
                )
              : IconButton(
                  tooltip: 'Back to chats',
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => popChatToInbox(Navigator.of(context)),
                ),
          titleSpacing: _searching ? 0 : null,
          title: _searching
              ? TextField(
                  controller: _searchQuery,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    hintText: 'Search in chat',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onSubmitted: (value) => _searchInChat(conv, value),
                )
              : InkWell(
                  onTap: () => _openContactProfile(conv),
                  child: Row(
                    children: [
                      GestureDetector(
                        // The photo itself opens full screen; the name beside it
                        // opens the contact profile.
                        onTap: () => _viewAvatar(conv, title, state),
                        child: Avatar(
                          name: title,
                          seed: conv.type == 'dm'
                              ? (conv.peer?.id ?? conv.id)
                              : conv.id,
                          radius: 19,
                          online: online,
                          badge: conv.type == 'group'
                              ? Icons.group_rounded
                              : null,
                          imageUrl: conv.type == 'dm'
                              ? state.avatarUrlFor(conv.peer?.id)
                              : null,
                          imageHeaders: state.api.imageAuthHeaders,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                fontSize: 16.5,
                                fontWeight: FontWeight.w700,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (presence.isNotEmpty || mood != null)
                              AnimatedSize(
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOut,
                                alignment: Alignment.topLeft,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (presence.isNotEmpty)
                                      AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 180,
                                        ),
                                        child: Semantics(
                                          key: ValueKey(presence),
                                          label: presence,
                                          child: SingleChildScrollView(
                                            scrollDirection: Axis.horizontal,
                                            child: Text(
                                              presence,
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                color:
                                                    presence == 'typing…' ||
                                                        presence.endsWith(
                                                          'are typing…',
                                                        )
                                                    ? scheme.primary
                                                    : scheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    if (mood != null)
                                      Text(
                                        mood,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: scheme.onSurfaceVariant
                                              .withValues(alpha: 0.9),
                                          fontStyle: FontStyle.italic,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
          actions: [
            if (_searching)
              IconButton(
                tooltip: 'Search',
                icon: const Icon(Icons.search_rounded),
                onPressed: () => _searchInChat(conv, _searchQuery.text),
              )
            else ...[
              if (conv.type == 'dm') ...[
                IconButton(
                  tooltip: 'Voice call',
                  onPressed: () => _startCall(conv, video: false),
                  icon: const Icon(Icons.call_rounded),
                ),
                IconButton(
                  tooltip: 'Video call',
                  onPressed: () => _startCall(conv, video: true),
                  icon: const Icon(Icons.videocam_rounded),
                ),
              ],
              if (conv.type == 'group')
                IconButton(
                  tooltip: 'Members',
                  onPressed: () => _showGroupMembers(conv),
                  icon: const Icon(Icons.info_outline_rounded),
                ),
              PopupMenuButton<String>(
                tooltip: 'More',
                position: PopupMenuPosition.under,
                onSelected: (value) => _onChatMenuSelected(value, conv),
                itemBuilder: (_) => _chatMenuItems(state, conv),
              ),
            ],
          ],
        ),
        body: Column(
          children: [
            ?_anniversaryBanner(conv),
            ?_pinsBanner(state, conv),
            Expanded(
              child: ChatBackground(
                imageUrl: state.wallpaperUrlFor(conv.id),
                headers: state.api.imageAuthHeaders,
                dim: state.wallpaperDimFor(conv.id),
                // Double-tap anywhere on the transcript to nudge. Translucent so
                // single taps, long-press menus, swipe-to-reply and scrolling all
                // still reach the messages underneath.
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onDoubleTap: _doodleMode ? null : _sendNudge,
                  child: Stack(
                    children: [
                      if (messages.isEmpty)
                        _EmptyConversation(title: title)
                      else
                        _MessageList(
                          controller: _scroll,
                          messages: messages,
                          conversation: conv,
                          meId: state.me?.id,
                          typing: typing,
                          senderNameOf: (id) => _senderName(state, conv, id),
                          highlightedMessageId: _highlightedMessageId,
                          keyFor: _keyFor,
                          onReply: _startReply,
                          onQuoteTap: _goToMessage,
                        ),
                      if (_showJumpToLatest)
                        Positioned(
                          right: 16,
                          bottom: 12,
                          child: _JumpToLatestButton(
                            onTap: _jumpToLatestPressed,
                          ),
                        ),
                      Positioned.fill(
                        child: NudgeOverlay(controller: _nudgeOverlay),
                      ),
                      if (_doodleMode && _doodleDraw != null)
                        Positioned.fill(
                          child: DoodleOverlay(
                            draw: _doodleDraw!,
                            incoming: _doodleIncoming,
                            relayAvailable: doodleRelayAvailable(
                              realtimeConnected: state.realtimeConnected,
                            ),
                            onCancel: () => _endDoodleMode(sendEnd: true),
                            onSend: _sendDoodle,
                            onClose: () => _endDoodleMode(sendEnd: true),
                            sending: _doodleSending,
                            onCanvasSize: (size) => _doodleCanvasSize = size,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (state.isUploadingMedia)
              _UploadProgressBar(
                done: state.mediaUploadDone,
                total: state.mediaUploadTotal,
              ),
            // Keys matter here. Inserting the draft bar above the composer shifts
            // the composer down a slot, and without keys Flutter rebuilds it from
            // scratch: the text field loses its platform input connection, so the
            // keyboard stays shut even though the field holds focus.
            if (_replyTo != null)
              ReplyDraftBar(
                key: const ValueKey('reply-draft'),
                quote: QuotedMessage.fromMessage(_replyTo!),
                senderName: _replyTo!.senderId == state.me?.id
                    ? 'You'
                    : _senderName(state, conv, _replyTo!.senderId),
                accent: _replyTo!.senderId == state.me?.id
                    ? AppColors.brand
                    : senderColor(_replyTo!.senderId),
                onCancel: () => setState(() => _replyTo = null),
              ),
            _Composer(
              key: const ValueKey('composer'),
              controller: _text,
              focusNode: _composerFocus,
              recording: _recording,
              recordedFor: _recorded,
              onChanged: _onTypingChanged,
              onSend: _send,
              onAttach: _openAttachmentSheet,
              onStartRecording: _startRecording,
              onStopRecording: () => _finishRecording(send: true),
              onCancelRecording: () => _finishRecording(send: false),
            ),
          ],
        ),
      ),
    );
  }
}

/// Scrolling transcript with date separators and grouped runs of messages.
class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.controller,
    required this.messages,
    required this.conversation,
    required this.meId,
    required this.typing,
    required this.senderNameOf,
    required this.highlightedMessageId,
    required this.keyFor,
    required this.onReply,
    required this.onQuoteTap,
  });

  final ScrollController controller;
  final List<ChatMessage> messages;
  final Conversation conversation;
  final int? meId;
  final bool typing;
  final String Function(int senderId) senderNameOf;
  final int? highlightedMessageId;
  final GlobalKey Function(int messageId) keyFor;
  final ValueChanged<ChatMessage> onReply;
  final ValueChanged<int> onQuoteTap;

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: controller,
      // Built bottom-up: the newest message is the anchor, so opening a chat
      // needs no catch-up scroll and a late-loading image cannot shift it.
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      itemCount: transcriptItemCount(
        messageCount: messages.length,
        typing: typing,
      ),
      itemBuilder: (context, index) {
        final messageIndex = transcriptMessageIndex(
          itemIndex: index,
          messageCount: messages.length,
          typing: typing,
        );
        if (messageIndex == null) return const _TypingBubble();

        final msg = messages[messageIndex];
        final previous = messageIndex == 0 ? null : messages[messageIndex - 1];
        final next = messageIndex == messages.length - 1
            ? null
            : messages[messageIndex + 1];
        final mine = msg.senderId == meId;

        final startsDay =
            previous == null ||
            !_sameDay(previous.createdAt.toLocal(), msg.createdAt.toLocal());
        final firstOfRun = startsDay || previous.senderId != msg.senderId;
        final lastOfRun =
            next == null ||
            next.senderId != msg.senderId ||
            !_sameDay(next.createdAt.toLocal(), msg.createdAt.toLocal());

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (startsDay) _DateSeparator(date: msg.createdAt.toLocal()),
            Padding(
              key: keyFor(msg.id),
              padding: EdgeInsets.only(top: firstOfRun ? 8 : 2),
              child: SwipeToReply(
                // Pending messages have no server id yet, so there is nothing
                // for the other side to quote.
                enabled: !msg.pending && msg.id > 0 && !msg.isDeleted,
                onReply: () => onReply(msg),
                child: _MessageRow(
                  message: msg,
                  conversationId: conversation.id,
                  mine: mine,
                  firstOfRun: firstOfRun,
                  lastOfRun: lastOfRun,
                  showSenderName:
                      conversation.type == 'group' && !mine && firstOfRun,
                  senderName: senderNameOf(msg.senderId),
                  highlighted: highlightedMessageId == msg.id,
                  quotedSenderName: msg.replyTo == null
                      ? null
                      : senderNameOf(msg.replyTo!.senderId),
                  quotedIsMine: msg.replyTo?.senderId == meId,
                  onQuoteTap: msg.replyTo == null
                      ? null
                      : () => onQuoteTap(msg.replyTo!.id),
                  onReply: msg.pending || msg.id <= 0 || msg.isDeleted
                      ? null
                      : () => onReply(msg),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({
    required this.message,
    required this.conversationId,
    required this.mine,
    required this.firstOfRun,
    required this.lastOfRun,
    required this.showSenderName,
    required this.senderName,
    this.highlighted = false,
    this.quotedSenderName,
    this.quotedIsMine = false,
    this.onQuoteTap,
    this.onReply,
  });

  final ChatMessage message;
  final int conversationId;
  final bool mine;
  final bool firstOfRun;
  final bool lastOfRun;
  final bool showSenderName;
  final String senderName;
  final bool highlighted;
  final String? quotedSenderName;
  final bool quotedIsMine;
  final VoidCallback? onQuoteTap;
  final VoidCallback? onReply;

  /// This account's current reaction on the message, or null.
  String? get _myReaction {
    for (final r in message.reactions) {
      if (r.reactedByMe) return r.emoji;
    }
    return null;
  }

  Future<void> _showActions(BuildContext context) async {
    if (message.isDeleted || message.isCallLog) return;

    final state = context.read<AppState>();
    final meId = state.me?.id;
    final isText = message.type == 'text';
    final canCopy = isText && (message.body ?? '').trim().isNotEmpty;
    // Editing is only offered inside the 15-minute trust window.
    final canEdit = message.canEdit(meId);
    final hasAttachActions = messageHasAttachmentActions(message);
    // Delete for everyone is the sender's (or a group admin's) call; delete for
    // me is always available so anyone can clear their own view.

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // WhatsApp-style quick reaction row at the top of the sheet.
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: ReactionBar(
                myEmoji: _myReaction,
                onPick: (emoji) => Navigator.pop(sheetContext, 'react:$emoji'),
                onMore: () => Navigator.pop(sheetContext, 'react:more'),
              ),
            ),
            const Divider(height: 1),
            if (hasAttachActions) ...[
              ListTile(
                leading: const Icon(Icons.open_in_new_rounded),
                title: const Text('Open'),
                onTap: () => Navigator.pop(sheetContext, 'attach:open'),
              ),
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('Save to phone'),
                subtitle: const Text('Choose where to keep this file'),
                onTap: () => Navigator.pop(sheetContext, 'attach:save'),
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('Share'),
                onTap: () => Navigator.pop(sheetContext, 'attach:share'),
              ),
              const Divider(height: 1),
            ],
            if (onReply != null)
              ListTile(
                leading: const Icon(Icons.reply_rounded),
                title: const Text('Reply'),
                onTap: () => Navigator.pop(sheetContext, 'reply'),
              ),
            if (canCopy)
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('Copy text'),
                onTap: () => Navigator.pop(sheetContext, 'copy'),
              ),
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () => Navigator.pop(sheetContext, 'edit'),
              ),
            ListTile(
              leading: Icon(
                state.isMessagePinned(conversationId, message.id)
                    ? Icons.push_pin_rounded
                    : Icons.push_pin_outlined,
              ),
              title: Text(
                state.isMessagePinned(conversationId, message.id)
                    ? 'Unpin'
                    : 'Pin',
              ),
              onTap: () => Navigator.pop(
                sheetContext,
                state.isMessagePinned(conversationId, message.id)
                    ? 'unpin'
                    : 'pin',
              ),
            ),
            ListTile(
              leading: Icon(
                state.isMessageStarred(message.id)
                    ? Icons.star_rounded
                    : Icons.star_outline_rounded,
              ),
              title: Text(
                state.isMessageStarred(message.id) ? 'Unstar' : 'Star',
              ),
              onTap: () => Navigator.pop(
                sheetContext,
                state.isMessageStarred(message.id) ? 'unstar' : 'star',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (action == null || !context.mounted) return;

    if (action.startsWith('attach:')) {
      final kind = action.substring('attach:'.length);
      await runAttachmentAction(context, message, switch (kind) {
        'open' => AttachmentAction.open,
        'save' => AttachmentAction.save,
        _ => AttachmentAction.share,
      });
      return;
    }

    if (action.startsWith('react:')) {
      final choice = action.substring('react:'.length);
      if (choice == 'more') {
        final picked = await showReactionPicker(context);
        if (picked != null && context.mounted) {
          await _react(context, picked);
        }
      } else {
        await _react(context, choice);
      }
      return;
    }

    switch (action) {
      case 'reply':
        onReply?.call();
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.body ?? ''));
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Copied')));
        }
      case 'edit':
        await _editMessage(context);
      case 'pin':
        try {
          await context.read<AppState>().pinMessage(message);
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(friendlyMessage(e))));
          }
        }
      case 'unpin':
        try {
          await context.read<AppState>().unpinMessage(message);
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(friendlyMessage(e))));
          }
        }
      case 'star':
        try {
          await context.read<AppState>().starMessage(message);
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(friendlyMessage(e))));
          }
        }
      case 'unstar':
        try {
          await context.read<AppState>().unstarMessage(message);
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(friendlyMessage(e))));
          }
        }
      case 'delete':
        await _deleteMessage(context);
    }
  }

  Future<void> _react(BuildContext context, String emoji) async {
    try {
      await context.read<AppState>().toggleReaction(message, emoji);
      HapticFeedback.selectionClick();
      unawaited(ReactionFreqStore.record(emoji));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyMessage(e))));
      }
    }
  }

  Future<void> _editMessage(BuildContext context) async {
    final controller = TextEditingController(text: message.body ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Message'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = result?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == (message.body ?? '').trim()) return;
    if (!context.mounted) return;
    try {
      await context.read<AppState>().editMessage(
        conversationId,
        message,
        trimmed,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyMessage(e))));
      }
    }
  }

  Future<void> _deleteMessage(BuildContext context) async {
    // Delete for everyone is only meaningful for your own messages (the server
    // also allows a group admin, but the common case is your own text). Delete
    // for me is always available.
    final scope = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (mine)
              ListTile(
                leading: const Icon(Icons.delete_forever_rounded),
                title: const Text('Delete for everyone'),
                onTap: () => Navigator.pop(sheetContext, 'everyone'),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('Delete for me'),
              onTap: () => Navigator.pop(sheetContext, 'me'),
            ),
            ListTile(
              leading: const Icon(Icons.close_rounded),
              title: const Text('Cancel'),
              onTap: () => Navigator.pop(sheetContext),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (scope == null || !context.mounted) return;
    try {
      await context.read<AppState>().deleteMessage(
        conversationId,
        message,
        scope: scope,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyMessage(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxWidth = MediaQuery.of(context).size.width * 0.76;

    // Call logs sit centred like WhatsApp's "Video call · 21 secs", not in a
    // left/right bubble.
    if (message.isCallLog) {
      return _CallLogTile(message: message);
    }
    // Photos, videos, and drawings use edge-to-edge tiles; doodles stay bubble-free.
    final isMediaTile =
        (message.type == 'image' || message.type == 'video') &&
        !message.isDeleted;
    final isDoodleTile = message.type == 'doodle' && !message.isDeleted;
    final isEdgeTile = isMediaTile || isDoodleTile;

    final footer = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          formatClockTime(context, message.createdAt),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: isEdgeTile ? Colors.white : scheme.outline,
            fontSize: 11,
          ),
        ),
        if (mine) ...[
          const SizedBox(width: 4),
          ReceiptTicks(
            level: message.pending ? -1 : message.receiptLevel(),
            onPhoto: isEdgeTile,
          ),
        ],
      ],
    );

    final quote = message.replyTo;

    // Emoji-only messages read as pictures, not text: draw them big, and for
    // short ones drop the bubble so nothing competes with the glyphs.
    final emojiCount = message.type == 'text' && !message.isDeleted
        ? emojiOnlyCount(message.body)
        : 0;
    final emojiSize = emojiOnlyFontSize(emojiCount);
    final bare =
        emojiSize != null &&
        emojiWithoutBubble(emojiCount) &&
        quote == null &&
        !showSenderName;
    final openActions = message.isDeleted || message.isCallLog
        ? null
        : () => _showActions(context);

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: GestureDetector(
          onLongPress: openActions,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: bare
                ? const EdgeInsets.fromLTRB(2, 2, 2, 0)
                : isDoodleTile
                ? EdgeInsets.zero
                : isMediaTile
                ? const EdgeInsets.all(4)
                : const EdgeInsets.fromLTRB(12, 8, 12, 7),
            decoration: BoxDecoration(
              color: bare
                  ? (highlighted
                        ? scheme.primary.withValues(alpha: 0.18)
                        : Colors.transparent)
                  : isDoodleTile
                  ? Colors.transparent
                  : highlighted
                  ? Color.alphaBlend(
                      scheme.primary.withValues(alpha: 0.22),
                      mine
                          ? AppColors.bubbleMineFor(context)
                          : AppColors.bubblePeerFor(context),
                    )
                  : mine
                  ? AppColors.bubbleMineFor(context)
                  : AppColors.bubblePeerFor(context),
              borderRadius: _bubbleRadius(),
              boxShadow: bare || isDoodleTile
                  ? null
                  : softShadow(
                      opacity: 0.045,
                      blur: 8,
                      offset: const Offset(0, 2),
                    ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showSenderName)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      senderName,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: senderColor(message.senderId),
                      ),
                    ),
                  ),
                if (quote != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: QuotedMessageCard(
                      quote: quote,
                      senderName: quotedIsMine
                          ? 'You'
                          : (quotedSenderName ?? 'Message'),
                      accent: quotedIsMine
                          ? AppColors.brand
                          : senderColor(quote.senderId),
                      onTap: onQuoteTap,
                    ),
                  ),
                if (isEdgeTile)
                  _MessageContent(
                    message: message,
                    maxWidth: maxWidth,
                    mine: mine,
                    footer: footer,
                    emojiSize: emojiSize,
                    emojiCount: emojiCount,
                    onLongPress: openActions,
                  )
                else
                  BubbleBody(
                    body: _MessageContent(
                      message: message,
                      maxWidth: maxWidth,
                      mine: mine,
                      emojiSize: emojiSize,
                      emojiCount: emojiCount,
                      onLongPress: openActions,
                    ),
                    meta: footer,
                  ),
                if (message.reactions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: ReactionChips(
                      reactions: message.reactions,
                      alignEnd: mine,
                      onToggle: (emoji) => _react(context, emoji),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  BorderRadius _bubbleRadius() {
    const wide = Radius.circular(AppRadius.bubble);
    const tight = Radius.circular(7);
    const joined = Radius.circular(10);
    return BorderRadius.only(
      topLeft: mine || firstOfRun ? wide : joined,
      topRight: !mine || firstOfRun ? wide : joined,
      bottomLeft: !mine && lastOfRun ? tight : wide,
      bottomRight: mine && lastOfRun ? tight : wide,
    );
  }
}

/// Centered call-log entry ("Video call · 21 secs" / "Missed call"), styled
/// like WhatsApp's in-transcript call rows.
class _CallLogTile extends StatelessWidget {
  const _CallLogTile({required this.message});

  final ChatMessage message;

  String? _endedByName(AppState state, CallLogInfo info) {
    if (info.endedByUserId == null) return null;
    final conv = state.conversationById(message.conversationId);
    if (conv == null) return null;
    for (final member in conv.members) {
      if (member.userId == info.endedByUserId) {
        return state.nameForMember(member);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = context.watch<AppState>();
    final info = parseCallLogBody(message.body);
    final label = formatCallLogTranscript(
      info,
      viewerUserId: state.me?.id,
      endedByName: _endedByName(state, info),
    );
    final color = info.isNegative ? scheme.error : scheme.onSurfaceVariant;

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(callLogIcon(info), size: 16, color: color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12.5, color: color)),
          ],
        ),
      ),
    );
  }
}

class _MessageContent extends StatelessWidget {
  const _MessageContent({
    required this.message,
    required this.maxWidth,
    required this.mine,
    this.footer,
    this.emojiSize,
    this.emojiCount = 0,
    this.onLongPress,
  });

  final ChatMessage message;
  final double maxWidth;
  final bool mine;
  final Widget? footer;
  final VoidCallback? onLongPress;

  /// Set when the body is nothing but emoji, which are drawn oversized.
  final double? emojiSize;

  /// How many emoji that body holds; a lone one gets the springy entrance.
  final int emojiCount;

  @override
  Widget build(BuildContext context) {
    if (message.isDeleted) {
      final scheme = Theme.of(context).colorScheme;
      return Text(
        'This message was deleted',
        style: TextStyle(
          height: 1.35,
          fontSize: 15,
          fontStyle: FontStyle.italic,
          color: scheme.onSurfaceVariant,
        ),
      );
    }

    switch (message.type) {
      case 'image':
        return ImageAttachment(
          message: message,
          maxWidth: maxWidth,
          footer: footer,
          onLongPress: onLongPress,
        );
      case 'video':
        return VideoAttachment(
          message: message,
          maxWidth: maxWidth,
          footer: footer,
          onLongPress: onLongPress,
        );
      case 'doodle':
        return DoodleAttachment(
          message: message,
          maxWidth: maxWidth,
          footer: footer,
          onLongPress: onLongPress,
        );
      case 'voice':
        return VoiceAttachment(
          message: message,
          accent: mine
              ? AppColors.brandDeep
              : Theme.of(context).colorScheme.primary,
          onLongPress: onLongPress,
        );
      case 'file':
        return FileAttachment(
          message: message,
          maxWidth: maxWidth,
          onLongPress: onLongPress,
        );
      default:
        final scheme = Theme.of(context).colorScheme;
        final size = emojiSize;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (size != null &&
                shouldAnimateSoloEmoji(
                  emojiCount: emojiCount,
                  animationsEnabled: !MediaQuery.disableAnimationsOf(context),
                ))
              SoloEmojiBubble(
                emoji: (message.body ?? '').trim(),
                fontSize: size,
                playbackKey: soloEmojiPlaybackKey(
                  messageId: message.id,
                  clientId: message.clientId,
                ),
              )
            else if (size != null)
              Text(
                message.body ?? '',
                // Emoji carry no links, so plain Text keeps the glyph metrics
                // clean at this size.
                style: emojiTextStyle(fontSize: size),
              )
            else
              RichMessageText(
                message.body ?? '',
                style: const TextStyle(height: 1.35, fontSize: 15),
              ),
            if (message.editedAt != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'edited',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    color: scheme.outline,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        );
    }
  }
}

class _DateSeparator extends StatelessWidget {
  const _DateSeparator({required this.date});

  final DateTime date;

  String get _label => formatDayLabel(date);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.surface.withValues(alpha: 0.90),
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Text(
            _label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(AppRadius.bubble),
            topRight: Radius.circular(AppRadius.bubble),
            bottomRight: Radius.circular(AppRadius.bubble),
            bottomLeft: Radius.circular(7),
          ),
          boxShadow: softShadow(opacity: 0.045, blur: 8),
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (index) {
              final phase = (_controller.value * 3 - index).clamp(0.0, 1.0);
              final lift = (phase < 0.5 ? phase : 1 - phase) * 2;
              return Padding(
                padding: EdgeInsets.only(right: index == 2 ? 0 : 5),
                child: Transform.translate(
                  offset: Offset(0, -lift * 2),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(
                        alpha: 0.35 + lift * 0.3,
                      ),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: scheme.surface,
                shape: BoxShape.circle,
                boxShadow: softShadow(color: scheme.primary, opacity: 0.15),
              ),
              child: Icon(
                Icons.lock_outline_rounded,
                size: 34,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Say hello to $title',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Messages here travel only over your private Tailscale network.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JumpToLatestButton extends StatelessWidget {
  const _JumpToLatestButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            Icons.keyboard_double_arrow_down_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class _ShareOption extends StatelessWidget {
  const _ShareOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.field),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 26),
              ),
              const SizedBox(height: 8),
              Text(label, style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
        ),
      ),
    );
  }
}

/// Thin banner shown while an album of attachments is uploading in order.
class _UploadProgressBar extends StatelessWidget {
  const _UploadProgressBar({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = total == 0 ? null : done / total;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      color: scheme.surfaceContainerHighest,
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, value: value),
          ),
          const SizedBox(width: 12),
          Text(
            'Sending $done of $total…',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

/// Message field that swaps the mic for a send button once you start typing.
class _Composer extends StatelessWidget {
  const _Composer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.recording,
    required this.recordedFor,
    required this.onChanged,
    required this.onSend,
    required this.onAttach,
    required this.onStartRecording,
    required this.onStopRecording,
    required this.onCancelRecording,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool recording;
  final Duration recordedFor;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onStartRecording;
  final VoidCallback onStopRecording;
  final VoidCallback onCancelRecording;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        boxShadow: softShadow(
          opacity: 0.06,
          blur: 16,
          offset: const Offset(0, -3),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: recording
              ? _RecordingBar(
                  elapsed: recordedFor,
                  onCancel: onCancelRecording,
                  onSend: onStopRecording,
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      onPressed: onAttach,
                      tooltip: 'Share a photo or file',
                      icon: Icon(
                        Icons.add_circle_outline_rounded,
                        color: scheme.primary,
                        size: 26,
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        minLines: 1,
                        maxLines: 5,
                        // Kept under the server's 8000-char body cap with room
                        // for a DM's ciphertext, which base64 expands ~1.4x.
                        maxLength: 4000,
                        buildCounter:
                            (
                              _, {
                              required currentLength,
                              required isFocused,
                              maxLength,
                            }) => null,
                        textCapitalization: TextCapitalization.sentences,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        decoration: const InputDecoration(
                          hintText: 'Message',
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 11,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.all(
                              Radius.circular(AppRadius.pill),
                            ),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.all(
                              Radius.circular(AppRadius.pill),
                            ),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.all(
                              Radius.circular(AppRadius.pill),
                            ),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: onChanged,
                      ),
                    ),
                    const SizedBox(width: 6),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: controller,
                      builder: (context, value, _) {
                        final hasText = value.text.trim().isNotEmpty;
                        return _PrimaryComposerButton(
                          icon: hasText
                              ? Icons.send_rounded
                              : Icons.mic_rounded,
                          onPressed: hasText ? onSend : onStartRecording,
                        );
                      },
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _PrimaryComposerButton extends StatelessWidget {
  const _PrimaryComposerButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: 46,
          height: 46,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            child: Icon(
              icon,
              key: ValueKey(icon),
              color: scheme.onPrimary,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}

class _RecordingBar extends StatelessWidget {
  const _RecordingBar({
    required this.elapsed,
    required this.onCancel,
    required this.onSend,
  });

  final Duration elapsed;
  final VoidCallback onCancel;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');

    return Row(
      children: [
        IconButton(
          onPressed: onCancel,
          tooltip: 'Discard',
          icon: const Icon(Icons.delete_outline_rounded, color: Colors.red),
        ),
        Expanded(
          child: Row(
            children: [
              const _PulsingDot(),
              const SizedBox(width: 10),
              Text(
                '$minutes:$seconds',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(width: 12),
              Text(
                'Recording…',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        _PrimaryComposerButton(icon: Icons.send_rounded, onPressed: onSend),
      ],
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_controller),
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: Colors.red,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
