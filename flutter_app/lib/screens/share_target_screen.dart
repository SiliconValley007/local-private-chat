import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../chat_navigation.dart';
import '../errors.dart';
import '../models.dart';
import '../services/incoming_share_service.dart';
import '../media_review.dart';
import 'media_review_screen.dart';
import '../widgets/avatar.dart';
import '../widgets/error_banner.dart';
import 'new_chat_screen.dart';

/// Chat picker shown when another app shares into Local Chat.
///
/// Deliberately a normal screen rather than a dialog: a share can carry several
/// files and the user needs the same search they have in the inbox to find the
/// right chat.
class ShareTargetScreen extends StatefulWidget {
  const ShareTargetScreen({super.key, required this.share});

  final IncomingShare share;

  @override
  State<ShareTargetScreen> createState() => _ShareTargetScreenState();
}

class _ShareTargetScreenState extends State<ShareTargetScreen> {
  final _search = TextEditingController();
  String _query = '';
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// What a shared file travels as.
  ///
  /// The sending app's mime type is trusted first because a file copied out of a
  /// content provider often has a stripped or misleading name; the extension is
  /// the fallback for providers that declare nothing useful.
  static String _typeFor(SharedFile file) {
    final byMime = file.attachmentType;
    if (byMime != 'file') return byMime;
    return AppState.attachmentTypeFor(file.name ?? file.path);
  }

  Future<void> _sendTo(Conversation conv) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final state = context.read<AppState>();
    final shareFiles = widget.share.files;
    MediaReviewResult? review;
    if (shareFiles.isNotEmpty) {
      setState(() => _sending = false);
      review = await MediaReviewScreen.open(
        context,
        files: shareFiles.map((f) => f.file).toList(),
        initialCaption: widget.share.composedText,
        defaultType: 'file',
      );
      if (!mounted) return;
      if (review == null || review.files.isEmpty) {
        setState(() => _sending = false);
        return;
      }
      setState(() => _sending = true);
    }

    final plan = planShareMediaSend(
      files: review?.files ?? const [],
      composedText: review != null
          ? (review.caption ?? '')
          : widget.share.composedText,
    );
    try {
      if (plan.files.isNotEmpty) {
        String typeForPath(String path) {
          for (final f in shareFiles) {
            if (f.path == path) return _typeFor(f);
          }
          return AppState.attachmentTypeFor(path);
        }

        if (plan.files.length == 1) {
          final file = plan.files.first;
          await state.uploadFile(
            conversationId: conv.id,
            file: file,
            type: typeForPath(file.path),
            caption: plan.caption,
          );
        } else {
          await state.uploadFiles(
            conversationId: conv.id,
            files: plan.files,
            type: 'file',
            typeOf: (File file) => typeForPath(file.path),
            caption: plan.caption,
          );
        }
      }
      if (plan.separateText != null) {
        await state.sendText(conv.id, plan.separateText!);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = friendlyMessage(e);
      });
      return;
    }
    if (!mounted) return;
    // Replaced rather than pushed: backing out of the chat should not land on a
    // picker for a share that has already been sent.
    Navigator.of(context).pushReplacement(chatRoute(conversation: conv));
  }

  /// Lets the share go to someone there is no chat with yet.
  Future<void> _pickNewChat() async {
    final conv = await Navigator.of(context).push<Conversation>(
      MaterialPageRoute(builder: (_) => const NewChatScreen()),
    );
    if (conv != null && mounted) await _sendTo(conv);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final query = _query.trim().toLowerCase();
    final conversations = state.conversations.where((c) {
      if (query.isEmpty) return true;
      return state.titleFor(c).toLowerCase().contains(query) ||
          (c.peer?.username.toLowerCase().contains(query) ?? false);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Share to'),
        actions: [
          IconButton(
            tooltip: 'New chat',
            icon: const Icon(Icons.person_add_alt_1_rounded),
            onPressed: _sending ? null : _pickNewChat,
          ),
        ],
        bottom: _sending
            ? const PreferredSize(
                preferredSize: Size.fromHeight(3),
                child: LinearProgressIndicator(minHeight: 3),
              )
            : null,
      ),
      body: Column(
        children: [
          _SharePreview(share: widget.share),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: ErrorBanner(message: _error!),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'Search chats',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
          Expanded(
            child: conversations.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'No chats here yet.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _sending ? null : _pickNewChat,
                            icon: const Icon(Icons.person_add_alt_1_rounded),
                            label: const Text('Pick someone'),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: conversations.length,
                    itemBuilder: (context, i) {
                      final conv = conversations[i];
                      final title = state.titleFor(conv);
                      return ListTile(
                        enabled: !_sending,
                        leading: Avatar(
                          name: title,
                          seed: conv.peer?.username ?? 'g${conv.id}',
                          radius: 22,
                          imageUrl: conv.peer == null
                              ? null
                              : state.avatarUrlFor(conv.peer!.id),
                          imageHeaders: state.api.imageAuthHeaders,
                        ),
                        title: Text(title),
                        subtitle: Text(
                          conv.type == 'dm'
                              ? '@${conv.peer?.username ?? ''}'
                              : '${conv.members.length} members',
                        ),
                        onTap: () => _sendTo(conv),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Shows what is about to be sent, so a mis-tapped share is obvious before a
/// chat is chosen.
class _SharePreview extends StatelessWidget {
  const _SharePreview({required this.share});

  final IncomingShare share;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = share.composedText;
    final files = share.files;
    final names = files
        .map((f) => f.name ?? f.path.split(Platform.pathSeparator).last)
        .toList();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (files.isNotEmpty)
            Row(
              children: [
                Icon(
                  Icons.attach_file_rounded,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    files.length == 1
                        ? names.first
                        : '${files.length} attachments',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              ],
            ),
          if (files.isNotEmpty && text.isNotEmpty) const SizedBox(height: 8),
          if (text.isNotEmpty)
            Text(
              text,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
        ],
      ),
    );
  }
}
