import 'package:flutter/material.dart';

import '../theme.dart';

/// Gradient pairs assigned per person, so avatars stay recognisable at a glance.
const _palettes = <List<Color>>[
  [Color(0xFF34D399), Color(0xFF0E7C66)],
  [Color(0xFF60A5FA), Color(0xFF2563EB)],
  [Color(0xFFF472B6), Color(0xFFDB2777)],
  [Color(0xFFFBBF24), Color(0xFFD97706)],
  [Color(0xFFA78BFA), Color(0xFF7C3AED)],
  [Color(0xFF22D3EE), Color(0xFF0891B2)],
  [Color(0xFFFB7185), Color(0xFFE11D48)],
];

List<Color> avatarPalette(Object seed) {
  final hash = seed.toString().codeUnits.fold<int>(7, (a, b) => a * 31 + b);
  return _palettes[hash.abs() % _palettes.length];
}

/// Colour used for a sender's name inside group bubbles.
Color senderColor(Object seed) => avatarPalette(seed)[1];

String initialsFor(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.characters.first.toUpperCase();
  return (parts.first.characters.first + parts.last.characters.first)
      .toUpperCase();
}

/// Circular avatar with initials, plus an optional presence dot.
///
/// When [imageUrl] is set the photo is shown instead of initials; if it fails
/// to load or is still loading, the gradient initials show through, so the
/// avatar never collapses to a blank circle.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.name,
    required this.seed,
    this.radius = 24,
    this.online,
    this.badge,
    this.imageUrl,
    this.imageHeaders,
  });

  final String name;

  /// Stable value (user or conversation id) that picks the gradient.
  final Object seed;
  final double radius;

  /// Null hides the presence dot entirely, e.g. for groups.
  final bool? online;

  /// Small glyph drawn instead of initials, used for group avatars.
  final IconData? badge;

  /// Profile picture URL; null keeps the gradient-initials look.
  final String? imageUrl;

  /// Auth headers for the (bearer-protected) avatar request.
  final Map<String, String>? imageHeaders;

  @override
  Widget build(BuildContext context) {
    final colors = avatarPalette(seed);
    final dotSize = radius * 0.5;

    final fallback = badge != null
        ? Icon(badge, color: Colors.white, size: radius * 0.9)
        : Text(
            initialsFor(name),
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: radius * 0.72,
              letterSpacing: 0.2,
            ),
          );

    Widget content = fallback;
    if (imageUrl != null) {
      content = ClipOval(
        child: Image.network(
          imageUrl!,
          headers: imageHeaders,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => Center(child: fallback),
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : Center(child: fallback),
        ),
      );
    }

    return SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: Stack(
        children: [
          Container(
            width: radius * 2,
            height: radius * 2,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: colors,
              ),
              boxShadow: softShadow(
                color: colors.last,
                opacity: 0.28,
                blur: 12,
                offset: const Offset(0, 4),
              ),
            ),
            child: content,
          ),
          if (online == true)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: dotSize,
                height: dotSize,
                decoration: BoxDecoration(
                  color: AppColors.online,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.surface,
                    width: dotSize * 0.18,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
