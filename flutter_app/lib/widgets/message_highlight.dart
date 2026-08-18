import 'package:flutter/material.dart';

/// Duration a jumped-to message stays lit before fading back.
///
/// Long enough to survive the eye travelling from the tap to the arriving row,
/// short enough that it never becomes part of the wallpaper.
const Duration messageHighlightHold = Duration(milliseconds: 2600);

/// How long the band takes to appear, and to fade once its hold is up.
const Duration messageHighlightFadeIn = Duration(milliseconds: 180);
const Duration messageHighlightFadeOut = Duration(milliseconds: 520);

/// Band of colour that flashes behind a message you were sent to.
///
/// Arriving at a message is only half the job: WhatsApp also says *which* one,
/// because a transcript of similar bubbles gives the eye nothing to land on.
/// The tint used to live in the bubble's own decoration, which meant a photo
/// painted straight over it and a doodle — drawn without a bubble at all —
/// showed nothing whatsoever.
///
/// Sitting behind the whole row instead, the flash reads the same for text,
/// attachments, drawings and call logs alike, and it spans the full width so it
/// is visible however narrow the bubble happens to be.
class MessageHighlight extends StatelessWidget {
  const MessageHighlight({
    required this.active,
    required this.child,
    super.key,
  });

  /// Whether this row is the one that was jumped to.
  final bool active;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A faint tint was easy to miss against a busy wallpaper on a dark theme, so
    // the band carries a border as well: colour alone was doing too much work.
    return AnimatedContainer(
      // Quick to arrive with the row, unhurried on the way out.
      duration: active ? messageHighlightFadeIn : messageHighlightFadeOut,
      curve: active ? Curves.easeOut : Curves.easeIn,
      decoration: BoxDecoration(
        color: active
            ? scheme.primary.withValues(alpha: 0.28)
            : Colors.transparent,
        border: Border.all(
          color: active
              ? scheme.primary.withValues(alpha: 0.55)
              : Colors.transparent,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}
