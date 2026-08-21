import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../message_info.dart';
import '../message_preview.dart';
import '../models.dart';
import '../theme.dart';
import '../time_format.dart';
import '../widgets/avatar.dart';

/// WhatsApp-style delivery details for a message sent by this account.
class MessageInfoScreen extends StatefulWidget {
  const MessageInfoScreen({
    super.key,
    required this.message,
    required this.conversation,
  });

  final ChatMessage message;
  final Conversation conversation;

  @override
  State<MessageInfoScreen> createState() => _MessageInfoScreenState();
}

class _MessageInfoScreenState extends State<MessageInfoScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppState>().syncInBackground(
        widget.conversation.id,
        markRead: false,
      );
    });
  }

  Map<int, String> _recipientNames(AppState state) {
    final meId = state.me?.id;
    if (widget.conversation.type == 'dm') {
      final peer = widget.conversation.peer;
      return peer == null
          ? const {}
          : {peer.id: state.titleFor(widget.conversation)};
    }
    return {
      for (final member in widget.conversation.members)
        if (member.userId != meId) member.userId: state.nameForMember(member),
    };
  }

  String _when(BuildContext context, DateTime? value) =>
      value == null ? '—' : formatMomentWithDay(context, value);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final message = state.messageForInfo(widget.message, widget.conversation);
    final recipients = messageRecipientInfo(
      message: message,
      recipientNames: _recipientNames(state),
    );
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Message info')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
            color: AppColors.chatCanvasFor(context),
            child: Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.76,
                ),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 9),
                  decoration: BoxDecoration(
                    color: bubbleFillFor(
                      context: context,
                      mine: true,
                      hasWallpaper: false,
                    ),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(AppRadius.bubble),
                      topRight: Radius.circular(AppRadius.bubble),
                      bottomLeft: Radius.circular(AppRadius.bubble),
                      bottomRight: Radius.circular(7),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          chatMessagePreview(
                            message,
                            viewerUserId: state.me?.id,
                          ),
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        formatClockTime(context, message.createdAt),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (recipients.length == 1) ...[
            _InfoStatusTile(
              icon: Icons.done_all_rounded,
              title: 'Read',
              value: _when(context, recipients.single.readAt),
              iconColor: messageInfoStatusColor(
                readRow: true,
                reached: recipients.single.hasRead,
                muted: scheme.outline,
              ),
            ),
            const Divider(height: 1, indent: 24, endIndent: 24),
            _InfoStatusTile(
              icon: Icons.done_all_rounded,
              title: 'Delivered',
              value: _when(context, recipients.single.effectiveDeliveredAt),
              iconColor: messageInfoStatusColor(
                readRow: false,
                reached: recipients.single.hasDelivered,
                muted: scheme.outline,
              ),
            ),
          ] else ...[
            const _SectionLabel('Recipient status'),
            for (final recipient in recipients)
              ListTile(
                leading: Avatar(
                  name: recipient.name,
                  seed: recipient.userId,
                  radius: 21,
                  imageUrl: state.avatarUrlFor(recipient.userId),
                  imageHeaders: state.api.imageAuthHeaders,
                ),
                title: Text(recipient.name),
                subtitle: Text(
                  recipient.hasRead
                      ? 'Read ${_when(context, recipient.readAt)}'
                      : recipient.hasDelivered
                      ? 'Delivered ${_when(context, recipient.effectiveDeliveredAt)}'
                      : 'Sent · waiting for delivery',
                ),
                trailing: Icon(
                  recipient.hasRead
                      ? Icons.done_all_rounded
                      : recipient.hasDelivered
                      ? Icons.done_all_rounded
                      : Icons.done_rounded,
                  color: messageInfoStatusColor(
                    readRow: recipient.hasRead,
                    reached: recipient.hasRead || recipient.hasDelivered,
                    muted: scheme.outline,
                  ),
                ),
              ),
          ],
          const Divider(height: 1, indent: 24, endIndent: 24),
          ListTile(
            leading: const Icon(Icons.schedule_rounded),
            title: const Text('Sent'),
            subtitle: Text(formatMomentWithDay(context, message.createdAt)),
          ),
        ],
      ),
    );
  }
}

class _InfoStatusTile extends StatelessWidget {
  const _InfoStatusTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.iconColor,
  });

  final IconData icon;
  final String title;
  final String value;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      leading: Icon(icon, color: iconColor),
      title: Text(title),
      subtitle: Text(value),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
