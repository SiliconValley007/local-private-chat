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

import '../app_state.dart';
import '../errors.dart';
import '../models.dart';
import '../services/export_service.dart';
import '../services/voice_player.dart';
import '../theme.dart';
import '../time_format.dart';
import '../widgets/attachments.dart';
import '../widgets/avatar.dart';
import '../widgets/linkified_text.dart';
import '../widgets/quoted_message.dart';
import '../widgets/rename_dialog.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.conversation});

  final Conversation conversation;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  final _searchQuery = TextEditingController();
  final _scroll = ScrollController();
  final _recorder = AudioRecorder();

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

  /// Tracks transcript growth so new messages can follow the bottom.
  int _knownMessageCount = 0;

  @override
  void initState() {
    super.initState();
    _appState = context.read<AppState>();
    _appState.setActiveConversation(widget.conversation.id);
    _scroll.addListener(_onScroll);
    _openAtLatestMessage();
  }

  Future<void> _openAtLatestMessage() async {
    try {
      await _appState.loadMessages(widget.conversation.id, initial: true);
      if (!mounted) return;
      // One jump after layout, followed by two safeguards for image previews or
      // other children whose final height settles in a later frame.
      _jumpToEnd(animate: false);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (mounted) _jumpToEnd(animate: false);
      await Future<void>.delayed(const Duration(milliseconds: 240));
      if (mounted) _jumpToEnd(animate: false);
    } catch (_) {
      // AppState already exposes load failures through its normal error UI.
    } finally {
      _openingConversation = false;
    }
  }

  @override
  void dispose() {
    _typingStop?.cancel();
    _recordTicker?.cancel();
    _highlightTimer?.cancel();
    _appState.setActiveConversation(null);
    _appState.setTyping(widget.conversation.id, false);
    VoicePlayer.instance.stop();
    _text.dispose();
    _searchQuery.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _recorder.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (!_openingConversation && _scroll.position.pixels <= 40) {
      _appState.loadOlder(widget.conversation.id);
    }
    final distanceFromBottom =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    final shouldShow = distanceFromBottom > 320;
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

  void _jumpToEnd({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  bool get _isNearBottom {
    if (!_scroll.hasClients) return true;
    return _scroll.position.maxScrollExtent - _scroll.position.pixels < 320;
  }

  /// Keeps the newest message in view as the transcript grows, but only while
  /// already at the bottom — nobody wants to be yanked out of older history.
  void _followNewMessages(int messageCount) {
    if (messageCount == _knownMessageCount) return;
    final grew = messageCount > _knownMessageCount;
    _knownMessageCount = messageCount;
    if (!grew || _openingConversation) return;
    if (_isNearBottom) _jumpToEnd(animate: false);
  }

  Future<void> _upload(File file, String type) async {
    final replyTo = _replyTo;
    if (replyTo != null) setState(() => _replyTo = null);
    final sending = context.read<AppState>().uploadFile(
      conversationId: widget.conversation.id,
      file: file,
      type: type,
      replyTo: replyTo,
    );
    _jumpToEnd(animate: false);
    await _guard(() => sending);
    _jumpToEnd(animate: false);
  }

  void _startReply(ChatMessage message) {
    setState(() => _replyTo = message);
  }

  /// Scrolls to a quoted message and flashes it.
  ///
  /// Off-screen items are not laid out, so this first moves near the message by
  /// its position in the list, then lets [Scrollable.ensureVisible] settle it
  /// once the row has actually been built.
  Future<void> _goToMessage(int messageId) async {
    final messages = _appState.messagesByConv[widget.conversation.id] ?? [];
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index < 0) {
      _showMessage('That message is not loaded on this phone anymore.');
      return;
    }

    _highlight(messageId);

    if (!await _ensureVisible(messageId)) {
      if (_scroll.hasClients && messages.length > 1) {
        final ratio = index / (messages.length - 1);
        _scroll.jumpTo(ratio * _scroll.position.maxScrollExtent);
        await Future<void>.delayed(const Duration(milliseconds: 16));
        await _ensureVisible(messageId);
      }
    }
  }

  Future<bool> _ensureVisible(int messageId) async {
    final target = _messageKeys[messageId]?.currentContext;
    if (target == null) return false;
    await Scrollable.ensureVisible(
      target,
      alignment: 0.3,
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

  Future<void> _pickImage(ImageSource source) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      imageQuality: 85,
      maxWidth: 2048,
    );
    if (picked == null || !mounted) return;
    await _upload(File(picked.path), 'image');
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles();
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    await _upload(File(path), 'file');
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
            ],
          ),
        ),
      ),
    );

    switch (choice) {
      case 'gallery':
        await _pickImage(ImageSource.gallery);
      case 'camera':
        await _pickImage(ImageSource.camera);
      case 'file':
        await _pickFile();
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
                    online: state.onlineByUser[member.userId] ?? member.isOnline,
                  ),
                  title: Text(state.nameForMember(member)),
                  subtitle: Text(
                    state.hasCustomName(member.username)
                        ? '@${member.username} · really ${member.displayName}'
                        : '@${member.username}',
                  ),
                  trailing: member.role == 'admin'
                      ? const Chip(label: Text('Admin'))
                      : const Icon(Icons.drive_file_rename_outline_rounded,
                          size: 18),
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

  String _subtitleFor(Conversation conv, AppState state, bool typing) {
    if (typing) return 'typing…';
    if (conv.type == 'group') return '${conv.members.length} members';
    final peer = conv.peer;
    if (peer == null) return '';
    if (state.onlineByUser[peer.id] ?? peer.isOnline) return 'online';
    final seen = state.lastSeenByUser[peer.id] ?? peer.lastSeenAt;
    if (seen == null) return 'offline';
    return formatLastSeen(context, seen);
  }

  Future<void> _renamePeer(Conversation conv) async {
    final peer = conv.peer;
    if (peer == null) return;
    await showRenameContactDialog(
      context,
      username: peer.username,
      serverName: peer.displayName,
    );
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

  Future<void> _onChatMenuSelected(String value, Conversation conv) async {
    final state = context.read<AppState>();
    switch (value) {
      case 'search':
        setState(() => _searching = true);
      case 'export':
        await _exportChat(conv);
      case 'pin':
        await state.togglePin(conv.id);
      case 'mute':
        await state.toggleMute(conv.id);
      case 'rename':
        await _renamePeer(conv);
    }
  }

  List<PopupMenuEntry<String>> _chatMenuItems(AppState state, Conversation conv) {
    final pinned = state.isPinned(conv.id);
    final muted = state.isMuted(conv.id);
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
      if (conv.type == 'dm')
        PopupMenuItem(
          value: 'rename',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.drive_file_rename_outline_rounded),
            title: Text(
              state.hasCustomName(conv.peer?.username)
                  ? 'Change name'
                  : 'Rename this person',
            ),
            subtitle: conv.peer == null
                ? null
                : Text('Really ${conv.peer!.displayName}'),
          ),
        ),
    ];
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
    final typing = (state.typingUsers[conv.id] ?? const {}).isNotEmpty;
    final online = conv.type == 'dm' && conv.peer != null
        ? (state.onlineByUser[conv.peer!.id] ?? false)
        : null;
    final scheme = Theme.of(context).colorScheme;
    final title = state.titleFor(conv);

    return Scaffold(
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
            : null,
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
                onTap: conv.type == 'group'
                    ? () => _showGroupMembers(conv)
                    : () => _renamePeer(conv),
                child: Row(
                  children: [
                    Avatar(
                      name: title,
                      seed: conv.type == 'dm'
                          ? (conv.peer?.id ?? conv.id)
                          : conv.id,
                      radius: 19,
                      online: online,
                      badge: conv.type == 'group' ? Icons.group_rounded : null,
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
                          Text(
                            _subtitleFor(conv, state, typing),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: typing
                                  ? scheme.primary
                                  : (online == true
                                        ? AppColors.online
                                        : scheme.onSurfaceVariant),
                            ),
                            overflow: TextOverflow.ellipsis,
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
          Expanded(
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
                    child: _JumpToLatestButton(onTap: () => _jumpToEnd()),
                  ),
              ],
            ),
          ),
          if (_replyTo != null)
            ReplyDraftBar(
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
            controller: _text,
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      itemCount: messages.length + (typing ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == messages.length) return const _TypingBubble();

        final msg = messages[index];
        final previous = index == 0 ? null : messages[index - 1];
        final next = index == messages.length - 1 ? null : messages[index + 1];
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
              child:               SwipeToReply(
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

  Future<void> _showActions(BuildContext context) async {
    if (message.isDeleted) return;

    final isText = message.type == 'text';
    final canCopy = isText && (message.body ?? '').trim().isNotEmpty;
    final canEdit = mine && isText;
    final canDelete = mine && isText;

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
            if (canDelete)
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

    if (!context.mounted) return;

    switch (action) {
      case 'reply':
        onReply?.call();
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.body ?? ''));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Copied')),
          );
        }
      case 'edit':
        await _editMessage(context);
      case 'delete':
        await _deleteMessage(context);
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyMessage(e))),
        );
      }
    }
  }

  Future<void> _deleteMessage(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text('This message will be removed for everyone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await context.read<AppState>().deleteMessage(conversationId, message);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyMessage(e))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxWidth = MediaQuery.of(context).size.width * 0.76;
    final isPhoto = message.type == 'image' && !message.isDeleted;

    final footer = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          formatClockTime(context, message.createdAt),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: isPhoto ? Colors.white : scheme.outline,
            fontSize: 11,
          ),
        ),
        if (mine) ...[
          const SizedBox(width: 4),
          _Ticks(
            level: message.pending ? -1 : message.receiptLevel(),
            onPhoto: isPhoto,
          ),
        ],
      ],
    );

    final quote = message.replyTo;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: GestureDetector(
          onLongPress: message.isDeleted ? null : () => _showActions(context),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: isPhoto
                ? const EdgeInsets.all(4)
                : const EdgeInsets.fromLTRB(12, 8, 12, 7),
            decoration: BoxDecoration(
              color: highlighted
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
              boxShadow: softShadow(
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
                _MessageContent(
                  message: message,
                  maxWidth: maxWidth,
                  mine: mine,
                  footer: isPhoto ? footer : null,
                ),
                if (!isPhoto)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: footer,
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

class _MessageContent extends StatelessWidget {
  const _MessageContent({
    required this.message,
    required this.maxWidth,
    required this.mine,
    this.footer,
  });

  final ChatMessage message;
  final double maxWidth;
  final bool mine;
  final Widget? footer;

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
        );
      case 'voice':
        return VoiceAttachment(
          message: message,
          accent: mine ? AppColors.brandDeep : Theme.of(context).colorScheme.primary,
        );
      case 'file':
        return FileAttachment(message: message, maxWidth: maxWidth);
      default:
        final scheme = Theme.of(context).colorScheme;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinkifiedText(
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
                      color: scheme.primary.withValues(alpha: 0.35 + lift * 0.3),
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

/// Message field that swaps the mic for a send button once you start typing.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
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
        boxShadow: softShadow(opacity: 0.06, blur: 16, offset: const Offset(0, -3)),
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
                        minLines: 1,
                        maxLines: 5,
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
                          icon: hasText ? Icons.send_rounded : Icons.mic_rounded,
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

class _Ticks extends StatelessWidget {
  const _Ticks({required this.level, this.onPhoto = false});

  final int level;
  final bool onPhoto;

  @override
  Widget build(BuildContext context) {
    final muted = onPhoto ? Colors.white : Theme.of(context).colorScheme.outline;
    if (level < 0) {
      return Icon(Icons.access_time_rounded, size: 13, color: muted);
    }
    if (level == 0) return Icon(Icons.done_rounded, size: 14, color: muted);
    return Icon(
      Icons.done_all_rounded,
      size: 14,
      color: level >= 2 ? const Color(0xFF2563EB) : muted,
    );
  }
}
