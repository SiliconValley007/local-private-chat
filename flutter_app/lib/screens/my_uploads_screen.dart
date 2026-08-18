import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../errors.dart';
import '../models.dart';
import '../widgets/attachments.dart';

/// Review-and-select cleanup for files owned by the signed-in user.
class MyUploadsScreen extends StatefulWidget {
  const MyUploadsScreen({super.key});

  @override
  State<MyUploadsScreen> createState() => _MyUploadsScreenState();
}

class _MyUploadsScreenState extends State<MyUploadsScreen> {
  List<OwnedMedia>? _items;
  final Set<int> _selected = {};
  String? _error;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final rows = await context.read<AppState>().listMyMedia();
      if (mounted) setState(() => _items = rows);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyMessage(e));
    }
  }

  int get _selectedBytes => (_items ?? const [])
      .where((item) => _selected.contains(item.messageId))
      .fold(0, (sum, item) => sum + item.mediaSize);

  void _toggleAll() {
    final items = _items ?? const <OwnedMedia>[];
    setState(() {
      if (_selected.length == items.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(items.map((item) => item.messageId));
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty || _deleting) return;
    final count = _selected.length;
    final size = formatFileSize(_selectedBytes);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete selected uploads?'),
        content: Text(
          'This will free about $size on the server. The $count selected '
          '${count == 1 ? 'attachment' : 'attachments'} will become deleted '
          'messages for everyone in those chats. Other users’ uploads are '
          'never included.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete my uploads'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    final ids = Set<int>.of(_selected);
    try {
      final result = await context.read<AppState>().deleteMyMedia(ids);
      if (!mounted) return;
      setState(() {
        _items = (_items ?? const [])
            .where((item) => !ids.contains(item.messageId))
            .toList();
        _selected.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Deleted ${result.deleted} ${result.deleted == 1 ? 'upload' : 'uploads'} '
            'and reclaimed about ${formatFileSize(result.reclaimedBytes)}.',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('My uploads'),
        actions: [
          if (items != null && items.isNotEmpty)
            TextButton(
              onPressed: _deleting ? null : _toggleAll,
              child: Text(
                _selected.length == items.length
                    ? 'Clear selection'
                    : 'Select all',
              ),
            ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            )
          : items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'You have no uploaded media on this server.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 110),
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = items[index];
                return CheckboxListTile(
                  value: _selected.contains(item.messageId),
                  onChanged: _deleting
                      ? null
                      : (selected) => setState(() {
                          if (selected ?? false) {
                            _selected.add(item.messageId);
                          } else {
                            _selected.remove(item.messageId);
                          }
                        }),
                  secondary: _OwnedMediaPreview(item: item),
                  title: Text(
                    item.mediaName ?? _typeLabel(item.type),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${item.conversationTitle} · '
                    '${formatFileSize(item.mediaSize)} · '
                    '${DateFormat.yMMMd().format(item.createdAt.toLocal())}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  controlAffinity: ListTileControlAffinity.trailing,
                );
              },
            ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : SafeArea(
              minimum: const EdgeInsets.all(12),
              child: FilledButton.icon(
                onPressed: _deleting ? null : _deleteSelected,
                icon: _deleting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_outline_rounded),
                label: Text(
                  'Delete ${_selected.length} · '
                  '${formatFileSize(_selectedBytes)}',
                ),
              ),
            ),
    );
  }
}

String _typeLabel(String type) => switch (type) {
  'image' => 'Photo',
  'video' => 'Video',
  'voice' => 'Voice note',
  _ => 'File',
};

class _OwnedMediaPreview extends StatelessWidget {
  const _OwnedMediaPreview({required this.item});

  final OwnedMedia item;

  @override
  Widget build(BuildContext context) {
    final api = context.read<AppState>().api;
    final imageUrl = switch (item.type) {
      'image' => api.mediaUrl(item.messageId),
      'video' => api.mediaThumbnailUrl(item.messageId),
      _ => null,
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 52,
        height: 52,
        child: imageUrl == null
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Icon(
                  item.type == 'voice'
                      ? Icons.mic_rounded
                      : Icons.insert_drive_file_outlined,
                ),
              )
            : Image.network(
                imageUrl,
                headers: api.imageAuthHeaders,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Icon(
                    item.type == 'video'
                        ? Icons.videocam_outlined
                        : Icons.broken_image_outlined,
                  ),
                ),
              ),
      ),
    );
  }
}
