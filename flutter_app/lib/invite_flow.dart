import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app_config.dart';
import 'app_state.dart';
import 'errors.dart';
import 'models.dart';

/// Turns a scanned, pasted, or tapped invite into an open DM.
///
/// An invite from someone on a different server is the normal case for a phone
/// that has never been set up, so switching the address is offered here rather
/// than sending the user to Server settings to copy it by hand.
Future<Conversation?> acceptInvite(BuildContext context, Invite invite) async {
  final state = context.read<AppState>();

  if (invite.pointsElsewhere(state.api.baseUrl)) {
    final switchServer = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Use this server?'),
        content: Text(
          '@${invite.username} invited you to\n${invite.serverUrl}\n\n'
          'This phone currently uses\n${state.api.baseUrl ?? 'no server'}\n\n'
          'You still need Tailscale connected to reach it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep mine'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Use theirs'),
          ),
        ],
      ),
    );
    if (switchServer == true) {
      await state.applyInviteServer(invite);
    }
  }

  final conv = await state.openDmFromInvite(invite);
  if (conv == null && context.mounted) {
    // Held for later: no account yet, or the server is still out of reach.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          state.isLoggedIn
              ? 'Saved @${invite.username}. The chat opens once the server is reachable.'
              : 'Server saved. Sign in and @${invite.username} opens by itself.',
        ),
      ),
    );
  }
  return conv;
}

/// Reads an invite from the clipboard and accepts it.
///
/// Returns null when the clipboard holds nothing usable; the caller shows why.
Future<Conversation?> acceptInviteFromClipboard(BuildContext context) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final invite = AppConfig.parseInvite(data?.text ?? '');
  if (invite == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No invite link on the clipboard. Copy a localchat:// link first.',
          ),
        ),
      );
    }
    return null;
  }
  if (!context.mounted) return null;
  try {
    return await acceptInvite(context, invite);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendlyMessage(e))));
    }
    return null;
  }
}
