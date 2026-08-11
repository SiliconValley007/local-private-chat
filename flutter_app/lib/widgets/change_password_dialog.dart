import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../errors.dart';

/// Dialog so a signed-in user can change their own login password.
Future<void> showChangePasswordDialog(BuildContext context) async {
  final current = TextEditingController();
  final next = TextEditingController();
  final confirm = TextEditingController();
  String? error;
  var busy = false;

  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            Future<void> submit() async {
              final cur = current.text;
              final neu = next.text;
              final conf = confirm.text;
              if (cur.isEmpty) {
                setLocal(() => error = 'Enter your current password.');
                return;
              }
              if (neu.length < 6) {
                setLocal(
                  () => error = 'New password must be at least 6 characters.',
                );
                return;
              }
              if (neu != conf) {
                setLocal(() => error = "The new passwords don't match.");
                return;
              }
              setLocal(() {
                busy = true;
                error = null;
              });
              try {
                await context.read<AppState>().changePassword(
                  currentPassword: cur,
                  newPassword: neu,
                );
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Password updated')),
                  );
                }
              } catch (e) {
                setLocal(() {
                  busy = false;
                  error = friendlyMessage(e);
                });
              }
            }

            return AlertDialog(
              title: const Text('Change password'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: current,
                    obscureText: true,
                    enabled: !busy,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Current password',
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: next,
                    obscureText: true,
                    enabled: !busy,
                    decoration: const InputDecoration(
                      labelText: 'New password',
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: confirm,
                    obscureText: true,
                    enabled: !busy,
                    decoration: const InputDecoration(
                      labelText: 'Confirm new password',
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => submit(),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: busy ? null : () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: busy ? null : submit,
                  child: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  } finally {
    current.dispose();
    next.dispose();
    confirm.dispose();
  }
}
