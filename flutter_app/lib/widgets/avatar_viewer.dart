import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'avatar.dart';

/// Full-screen profile picture, the way tapping someone's photo in WhatsApp
/// opens it.
///
/// Works for a person who has no photo too: the gradient initials are shown
/// large rather than an empty black screen.
class AvatarViewerScreen extends StatefulWidget {
  const AvatarViewerScreen({
    super.key,
    required this.name,
    required this.seed,
    this.imageUrl,
    this.imageHeaders,
    this.onEdit,
  });

  final String name;

  /// Stable value (user or conversation id) picking the fallback gradient.
  final Object seed;

  final String? imageUrl;
  final Map<String, String>? imageHeaders;

  /// Shown as a pencil in the app bar; only your own picture is editable.
  final VoidCallback? onEdit;

  @override
  State<AvatarViewerScreen> createState() => _AvatarViewerScreenState();
}

class _AvatarViewerScreenState extends State<AvatarViewerScreen> {
  bool _sharing = false;

  Future<void> _share() async {
    final url = widget.imageUrl;
    if (url == null || _sharing) return;
    setState(() => _sharing = true);
    try {
      final res = await http.get(Uri.parse(url), headers: widget.imageHeaders);
      if (res.statusCode != 200) {
        throw const HttpException("That photo couldn't be fetched.");
      }
      final mime = res.headers['content-type'] ?? 'image/jpeg';
      final extension = mime.contains('png') ? 'png' : 'jpg';
      final safeName = widget.name
          .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
          .trim();
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/${safeName.isEmpty ? 'profile' : safeName}.$extension',
      );
      await file.writeAsBytes(res.bodyBytes, flush: true);
      await Share.shareXFiles([XFile(file.path, mimeType: mime)]);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("That photo couldn't be shared.")),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.imageUrl;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.black,
        title: const Text(
          'Profile picture',
          style: TextStyle(fontSize: 16, color: Colors.white),
        ),
        actions: [
          if (widget.onEdit != null)
            IconButton(
              tooltip: 'Change photo',
              onPressed: widget.onEdit,
              icon: const Icon(Icons.edit_outlined),
            ),
          if (url != null)
            IconButton(
              tooltip: 'Share',
              onPressed: _sharing ? null : _share,
              icon: _sharing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.share_outlined),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: url == null
                  ? _NoPhoto(name: widget.name, seed: widget.seed)
                  : InteractiveViewer(
                      minScale: 1,
                      maxScale: 4,
                      child: Image(
                        image: CachedNetworkImageProvider(
                          url,
                          headers: widget.imageHeaders ?? const {},
                        ),
                        fit: BoxFit.contain,
                        width: double.infinity,
                        loadingBuilder: (context, child, progress) =>
                            progress == null
                            ? child
                            : const Center(
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                ),
                              ),
                        errorBuilder: (_, _, _) => _NoPhoto(
                          name: widget.name,
                          seed: widget.seed,
                          note: "This photo couldn't be loaded.",
                        ),
                      ),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            child: Text(
              widget.name,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Large gradient initials, used when there is no photo to show.
class _NoPhoto extends StatelessWidget {
  const _NoPhoto({required this.name, required this.seed, this.note});

  final String name;
  final Object seed;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Avatar(name: name, seed: seed, radius: 84),
        const SizedBox(height: 18),
        Text(
          note ?? 'No profile photo yet',
          style: const TextStyle(color: Colors.white70),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
