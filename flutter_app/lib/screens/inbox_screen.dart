import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/theme_store.dart';
import '../theme.dart';
import '../time_format.dart';
import '../widgets/avatar.dart';
import '../widgets/rename_dialog.dart';
import '../widgets/error_banner.dart';
import 'backup_screen.dart';
import 'chat_screen.dart';
import 'new_chat_screen.dart';
import 'new_group_screen.dart';
import 'qr_invite_screen.dart';
import 'server_setup_screen.dart';

class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().refreshInbox();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Conversation> _visible(AppState state, List<Conversation> all) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return all;
    return all.where((c) {
      // Match the name you gave them, the name they chose, and the username.
      final shown = state.titleFor(c).toLowerCase();
      final real = c.peer?.displayName.toLowerCase() ?? '';
      final username = c.peer?.username.toLowerCase() ?? '';
      var preview = '';
      if (c.lastMessage != null) {
        final summary = AppState.messagePreview(c.lastMessage!);
        preview = c.lastMessage!.senderId == state.me?.id
            ? 'you: $summary'
            : summary;
        preview = preview.toLowerCase();
      }
      return shown.contains(query) ||
          real.contains(query) ||
          username.contains(query) ||
          preview.contains(query);
    }).toList();
  }

  Future<void> _rename(Conversation conv) async {
    final peer = conv.peer;
    if (conv.type != 'dm' || peer == null) return;
    await showRenameContactDialog(
      context,
      username: peer.username,
      serverName: peer.displayName,
    );
  }

  Future<void> _showConversationActions(Conversation conv) async {
    final state = context.read<AppState>();
    final pinned = state.isPinned(conv.id);
    final muted = state.isMuted(conv.id);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
              ),
              title: Text(pinned ? 'Unpin' : 'Pin'),
              onTap: () => Navigator.pop(sheetContext, 'pin'),
            ),
            ListTile(
              leading: Icon(
                muted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
              ),
              title: Text(muted ? 'Unmute' : 'Mute'),
              onTap: () => Navigator.pop(sheetContext, 'mute'),
            ),
            if (conv.type == 'dm')
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline_rounded),
                title: const Text('Rename'),
                onTap: () => Navigator.pop(sheetContext, 'rename'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'pin':
        await state.togglePin(conv.id);
      case 'mute':
        await state.toggleMute(conv.id);
      case 'rename':
        await _rename(conv);
    }
  }

  Future<void> _chooseAppearance() async {
    final state = context.read<AppState>();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                'Appearance',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                'Your choice is kept until you change it again.',
                style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                  color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            // RadioGroup owns the selected value so the tick follows a change
            // made while this sheet is open.
            RadioGroup<ThemeMode>(
              groupValue: sheetContext.watch<AppState>().themeMode,
              onChanged: (picked) {
                if (picked != null) state.setThemeMode(picked);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final mode in ThemeMode.values)
                    RadioListTile<ThemeMode>(
                      value: mode,
                      title: Text(ThemeStore.labelFor(mode)),
                      secondary: Icon(_appearanceIcon(mode)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  IconData _appearanceIcon(ThemeMode mode) => switch (mode) {
    ThemeMode.light => Icons.light_mode_outlined,
    ThemeMode.dark => Icons.dark_mode_outlined,
    ThemeMode.system => Icons.brightness_auto_outlined,
  };

  Future<void> _onMenuSelected(String value) async {
    final state = context.read<AppState>();
    final navigator = Navigator.of(context);
    switch (value) {
      case 'appearance':
        await _chooseAppearance();
      case 'qr':
        await navigator.push(
          MaterialPageRoute(builder: (_) => const QrInviteScreen()),
        );
      case 'backup':
        await navigator.push(
          MaterialPageRoute(builder: (_) => const BackupScreen()),
        );
      case 'settings':
        await navigator.push(
          MaterialPageRoute(builder: (_) => const ServerSetupScreen()),
        );
      case 'logout':
        await state.logout();
    }
  }

  Future<void> _startNew() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const _SheetGlyph(
                icon: Icons.chat_bubble_rounded,
                color: AppColors.brand,
              ),
              title: const Text('New chat'),
              subtitle: const Text('Search people, contacts, or scan a QR'),
              onTap: () => Navigator.pop(sheetContext, 'dm'),
            ),
            ListTile(
              leading: const _SheetGlyph(
                icon: Icons.groups_rounded,
                color: Color(0xFF7C3AED),
              ),
              title: const Text('New group'),
              subtitle: const Text('Chat with several people at once'),
              onTap: () => Navigator.pop(sheetContext, 'group'),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    final conv = await Navigator.of(context).push<Conversation>(
      MaterialPageRoute(
        builder: (_) =>
            action == 'group' ? const NewGroupScreen() : const NewChatScreen(),
      ),
    );
    if (conv != null && mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final me = state.me;
    final conversations = _visible(state, state.conversations);
    final unreadTotal = state.conversations.fold<int>(
      0,
      (sum, c) => sum + c.unreadCount,
    );

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        title: Row(
          children: [
            if (me != null)
              Avatar(name: me.displayName, seed: me.id, radius: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Chats', style: theme.textTheme.titleLarge),
                  Text(
                    unreadTotal > 0
                        ? '$unreadTotal unread message${unreadTotal == 1 ? '' : 's'}'
                        : '@${me?.username ?? ''}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: unreadTotal > 0
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: state.refreshInbox,
            icon: const Icon(Icons.refresh_rounded),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            position: PopupMenuPosition.under,
            onSelected: _onMenuSelected,
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'appearance',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.brightness_6_outlined),
                  title: Text('Appearance'),
                ),
              ),
              PopupMenuItem(
                value: 'qr',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.qr_code_2_rounded),
                  title: Text('My invite QR'),
                ),
              ),
              PopupMenuItem(
                value: 'backup',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.cloud_upload_outlined),
                  title: Text('Backup & restore'),
                ),
              ),
              PopupMenuItem(
                value: 'settings',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.dns_outlined),
                  title: Text('Server settings'),
                ),
              ),
              PopupMenuItem(
                value: 'logout',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.logout_rounded),
                  title: Text('Log out'),
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _startNew,
        tooltip: 'Start a chat',
        child: const Icon(Icons.edit_rounded),
      ),
      body: Column(
        children: [
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: ErrorBanner(
                message: state.error!,
                onRetry: () {
                  state.clearError();
                  state.refreshInbox();
                },
              ),
            ),
          if (state.showReconnecting)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Center(
                child: Chip(
                  avatar: Icon(
                    Icons.sync_rounded,
                    size: 16,
                    color: Colors.amber.shade900,
                  ),
                  label: Text(
                    'Reconnecting to server…',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: Colors.amber.shade900,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  backgroundColor: Colors.amber.withValues(alpha: 0.14),
                  side: BorderSide(color: Colors.amber.shade700),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search chats',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  borderSide: BorderSide(color: scheme.primary, width: 1.4),
                ),
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: state.refreshInbox,
              child: conversations.isEmpty
                  ? _InboxEmptyState(
                      searching: _query.trim().isNotEmpty,
                      onStart: _startNew,
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                      itemCount: conversations.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final conv = conversations[index];
                        return _ConversationTile(
                          conversation: conv,
                          title: state.titleFor(conv),
                          timeLabel: formatListTimestamp(
                            context,
                            conv.updatedAt,
                          ),
                          online: conv.type == 'dm' && conv.peer != null
                              ? (state.onlineByUser[conv.peer!.id] ??
                                    conv.peer!.isOnline)
                              : null,
                          fromMe: conv.lastMessage?.senderId == state.me?.id,
                          pinned: state.isPinned(conv.id),
                          muted: state.isMuted(conv.id),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ChatScreen(conversation: conv),
                            ),
                          ),
                          onLongPress: () => _showConversationActions(conv),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.title,
    required this.timeLabel,
    required this.online,
    required this.fromMe,
    required this.pinned,
    required this.muted,
    required this.onTap,
    required this.onLongPress,
  });

  final Conversation conversation;
  final String title;
  final String timeLabel;
  final bool? online;
  final bool fromMe;
  final bool pinned;
  final bool muted;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// Small glyph shown before the preview for anything that isn't plain text.
  IconData? get _previewIcon {
    switch (conversation.lastMessage?.type) {
      case 'image':
        return Icons.photo_camera_rounded;
      case 'voice':
        return Icons.mic_rounded;
      case 'file':
        return Icons.insert_drive_file_rounded;
      default:
        return null;
    }
  }

  String get _previewText {
    final last = conversation.lastMessage;
    if (last == null) return 'No messages yet';
    final summary = AppState.messagePreview(last);
    return fromMe ? 'You: $summary' : summary;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unread = conversation.unreadCount;
    final isGroup = conversation.type == 'group';

    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Avatar(
                name: title,
                seed: isGroup
                    ? conversation.id
                    : (conversation.peer?.id ?? conversation.id),
                radius: 26,
                online: online,
                badge: isGroup ? Icons.group_rounded : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (pinned) ...[
                          Icon(
                            Icons.push_pin_rounded,
                            size: 14,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 4),
                        ],
                        if (muted) ...[
                          Icon(
                            Icons.notifications_off_rounded,
                            size: 14,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              fontSize: 15.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (_previewIcon != null) ...[
                          Icon(
                            _previewIcon,
                            size: 14,
                            color: unread > 0
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            _previewText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 13.5,
                              color: unread > 0
                                  ? scheme.onSurface
                                  : scheme.onSurfaceVariant,
                              fontWeight: unread > 0
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    timeLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: unread > 0 ? scheme.primary : scheme.outline,
                      fontWeight: unread > 0
                          ? FontWeight.w800
                          : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (unread > 0)
                    Container(
                      constraints: const BoxConstraints(minWidth: 22),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.unread,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text(
                        unread > 99 ? '99+' : '$unread',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: scheme.onPrimary,
                        ),
                      ),
                    )
                  else
                    const SizedBox(height: 20),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InboxEmptyState extends StatelessWidget {
  const _InboxEmptyState({required this.searching, required this.onStart});

  final bool searching;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 64, 32, 32),
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: scheme.surface,
              shape: BoxShape.circle,
              boxShadow: softShadow(
                color: scheme.primary,
                opacity: 0.16,
                blur: 26,
                offset: const Offset(0, 10),
              ),
            ),
            child: Icon(
              searching ? Icons.search_off_rounded : Icons.forum_rounded,
              size: 40,
              color: scheme.primary,
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          searching ? 'No chats match that' : 'No chats yet',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          searching
              ? 'Try a different name or username.'
              : 'Start a private conversation. Everything stays on your own Tailscale network.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        if (!searching) ...[
          const SizedBox(height: 22),
          Center(
            child: FilledButton.icon(
              onPressed: onStart,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Start a chat'),
            ),
          ),
        ],
      ],
    );
  }
}

class _SheetGlyph extends StatelessWidget {
  const _SheetGlyph({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Icon(icon, color: color, size: 21),
    );
  }
}
