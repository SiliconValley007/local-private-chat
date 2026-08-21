import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../call_log.dart';
import '../chat_navigation.dart';
import '../errors.dart';
import '../models.dart';
import '../theme.dart';
import '../time_format.dart';
import 'call_screen.dart';

enum _CallFilter { all, missed }

/// One place for incoming, outgoing, missed, and completed calls.
class CallsScreen extends StatefulWidget {
  const CallsScreen({super.key});

  @override
  State<CallsScreen> createState() => _CallsScreenState();
}

class _CallsScreenState extends State<CallsScreen> {
  List<ChatMessage> _calls = const [];
  bool _loading = true;
  String? _error;
  _CallFilter _filter = _CallFilter.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final calls = await context.read<AppState>().listCallLogs();
      if (!mounted) return;
      setState(() {
        _calls = calls;
        _loading = false;
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyMessage(failure);
      });
    }
  }

  List<ChatMessage> get _visible {
    if (_filter == _CallFilter.all) return _calls;
    return [
      for (final message in _calls)
        if (parseCallLogBody(message.body).isNegative) message,
    ];
  }

  Future<void> _startCall(
    BuildContext context,
    Conversation conversation, {
    required bool video,
  }) async {
    final state = context.read<AppState>();
    if (conversation.type != 'dm' || conversation.peer == null) return;
    try {
      await state.calls.startOutgoing(
        conversationId: conversation.id,
        media: video ? 'video' : 'audio',
        peerName: state.titleFor(conversation),
        peerUserId: conversation.peer?.id,
      );
      if (context.mounted) await presentCallScreen(context);
    } catch (failure) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendlyMessage(failure))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final visible = _visible;
    return Scaffold(
      appBar: AppBar(title: const Text('Calls')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<_CallFilter>(
                segments: const [
                  ButtonSegment(
                    value: _CallFilter.all,
                    icon: Icon(Icons.call_rounded),
                    label: Text('All'),
                  ),
                  ButtonSegment(
                    value: _CallFilter.missed,
                    icon: Icon(Icons.phone_missed_rounded),
                    label: Text('Missed'),
                  ),
                ],
                selected: {_filter},
                onSelectionChanged: (picked) {
                  setState(() => _filter = picked.first);
                },
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? ListView(
                      padding: const EdgeInsets.all(32),
                      children: [
                        const Icon(Icons.cloud_off_rounded, size: 44),
                        const SizedBox(height: 12),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        Center(
                          child: FilledButton.tonal(
                            onPressed: _load,
                            child: const Text('Try again'),
                          ),
                        ),
                      ],
                    )
                  : visible.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(40),
                      children: [
                        Icon(
                          _filter == _CallFilter.missed
                              ? Icons.phone_in_talk_rounded
                              : Icons.call_outlined,
                          size: 52,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          _filter == _CallFilter.missed
                              ? 'No missed calls'
                              : 'No calls yet',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 5),
                      itemBuilder: (context, index) {
                        final message = visible[index];
                        final info = parseCallLogBody(message.body);
                        final conversation = state.conversationById(
                          message.conversationId,
                        );
                        final mine = message.senderId == state.me?.id;
                        final title = conversation == null
                            ? 'Chat'
                            : state.titleFor(conversation);
                        final direction = mine ? 'Outgoing' : 'Incoming';
                        final subtitle =
                            '$direction · ${formatCallLogPreview(info)}';
                        final negative = info.isNegative;
                        return Material(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(AppRadius.card),
                          child: ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadius.card,
                              ),
                            ),
                            leading: CircleAvatar(
                              backgroundColor:
                                  (negative
                                          ? Theme.of(context).colorScheme.error
                                          : Theme.of(
                                              context,
                                            ).colorScheme.primary)
                                      .withValues(alpha: 0.12),
                              child: Icon(
                                callLogIcon(info),
                                color: negative
                                    ? Theme.of(context).colorScheme.error
                                    : Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            title: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: conversation?.type == 'dm'
                                ? IconButton(
                                    tooltip: info.isVideo
                                        ? 'Video call $title'
                                        : 'Voice call $title',
                                    onPressed: () => _startCall(
                                      context,
                                      conversation!,
                                      video: info.isVideo,
                                    ),
                                    icon: Icon(
                                      info.isVideo
                                          ? Icons.videocam_rounded
                                          : Icons.call_rounded,
                                    ),
                                  )
                                : Text(
                                    formatListTimestamp(
                                      context,
                                      message.createdAt,
                                    ),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelSmall,
                                  ),
                            onTap: conversation == null
                                ? null
                                : () => pushChat(
                                    context,
                                    conversation: conversation,
                                    initialMessageId: message.id,
                                  ),
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
