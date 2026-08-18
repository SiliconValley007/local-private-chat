import 'package:flutter/material.dart';

/// Paints a chat's shared wallpaper behind the transcript.
///
/// The wallpaper lives on the server so everyone in the chat sees the same
/// image; this widget just fetches it with the caller's auth headers. With no
/// wallpaper set the child is returned untouched so the default theme surface
/// shows through.
class ChatBackground extends StatelessWidget {
  const ChatBackground({
    super.key,
    required this.imageUrl,
    required this.headers,
    required this.dim,
    required this.child,
  });

  /// Authenticated, version-busted wallpaper URL, or null for the theme default.
  final String? imageUrl;
  final Map<String, String> headers;

  /// How much to darken the image (0..0.8) so message text stays readable.
  final double dim;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    if (url == null || url.trim().isEmpty) return child;

    return Stack(
      fit: StackFit.expand,
      children: [
        // A wallpaper the server can't serve (offline, deleted) must not blank
        // the chat, so failures fall back to the plain surface.
        Image.network(
          url,
          key: ValueKey(url),
          headers: headers,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) =>
              ColoredBox(color: Theme.of(context).colorScheme.surface),
        ),
        if (dim > 0) ColoredBox(color: Colors.black.withValues(alpha: dim)),
        child,
      ],
    );
  }
}
