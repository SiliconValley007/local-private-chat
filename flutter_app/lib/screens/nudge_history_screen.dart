import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../nudge_log.dart';
import '../time_format.dart';
import '../widgets/error_banner.dart';
import '../widgets/loading_placeholders.dart';

/// Per-chat nudge history — sent and received pokes kept off the transcript.
class NudgeHistoryScreen extends StatefulWidget {
  const NudgeHistoryScreen({super.key, required this.conversation});

  final Conversation conversation;

  @override
  State<NudgeHistoryScreen> createState() => _NudgeHistoryScreenState();
}

class _NudgeHistoryScreenState extends State<NudgeHistoryScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppState>().refreshNudgeHistory(widget.conversation.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final conv = state.conversations.cast<Conversation?>().firstWhere(
      (c) => c?.id == widget.conversation.id,
      orElse: () => widget.conversation,
    )!;
    final items = state.nudgeHistory;
    final loading = state.nudgeHistoryLoading;
    final loadingMore = state.nudgeHistoryLoadingMore;
    final error = state.nudgeHistoryError;

    return Scaffold(
      appBar: AppBar(title: const Text('Nudge history')),
      body: loading && items.isEmpty
          ? const ListSkeleton(rows: 6, label: 'Loading nudge history')
          : Column(
              children: [
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: ErrorBanner(message: error),
                  ),
                Expanded(
                  child: items.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Text(
                              'Wave, poke, hug, or kiss someone — it shows up here, not in the chat.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : NotificationListener<ScrollNotification>(
                          onNotification: (n) {
                            if (n.metrics.pixels >
                                n.metrics.maxScrollExtent - 200) {
                              state.loadMoreNudgeHistory();
                            }
                            return false;
                          },
                          child: ListView.separated(
                            itemCount: items.length + (loadingMore ? 1 : 0),
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
                              final record = items[i];
                              final variant = NudgeVariant.parse(
                                record.variant,
                              );
                              final line = formatNudgeHistoryLine(
                                record: record,
                                viewerUserId: state.me?.id,
                                conversation: conv,
                                nameFor: state.nameFor,
                                nameForMember: state.nameForMember,
                              );
                              final isSent = record.senderId == state.me?.id;
                              return ListTile(
                                leading: Icon(
                                  nudgeHistoryIcon(variant),
                                  color: isSent
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).colorScheme.secondary,
                                ),
                                title: Text(line),
                                subtitle: Text(
                                  formatClockTime(context, record.at.toLocal()),
                                ),
                                trailing: record.pending
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Text(
                                        variant.emoji,
                                        style: const TextStyle(fontSize: 22),
                                      ),
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
