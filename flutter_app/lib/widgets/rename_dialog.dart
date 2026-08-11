import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import 'avatar.dart';

/// Asks for a nickname for one person and saves it on this phone.
///
/// Returns true when the name was changed. The name people chose for themselves
/// is always shown as a reminder of who you are actually renaming.
Future<bool> showRenameContactDialog(
  BuildContext context, {
  required String username,
  required String serverName,
}) async {
  final state = context.read<AppState>();
  final current = state.contactAliases[username] ?? '';
  final controller = TextEditingController(text: current);

  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      return AlertDialog(
        title: const Text('Rename this person'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Avatar(name: serverName, seed: username, radius: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        serverName,
                        style: theme.textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '@$username',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              maxLength: 40,
              decoration: InputDecoration(
                labelText: 'Name to show',
                hintText: serverName,
                counterText: '',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.field),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => Navigator.pop(dialogContext, true),
            ),
            const SizedBox(height: 10),
            Text(
              'Only you see this name. It is saved on this phone and included in '
              'your encrypted backup.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
        actions: [
          if (current.isNotEmpty)
            TextButton(
              onPressed: () {
                controller.clear();
                Navigator.pop(dialogContext, true);
              },
              child: const Text('Use real name'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save'),
          ),
        ],
      );
    },
  );

  final result = saved ?? false;
  if (result) {
    await state.renameContact(username, controller.text);
  }
  controller.dispose();
  return result;
}
