import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../chat_navigation.dart';
import '../models.dart';
import '../screens/shared_media_screen.dart';
import '../theme.dart';
import '../time_format.dart';
import '../widgets/avatar.dart';
import '../widgets/avatar_viewer.dart';
import '../widgets/rename_dialog.dart';

/// WhatsApp-style contact profile opened from a DM chat header.
class ContactProfileScreen extends StatelessWidget {
  const ContactProfileScreen({super.key, required this.conversation});

  final Conversation conversation;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final conv = state.conversations.cast<Conversation?>().firstWhere(
      (c) => c?.id == conversation.id,
      orElse: () => conversation,
    )!;
    final peer = conv.peer;
    if (peer == null || conv.type != 'dm') {
      return const Scaffold(
        body: Center(child: Text('Profile is only available for direct chats')),
      );
    }

    final title = state.titleFor(conv);
    final online = state.onlineByUser[peer.id] ?? peer.isOnline;
    final seen = state.lastSeenByUser[peer.id] ?? peer.lastSeenAt;
    final presence = online
        ? 'online'
        : (seen == null ? '' : formatLastSeen(context, seen));
    final mood = peer.mood?.trim();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Contact info')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
        children: [
          Center(
            child: GestureDetector(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AvatarViewerScreen(
                    name: title,
                    seed: peer.id,
                    imageUrl: state.avatarUrlFor(peer.id),
                    imageHeaders: state.api.imageAuthHeaders,
                  ),
                ),
              ),
              child: Avatar(
                name: title,
                seed: peer.id,
                radius: 56,
                online: online,
                imageUrl: state.avatarUrlFor(peer.id),
                imageHeaders: state.api.imageAuthHeaders,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
          ),
          if (state.hasCustomName(peer.username)) ...[
            const SizedBox(height: 6),
            Center(
              child: Text(
                'Really ${peer.displayName}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          const SizedBox(height: 4),
          Center(
            child: Text(
              '@${peer.username}',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          if (presence.isNotEmpty) ...[
            const SizedBox(height: 14),
            Semantics(
              label: presence,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  presence,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: online ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
          if (mood != null && mood.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              mood,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
                color: scheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 28),
          _ActionTile(
            icon: Icons.perm_media_outlined,
            title: 'Media, links, and docs',
            onTap: () async {
              final messageId = await Navigator.of(context).push<int>(
                MaterialPageRoute(
                  builder: (_) => SharedMediaScreen(conversation: conv),
                ),
              );
              if (messageId != null && context.mounted) {
                Navigator.pop(context);
                await pushChat(
                  context,
                  conversation: conv,
                  initialMessageId: messageId,
                );
              }
            },
          ),
          _ActionTile(
            icon: Icons.drive_file_rename_outline_rounded,
            title: state.hasCustomName(peer.username)
                ? 'Change name'
                : 'Rename this person',
            subtitle: 'Only you see this name',
            onTap: () => showRenameContactDialog(
              context,
              username: peer.username,
              serverName: peer.displayName,
            ),
          ),
          _ActionTile(
            icon: Icons.call_rounded,
            title: 'Voice call',
            onTap: () => Navigator.pop(context, 'voice'),
          ),
          _ActionTile(
            icon: Icons.videocam_rounded,
            title: 'Video call',
            onTap: () => Navigator.pop(context, 'video'),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}
