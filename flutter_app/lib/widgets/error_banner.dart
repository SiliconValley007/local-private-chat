import 'package:flutter/material.dart';

/// Inline error message with the same look everywhere in the app.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({
    super.key,
    required this.message,
    this.onRetry,
    this.onDismiss,
  });

  final String message;
  final VoidCallback? onRetry;

  /// Lets the reader put the banner away. Without this, a failure that retrying
  /// cannot fix — someone leaving the tailnet, say — sits there for good.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 20, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onErrorContainer,
                height: 1.35,
              ),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 4),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
          if (onDismiss != null)
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close_rounded, size: 18),
              color: scheme.onErrorContainer,
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}
