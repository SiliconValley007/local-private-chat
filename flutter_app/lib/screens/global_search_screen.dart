import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../chat_navigation.dart';
import '../errors.dart';
import '../models.dart';
import '../time_format.dart';

/// Cross-chat search with media-type chips. E2E DMs are searched locally.
class GlobalSearchScreen extends StatefulWidget {
  const GlobalSearchScreen({super.key});

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  final _query = TextEditingController();
  String? _mediaType;
  List<ChatMessage> _results = const [];
  bool _loading = false;
  String? _error;

  /// Bumped per search so a slow earlier answer cannot overwrite a newer one.
  /// Sweeping sealed DM history takes long enough for that to happen.
  int _generation = 0;

  static const _filters = <(String?, String)>[
    (null, 'All text'),
    ('image', 'Photos'),
    ('video', 'Videos'),
    ('file', 'Docs'),
    ('voice', 'Voice'),
    ('link', 'Links'),
  ];

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final q = _query.text.trim();
    FocusScope.of(context).unfocus();
    if (q.isEmpty && _mediaType == null) {
      setState(() {
        _generation++;
        _results = const [];
        _error = null;
      });
      return;
    }
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _results = const [];
    });
    try {
      final results = await context.read<AppState>().searchMessages(
        q,
        mediaType: _mediaType,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = friendlyMessage(e);
      });
    }
  }

  Future<void> _open(ChatMessage message) async {
    final state = context.read<AppState>();
    final conv = state.conversations.cast<Conversation?>().firstWhere(
      (c) => c?.id == message.conversationId,
      orElse: () => null,
    );
    if (conv == null) return;
    await pushChat(context, conversation: conv, initialMessageId: message.id);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search messages…',
            border: InputBorder.none,
          ),
          onSubmitted: (_) => _run(),
          onChanged: (_) {
            // Debounce lightly by only searching when empty clears results.
            if (_query.text.trim().isEmpty && _mediaType == null) {
              setState(() => _results = const []);
            }
          },
        ),
        actions: [
          IconButton(
            tooltip: 'Search',
            onPressed: _loading ? null : _run,
            icon: const Icon(Icons.search_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                for (final (value, label) in _filters) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(label),
                      selected:
                          _mediaType == value ||
                          (value == null && _mediaType == null),
                      onSelected: (_) {
                        setState(() {
                          _mediaType = value;
                        });
                        _run();
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: _results.isEmpty && !_loading
                ? Center(
                    child: Text(
                      _query.text.trim().isEmpty && _mediaType == null
                          ? 'Search across every chat you are in.'
                          : 'No matches.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: _results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final msg = _results[index];
                      final conv = state.conversations
                          .cast<Conversation?>()
                          .firstWhere(
                            (c) => c?.id == msg.conversationId,
                            orElse: () => null,
                          );
                      final title = conv == null
                          ? 'Chat'
                          : state.titleFor(conv);
                      return ListTile(
                        title: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          AppState.messagePreview(msg),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(
                          formatClockTime(context, msg.createdAt),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        onTap: () => _open(msg),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
