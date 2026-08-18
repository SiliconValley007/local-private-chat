import 'package:flutter/material.dart';

import '../theme.dart';

/// The first thing the app paints, standing in for the Android splash window.
///
/// A cold start used to read as three unrelated screens: a black system window,
/// a gradient with a spinner in the middle, and then the inbox. The spinner was
/// the worst of it — it says "something is wrong and you are waiting" for work
/// that normally takes a moment.
///
/// This surface starts on the exact colour Android just painted and shows the
/// app's own mark, so the handover is invisible. A quiet line of text appears
/// only if the wait runs long enough to be worth explaining.
class LaunchSurface extends StatefulWidget {
  const LaunchSurface({super.key, this.hint = 'Getting things ready…'});

  /// Shown once the start is slow enough that silence would be confusing.
  final String hint;

  /// How long the launch may take before the app says anything about it.
  static const hintDelay = Duration(milliseconds: 1600);

  @override
  State<LaunchSurface> createState() => _LaunchSurfaceState();
}

class _LaunchSurfaceState extends State<LaunchSurface> {
  bool _showHint = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(LaunchSurface.hintDelay).then((_) {
      if (mounted) setState(() => _showHint = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: splashBackgroundFor(scheme.brightness),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.brand, AppColors.brandDeep],
                ),
                boxShadow: softShadow(blur: 24, opacity: 0.12),
              ),
              child: Center(
                child: Image.asset(
                  'assets/branding/chat.png',
                  width: 48,
                  height: 48,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Local Chat',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 10),
            // The slot is always reserved, so the hint fades in without moving
            // the mark that is already on screen.
            SizedBox(
              height: 20,
              child: AnimatedOpacity(
                opacity: _showHint ? 1 : 0,
                duration: const Duration(milliseconds: 300),
                child: Text(
                  widget.hint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
