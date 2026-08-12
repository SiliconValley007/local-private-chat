import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../errors.dart';
import '../models.dart';
import '../theme.dart';
import '../time_format.dart';
import '../widgets/attachments.dart';

/// WhatsApp-style Media / Docs / Links gallery for one conversation.
///
/// Pops with a message id when the user chooses "Show in chat".
class SharedMediaScreen extends StatefulWidget {
  const SharedMediaScreen({super.key, required this.conversation});

  final Conversation conversation;

  @override
  State<SharedMediaScreen> createState() => _SharedMediaScreenState();
}

class _SharedMediaScreenState extends State<SharedMediaScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _scroll = ScrollController();

  List<SharedItem> _items = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _exhausted = false;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging) setState(() {});
    });
    _scroll.addListener(_onScroll);
    _loadInitial();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore || _exhausted) return;
    if (_scroll.position.extentAfter < 400) {
      _loadMore();
    }
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await context.read<AppState>().listShared(
        widget.conversation.id,
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _exhausted = items.length < 100;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyMessage(e);
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _exhausted || _items.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final oldest = _items
          .map((i) => i.messageId)
          .reduce((a, b) => a < b ? a : b);
      final more = await context.read<AppState>().listShared(
        widget.conversation.id,
        beforeId: oldest,
      );
      if (!mounted) return;
      final known = {
        for (final i in _items) '${i.kind}:${i.messageId}:${i.url}',
      };
      final fresh = [
        for (final i in more)
          if (!known.contains('${i.kind}:${i.messageId}:${i.url}')) i,
      ];
      setState(() {
        _items = [..._items, ...fresh];
        _loadingMore = false;
        _exhausted = more.isEmpty || more.length < 100;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  List<SharedItem> get _visible {
    final kind = switch (_tabs.index) {
      0 => 'media',
      1 => 'docs',
      _ => 'links',
    };
    final filtered = _items.where((i) => i.kind == kind);
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return filtered.toList();
    return filtered.where((i) {
      final name = (i.mediaName ?? '').toLowerCase();
      final url = (i.url ?? '').toLowerCase();
      final body = (i.body ?? '').toLowerCase();
      return name.contains(q) || url.contains(q) || body.contains(q);
    }).toList();
  }

  void _showInChat(int messageId) => Navigator.of(context).pop(messageId);

  ChatMessage _asMessage(SharedItem item, {required String type}) => ChatMessage(
    id: item.messageId,
    conversationId: widget.conversation.id,
    senderId: item.senderId,
    type: type,
    body: item.body,
    mediaName: item.mediaName,
    mediaSize: item.mediaSize,
    mediaMime: item.mediaMime,
    createdAt: item.createdAt,
  );

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _openDoc(SharedItem item) async {
    try {
      await context.read<AppState>().media.openExternally(
        _asMessage(item, type: 'file'),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendlyMessage(e))));
    }
  }

  Future<void> _viewMedia(SharedItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen(
          message: _asMessage(item, type: 'image'),
          onShowInChat: () {
            Navigator.of(context).pop(); // close viewer
            _showInChat(item.messageId);
          },
        ),
      ),
    );
  }

  Future<void> _itemActions(SharedItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item.kind == 'docs')
              ListTile(
                leading: const Icon(Icons.open_in_new_rounded),
                title: const Text('Open'),
                onTap: () => Navigator.pop(sheetContext, 'open'),
              ),
            if (item.kind == 'links')
              ListTile(
                leading: const Icon(Icons.open_in_browser_rounded),
                title: const Text('Open link'),
                onTap: () => Navigator.pop(sheetContext, 'open'),
              ),
            if (item.kind == 'media')
              ListTile(
                leading: const Icon(Icons.fullscreen_rounded),
                title: const Text('View'),
                onTap: () => Navigator.pop(sheetContext, 'view'),
              ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline_rounded),
              title: const Text('Show in chat'),
              onTap: () => Navigator.pop(sheetContext, 'chat'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'chat':
        _showInChat(item.messageId);
      case 'open':
        if (item.kind == 'links' && item.url != null) {
          await _openLink(item.url!);
        } else if (item.kind == 'docs') {
          await _openDoc(item);
        }
      case 'view':
        await _viewMedia(item);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final visible = _visible;
    final groups = _groupByMonth(visible);

    return Scaffold(
      appBar: AppBar(
        title: const Text('All media'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Media'),
            Tab(text: 'Docs'),
            Tab(text: 'Links'),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: scheme.surfaceContainerHighest.withValues(
                  alpha: 0.55,
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _loadInitial,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  )
                : visible.isEmpty
                ? Center(
                    child: Text(
                      _emptyLabel,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : _tabs.index == 0
                ? _MediaGrid(
                    groups: groups,
                    controller: _scroll,
                    loadingMore: _loadingMore,
                    onTap: _viewMedia,
                    onLongPress: _itemActions,
                  )
                : _DocsOrLinksList(
                    groups: groups,
                    controller: _scroll,
                    loadingMore: _loadingMore,
                    links: _tabs.index == 2,
                    onTap: (item) async {
                      if (item.kind == 'links' && item.url != null) {
                        await _openLink(item.url!);
                      } else {
                        await _openDoc(item);
                      }
                    },
                    onLongPress: _itemActions,
                    onShowInChat: (item) => _showInChat(item.messageId),
                  ),
          ),
        ],
      ),
    );
  }

  String get _emptyLabel => switch (_tabs.index) {
    0 => 'No photos shared yet',
    1 => 'No documents shared yet',
    _ => 'No links shared yet',
  };
}

