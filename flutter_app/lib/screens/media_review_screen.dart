import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../media_review.dart';
import '../theme.dart';

/// WhatsApp-style review after camera, gallery, or document selection.
///
/// Shows selected previews, lets the user remove or reorder them, and add an
/// optional caption that will attach to the first uploaded message only.
class MediaReviewScreen extends StatefulWidget {
  const MediaReviewScreen({
    super.key,
    required this.files,
    this.initialCaption,
    this.defaultType = 'file',
  });

  final List<File> files;
  final String? initialCaption;

  /// Fallback attachment kind when the path has no useful extension.
  final String defaultType;

  /// Opens the review sheet and returns the user's choices, or null if cancelled.
  static Future<MediaReviewResult?> open(
    BuildContext context, {
    required List<File> files,
    String? initialCaption,
    String defaultType = 'file',
  }) {
    if (files.isEmpty) return Future.value(null);
    return Navigator.of(context).push<MediaReviewResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => MediaReviewScreen(
          files: files,
          initialCaption: initialCaption,
          defaultType: defaultType,
        ),
      ),
    );
  }

  @override
  State<MediaReviewScreen> createState() => _MediaReviewScreenState();
}

class _MediaReviewScreenState extends State<MediaReviewScreen> {
  late List<File> _files;
  late final TextEditingController _caption;
  late final PageController _pageController;
  int _focusedIndex = 0;

  @override
  void initState() {
    super.initState();
    _files = List<File>.from(widget.files);
    _caption = TextEditingController(text: widget.initialCaption ?? '');
    _pageController = PageController();
  }

  @override
  void dispose() {
    _caption.dispose();
    _pageController.dispose();
    super.dispose();
  }

  String _typeFor(File file) {
    final kind = AppState.attachmentTypeFor(file.path);
    return kind == 'file' ? widget.defaultType : kind;
  }

  String _nameFor(File file) {
    final parts = file.path.split(Platform.pathSeparator);
    return parts.isEmpty ? file.path : parts.last;
  }

  void _removeAt(int index) {
    setState(() {
      _files.removeAt(index);
      if (_files.isEmpty) {
        Navigator.pop(context);
        return;
      }
      if (_focusedIndex >= _files.length) {
        _focusedIndex = _files.length - 1;
      } else if (_focusedIndex > index) {
        _focusedIndex--;
      }
    });
  }

  void _reorderItem(int oldIndex, int newIndex) {
    setState(() {
      final item = _files.removeAt(oldIndex);
      _files.insert(newIndex, item);
      _focusedIndex = newIndex;
    });
  }

  void _send() {
    if (_files.isEmpty) return;
    Navigator.pop(
      context,
      MediaReviewResult(
        files: List<File>.from(_files),
        caption: normalizeMediaCaption(_caption.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final focused = _files[_focusedIndex];
    final focusedType = _typeFor(focused);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          _files.length == 1 ? 'Send to chat' : '${_files.length} items',
        ),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              onPageChanged: (i) => setState(() => _focusedIndex = i),
              itemCount: _files.length,
              itemBuilder: (context, index) {
                final file = _files[index];
                final type = _typeFor(file);
                return _MainPreview(
                  file: file,
                  type: type,
                  name: _nameFor(file),
                );
              },
            ),
          ),
          if (_files.length > 1)
            SizedBox(
              height: 92,
              child: ReorderableListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                buildDefaultDragHandles: false,
                itemCount: _files.length,
                onReorderItem: _reorderItem,
                proxyDecorator: (child, index, animation) => Material(
                  color: Colors.transparent,
                  elevation: 6,
                  child: child,
                ),
                itemBuilder: (context, index) {
                  final file = _files[index];
                  final selected = index == _focusedIndex;
                  return ReorderableDragStartListener(
                    key: ValueKey(file.path),
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _ThumbTile(
                        file: file,
                        type: _typeFor(file),
                        selected: selected,
                        onTap: () {
                          setState(() => _focusedIndex = index);
                          _pageController.animateToPage(
                            index,
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                          );
                        },
                        onRemove: () => _removeAt(index),
                      ),
                    ),
                  );
                },
              ),
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _nameFor(focused),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                ),
              ),
            ),
          SafeArea(
            top: false,
            child: Container(
              width: double.infinity,
              color: scheme.surface,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _caption,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: focusedType == 'file'
                            ? 'Add a caption…'
                            : 'Add a caption…',
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.field),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _files.isEmpty ? null : _send,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(52, 52),
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                    ),
                    child: const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MainPreview extends StatelessWidget {
  const _MainPreview({
    required this.file,
    required this.type,
    required this.name,
  });

  final File file;
  final String type;
  final String name;

  @override
  Widget build(BuildContext context) {
    switch (type) {
      case 'image':
        return InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Center(child: Image.file(file, fit: BoxFit.contain)),
        );
      case 'video':
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.videocam_rounded,
                size: 72,
                color: Colors.white.withValues(alpha: 0.9),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
        );
      default:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.insert_drive_file_rounded,
                size: 72,
                color: Colors.white.withValues(alpha: 0.9),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
        );
    }
  }
}

class _ThumbTile extends StatelessWidget {
  const _ThumbTile({
    required this.file,
    required this.type,
    required this.selected,
    required this.onTap,
    required this.onRemove,
  });

  final File file;
  final String type;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? AppColors.brand : Colors.white24,
                width: selected ? 2.5 : 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: _ThumbContent(file: file, type: type),
          ),
          Positioned(
            top: -6,
            right: -6,
            child: Material(
              color: Colors.black87,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThumbContent extends StatelessWidget {
  const _ThumbContent({required this.file, required this.type});

  final File file;
  final String type;

  @override
  Widget build(BuildContext context) {
    if (type == 'image') {
      return Image.file(file, fit: BoxFit.cover, width: 72, height: 72);
    }
    final icon = type == 'video'
        ? Icons.videocam_rounded
        : Icons.insert_drive_file_rounded;
    return ColoredBox(
      color: Colors.white12,
      child: Center(child: Icon(icon, color: Colors.white70)),
    );
  }
}
