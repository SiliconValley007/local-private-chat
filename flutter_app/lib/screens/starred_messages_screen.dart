import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../chat_navigation.dart';
import '../errors.dart';
import '../message_preview.dart';
import '../models.dart';
import '../time_format.dart';
import '../widgets/error_banner.dart';
import '../widgets/loading_placeholders.dart';

/// Private bookmarks for this account — WhatsApp-style starred messages.
class StarredMessagesScreen extends StatefulWidget {
  const StarredMessagesScreen({super.key});

  @override
  State<StarredMessagesScreen> createState() => _StarredMessagesScreenState();
}

class _StarredMessagesScreenState extends State<StarredMessagesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().refreshStarredList();
    });
  }

  Future<void> _open(ChatMessage message) async {
    final state = context.read<AppState>();
    final conv = state.conversations.cast<Conversation?>().firstWhere(
      (c) => c?.id == message.conversationId,
      orElse: () => null,
    );
    if (conv == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That chat is no longer available.')),
      );
      return;
    }
    await pushChat(context, conversation: conv, initialMessageId: message.id);
  }

  Future<void> _confirmUnstar(AppState state, ChatMessage msg) async {
    final unstar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unstar message?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unstar'),
          ),
        ],
      ),
    );
    if (unstar != true || !mounted) return;
    try {
      await state.unstarMessage(msg);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendlyMessage(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final items = state.starredMessages;
    return Scaffold(
      appBar: AppBar(title: const Text('Starred messages')),
      // Stand-in rows rather than a bare spinner, so the screen keeps its shape
      // while the list arrives instead of jumping from a dot to a full list.
      body: state.starredLoading
          ? const ListSkeleton(label: 'Loading starred messages')
          : Column(
              children: [
                if (state.starredError != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: ErrorBanner(message: state.starredError!),
                  ),
                Expanded(
                  child: items.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Text(
                              'Star important messages to find them here later.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : NotificationListener<ScrollNotification>(
                          onNotification: (n) {
                            if (n.metrics.pixels >
                                n.metrics.maxScrollExtent - 200) {
                              state.loadMoreStarred();
                            }
                            return false;
                          },
                          child: ListView.separated(
                            itemCount:
                                items.length +
                                (state.starredLoadingMore ? 1 : 0),
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, i) {
                              if (i >= items.length) {
                                return const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }
                              final msg = items[i];
                              final conv = state.conversations
                                  .cast<Conversation?>()
                                  .firstWhere(
                                    (c) => c?.id == msg.conversationId,
                                    orElse: () => null,
                                  );
                              final chatTitle = conv == null
                                  ? 'Chat'
                                  : state.titleFor(conv);
                              final sender = () {
                                if (msg.senderId == state.me?.id) {
                                  return 'You';
                                }
                                if (conv != null) {
                                  for (final m in conv.members) {
                                    if (m.userId == msg.senderId) {
                                      return state.nameForMember(m);
                                    }
                                  }
                                }
                                return 'Someone';
                              }();
                              return ListTile(
                                leading: Icon(
                                  msg.isDeleted
                                      ? Icons.block_rounded
                                      : Icons.star_rounded,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                title: Text(
                                  chatMessagePreview(msg),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '$chatTitle · $sender · ${formatClockTime(context, msg.createdAt)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => _open(msg),
                                onLongPress: () => _confirmUnstar(state, msg),
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