List<({String heading, List<SharedItem> items})> _groupByMonth(
  List<SharedItem> items,
) {
  final groups = <String, List<SharedItem>>{};
  final order = <String>[];
  for (final item in items) {
    final heading = formatMonthHeading(item.createdAt);
    final bucket = groups.putIfAbsent(heading, () {
      order.add(heading);
      return <SharedItem>[];
    });
    bucket.add(item);
  }
  return [
    for (final heading in order) (heading: heading, items: groups[heading]!),
  ];
}

class _MediaGrid extends StatelessWidget {
  const _MediaGrid({
    required this.groups,
    required this.controller,
    required this.loadingMore,
    required this.onTap,
    required this.onLongPress,
  });

  final List<({String heading, List<SharedItem> items})> groups;
  final ScrollController controller;
  final bool loadingMore;
  final Future<void> Function(SharedItem item) onTap;
  final Future<void> Function(SharedItem item) onLongPress;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final headers = <String, String>{
      if (state.api.token != null) 'Authorization': 'Bearer ${state.api.token}',
    };

    return CustomScrollView(
      controller: controller,
      slivers: [
        for (final group in groups) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                group.heading,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final item = group.items[index];
                return GestureDetector(
                  onTap: () => onTap(item),
                  onLongPress: () => onLongPress(item),
                  child: Image.network(
                    state.api.mediaUrl(item.messageId),
                    headers: headers,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => ColoredBox(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
                  ),
                );
              }, childCount: group.items.length),
            ),
          ),
        ],
        if (loadingMore)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

class _DocsOrLinksList extends StatelessWidget {
  const _DocsOrLinksList({
    required this.groups,
    required this.controller,
    required this.loadingMore,
    required this.links,
    required this.onTap,
    required this.onLongPress,
    required this.onShowInChat,
  });

  final List<({String heading, List<SharedItem> items})> groups;
  final ScrollController controller;
  final bool loadingMore;
  final bool links;
  final Future<void> Function(SharedItem item) onTap;
  final Future<void> Function(SharedItem item) onLongPress;
  final void Function(SharedItem item) onShowInChat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rowCount = groups.fold<int>(0, (sum, g) => sum + 1 + g.items.length);

    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: rowCount + (loadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (loadingMore && index == rowCount) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        var cursor = 0;
        for (final group in groups) {
          if (index == cursor) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
              child: Text(
                group.heading,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
            );
          }
          cursor += 1;
          if (index < cursor + group.items.length) {
            final item = group.items[index - cursor];
            if (links) {
              final host = Uri.tryParse(item.url ?? '')?.host ?? item.url ?? '';
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(
                    Icons.link_rounded,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                title: Text(
                  item.url ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(host),
                trailing: Text(
                  formatShortDate(item.createdAt),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                onTap: () => onTap(item),
                onLongPress: () => onLongPress(item),
              );
            }

            final fake = ChatMessage(
              id: item.messageId,
              conversationId: 0,
              senderId: item.senderId,
              type: 'file',
              mediaName: item.mediaName,
              mediaSize: item.mediaSize,
              mediaMime: item.mediaMime,
              createdAt: item.createdAt,
            );
            final badge = fileBadge(fake);
            final ext = fileExtensionOf(fake);
            final size = formatFileSize(item.mediaSize);
            final meta = [
              if (ext.isNotEmpty) ext,
              if (size.isNotEmpty) size,
            ].join(' · ');
            return ListTile(
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: badge.color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(badge.icon, color: badge.color),
              ),
              title: Text(
                item.mediaName ?? 'Document',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(meta),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    formatShortDate(item.createdAt),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Show in chat',
                    icon: const Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 20,
                    ),
                    onPressed: () => onShowInChat(item),
                  ),
                ],
              ),
              onTap: () => onTap(item),
              onLongPress: () => onLongPress(item),
            );
          }
          cursor += group.items.length;
        }
        return const SizedBox.shrink();
      },
    );
  }
}
