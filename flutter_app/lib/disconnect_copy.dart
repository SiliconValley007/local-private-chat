// Inbox and chat presence when they are not on this server, or were removed.

String? disconnectSubtitle({
  required bool removed,
  bool unreachable = false,
  bool notOnTailnet = false,
  bool serverAccessRevoked = false,
  bool tailnetPending = false,
}) {
  if (removed) return 'Removed';
  if (serverAccessRevoked) return 'Server access revoked';
  if (notOnTailnet) return 'Not on this tailnet';
  // Never seen here yet, which is a different fact from having left. A phone
  // that is simply switched off must not be reported as removed from the
  // tailnet, so this says what is actually true and what would change it.
  if (tailnetPending) return 'Waiting for them to connect';
  if (unreachable) return null;
  return null;
}

/// Why the composer is closed, or null when the chat can be written in.
///
/// Named, because "This account is not on this tailnet" sitting under your own
/// chat reads as though *you* were the one removed from the tailnet.
/// Note that a chat can be written in, but has nowhere to arrive yet.
///
/// Not a closed composer. Someone the admin has put on the tailnet but who has
/// not opened the app here is in exactly the position of a contact whose phone
/// is switched off: the message waits. Refusing to let the first message be
/// written would mean nobody can ever be the first to say hello.
String? pendingDeliveryNote({
  required bool tailnetPending,
  String? peerName,
}) {
  if (!tailnetPending) return null;
  final who = (peerName == null || peerName.trim().isEmpty)
      ? 'They'
      : peerName.trim();
  return '$who has not opened Local Chat here yet. Messages wait until they '
      'do.';
}

String? composerClosedReason({
  required bool removed,
  required bool notOnTailnet,
  bool serverAccessRevoked = false,
  String? peerName,
}) {
  if (removed) return "This contact was removed. You can't send messages.";
  if (serverAccessRevoked) {
    final who = (peerName == null || peerName.trim().isEmpty)
        ? "This contact's"
        : "${peerName.trim()}'s";
    return "$who access to this server was revoked. You can't send messages "
        'unless the server is shared with them again.';
  }
  if (notOnTailnet) {
    final who = (peerName == null || peerName.trim().isEmpty)
        ? 'This contact'
        : peerName.trim();
    return "$who is not on this tailnet. You can't send messages until they "
        'rejoin it.';
  }
  return null;
}

// Severing a chat is an in-app act. Saying so plainly stops anyone reading it
// as a change to who can reach the tailnet, which only the Tailscale console
// decides.

const String tailscaleUnchangedNote = 'Does not change Tailscale access';

const String deleteChatConfirm =
    'Delete this chat for you? Your copy of the messages goes, theirs stays. '
    'This does not change Tailscale access.';

const String deleteChatEveryoneConfirm =
    'Delete this chat? "Just for me" removes your copy only; "For both of us" '
    'removes it for both people. This does not change Tailscale access.';

const String removeContactConfirm =
    'Remove this contact? They can no longer message you here, and the chat '
    'history you keep is untouched. This does not change Tailscale access — '
    'use the Tailscale console for that.';
