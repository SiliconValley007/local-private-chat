/// The activity log as the app sees it: one entry per action the server kept.
///
/// The screen that shows these is read-only by design — the point of the log is
/// that nobody, admin included, can rewrite it — so everything here is parsing
/// and wording, with no mutation anywhere.
library;

import 'e2e_text.dart';
import 'time_format.dart';

/// Filters offered above the log, in the order they are drawn.
const List<AuditCategory> auditCategories = [
  AuditCategory(id: 'all', label: 'Everything'),
  AuditCategory(id: 'edits', label: 'Edits'),
  AuditCategory(id: 'deletions', label: 'Deletions'),
  AuditCategory(id: 'messages', label: 'Messages'),
  AuditCategory(id: 'calls', label: 'Calls'),
  AuditCategory(id: 'accounts', label: 'Accounts'),
  AuditCategory(id: 'settings', label: 'Settings'),
  AuditCategory(id: 'reads', label: 'Read receipts'),
  AuditCategory(id: 'other', label: 'Everything else'),
];

class AuditCategory {
  const AuditCategory({required this.id, required this.label});

  final String id;
  final String label;
}

/// Whether an entry of this category is worth pulling out of the pile.
///
/// Edits and deletions are the actions that change what the chat says happened,
/// which is the whole reason this log exists, so they are drawn louder.
bool isSensitiveCategory(String category) =>
    category == 'edits' || category == 'deletions';

/// Which server permission state the app is in for the log.
class AdminStatus {
  const AdminStatus({
    required this.myUsername,
    this.adminUsername,
    this.isAdmin = false,
    this.canClaim = false,
    this.lockedByServer = false,
    this.adminDevicePinned = false,
    this.thisDeviceTrusted = false,
    this.needsDeviceTrust = false,
  });

  factory AdminStatus.fromJson(Map<String, dynamic> json) => AdminStatus(
    myUsername: (json['my_username'] as String?) ?? '',
    adminUsername: json['admin_username'] as String?,
    isAdmin: json['is_admin'] == true,
    canClaim: json['can_claim'] == true,
    lockedByServer: json['locked_by_server'] == true,
    adminDevicePinned: json['admin_device_pinned'] == true,
    thisDeviceTrusted: json['this_device_trusted'] == true,
    needsDeviceTrust: json['needs_device_trust'] == true,
  );

  final String myUsername;
  final String? adminUsername;
  final bool isAdmin;

  /// True when this account may name the admin: either nobody holds the role
  /// yet, or this account already does and is handing it on.
  final bool canClaim;

  /// The admin was pinned on the server itself, so the app must not offer to
  /// change it — it would fail, and look broken doing so.
  final bool lockedByServer;

  /// A trusted-device pin is stored; only that install may open the log.
  final bool adminDevicePinned;

  /// This phone's device id matches the pin.
  final bool thisDeviceTrusted;

  /// Admin with no pin yet — offer "Trust this phone".
  final bool needsDeviceTrust;

  bool get unclaimed => adminUsername == null || adminUsername!.isEmpty;

  /// May this phone actually fetch the activity log right now?
  bool get canReadLog {
    if (!isAdmin) return false;
    if (!adminDevicePinned) return true;
    return thisDeviceTrusted;
  }
}

/// Header counts for the log screen.
class AuditSummary {
  const AuditSummary({
    this.total = 0,
    this.lastDay = 0,
    this.edits = 0,
    this.deletions = 0,
    this.oldestAt,
  });

  factory AuditSummary.fromJson(Map<String, dynamic> json) => AuditSummary(
    total: (json['total'] as num?)?.toInt() ?? 0,
    lastDay: (json['last_day'] as num?)?.toInt() ?? 0,
    edits: (json['edits'] as num?)?.toInt() ?? 0,
    deletions: (json['deletions'] as num?)?.toInt() ?? 0,
    oldestAt: tryParseServerTime(json['oldest_at'] as String?),
  );

  final int total;
  final int lastDay;
  final int edits;
  final int deletions;
  final DateTime? oldestAt;
}

/// One recorded action.
class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.at,
    required this.action,
    required this.category,
    required this.summary,
    this.actorUserId,
    this.actorUsername,
    this.conversationId,
    this.messageId,
    this.targetUserId,
    this.beforeText,
    this.afterText,
    this.details,
    this.ip,
  });

  factory AuditEntry.fromJson(Map<String, dynamic> json) => AuditEntry(
    id: (json['id'] as num).toInt(),
    at: parseServerTime(json['at'] as String),
    action: json['action'] as String,
    category: (json['category'] as String?) ?? 'other',
    summary: (json['summary'] as String?) ?? '',
    actorUserId: (json['actor_user_id'] as num?)?.toInt(),
    actorUsername: json['actor_username'] as String?,
    conversationId: (json['conversation_id'] as num?)?.toInt(),
    messageId: (json['message_id'] as num?)?.toInt(),
    targetUserId: (json['target_user_id'] as num?)?.toInt(),
    beforeText: json['before_text'] as String?,
    afterText: json['after_text'] as String?,
    details: json['details'] as Map<String, dynamic>?,
    ip: json['ip'] as String?,
  );

  final int id;
  final DateTime at;
  final String action;
  final String category;
  final String summary;
  final int? actorUserId;
  final String? actorUsername;
  final int? conversationId;
  final int? messageId;
  final int? targetUserId;
  final String? beforeText;
  final String? afterText;
  final Map<String, dynamic>? details;
  final String? ip;

  bool get hasTextChange =>
      (beforeText != null && beforeText!.isNotEmpty) ||
      (afterText != null && afterText!.isNotEmpty);
}

/// The things only the reader's own device knows, attached at display time.
///
/// Two of them cannot come from the server by design. Nicknames live on the
/// phone, so the log can only ever be written with "chat 1"; and a direct
/// message arrives already sealed by the sender, so the log holds a token the
/// server cannot read. Both are filled in here, which is why an entry reads as a
/// sentence on a member's phone and stays opaque everywhere else.
class AuditNaming {
  const AuditNaming({
    this.myUsername,
    this.myUserId,
    this.chatName,
    this.peerName,
    this.targetName,
    this.revealedBefore,
    this.revealedAfter,
  });

  /// The account reading the log, so its own actions read as "You".
  final String? myUsername;

  /// The reader's own account id, so an account is recognised as theirs even
  /// after a rename.
  final int? myUserId;

  /// What this reader calls the chat an entry happened in.
  final String? chatName;

  /// The other person in that chat as this phone knows them — a fallback only:
  /// the server writes the parties into the entry itself, and that is what a
  /// reader is shown when the two disagree.
  final String? peerName;

  /// The username behind [AuditEntry.targetUserId], when this phone knows it.
  final String? targetName;

  /// [AuditEntry.beforeText] after this device opened it with its own key.
  final String? revealedBefore;

  /// [AuditEntry.afterText] after this device opened it with its own key.
  final String? revealedAfter;
}

/// How a moment is written for this reader, injected so the wording can be
/// tested without a widget tree.
typedef AuditTimeFormat = String Function(DateTime when);

/// The action name as a person would say it: "Message edited", "Signed in".
String auditActionLabel(String action) {
  const named = <String, String>{
    'message.sent': 'Message sent',
    'message.edited': 'Message edited',
    'message.deleted': 'Message deleted for everyone',
    'message.hidden': 'Message hidden for one person',
    'message.expired': 'Disappearing message expired',
    'media.deleted': 'Attachment deleted',
    'message.pinned': 'Message pinned',
    'message.unpinned': 'Message unpinned',
    'message.starred': 'Message starred',
    'message.unstarred': 'Message unstarred',
    'message.reacted': 'Reaction added',
    'message.reaction_removed': 'Reaction removed',
    'message.read': 'Messages read',
    'chat.nudge': 'Nudge sent',
    'account.registered': 'Account created',
    'account.signed_in': 'Signed in',
    'account.password_changed': 'Password changed',
    'account.avatar_set': 'Profile photo set',
    'account.avatar_removed': 'Profile photo removed',
    'account.mood_set': 'Mood changed',
    'account.display_name_set': 'Display name changed',
    'device.registered': 'Device registered for notifications',
    'device.removed': 'Device removed',
    'backup.saved': 'Encrypted backup saved',
    'conversation.created': 'Chat created',
    'conversation.members_added': 'Members added',
    'conversation.wallpaper_set': 'Wallpaper set',
    'conversation.wallpaper_cleared': 'Wallpaper cleared',
    'conversation.wallpaper_dimmed': 'Wallpaper dimming changed',
    'conversation.disappearing_set': 'Disappearing messages changed',
    'conversation.anniversary_set': 'Anniversary changed',
    'admin.designated': 'Admin changed',
    'admin.device_trusted': 'Admin device trusted',
    'admin.device_cleared': 'Admin device pin cleared',
    'admin.force_logout': 'User force-signed-out',
    'call.started': 'Call started',
    'call.ended': 'Call ended',
    'request.method': 'Other request',
  };
  final known = named[action];
  if (known != null) return known;
  // An action added on the server but not named here still has to read like
  // words: "media.deleted" becomes "Media deleted".
  final words = action.replaceAll('.', ' ').replaceAll('_', ' ').trim();
  if (words.isEmpty) return 'Action';
  return words[0].toUpperCase() + words.substring(1);
}

/// Who did it, for the row's second line.
///
/// Reads as "You" for the reader's own actions, and still points somewhere when
/// the account behind an entry has since been deleted.
String auditActorLabel(AuditEntry entry, {String? myUsername}) {
  final name = entry.actorUsername?.trim();
  final me = myUsername?.trim();
  if (name != null && name.isNotEmpty) {
    if (me != null && me.isNotEmpty && name.toLowerCase() == me.toLowerCase()) {
      return 'You';
    }
    return '@$name';
  }
  if (entry.actorUserId != null) {
    return 'a since-deleted account (#${entry.actorUserId})';
  }
  return 'the server itself';
}

/// The whole entry in one sentence: who, what, and which chat, in words.
///
/// The server writes what it can — "DDas set disappearing messages in chat 1 to
/// 86400" — and cannot do better, because it has neither the reader's name for
/// the chat nor any reason to translate a timer into English. Doing it here also
/// means a value is only ever spelled out for someone allowed to read it.
String auditSentence(
  AuditEntry entry, {
  AuditNaming naming = const AuditNaming(),
}) {
  final who = auditActorLabel(entry, myUsername: naming.myUsername);
  final where = _wherePhrase(entry, naming);
  final thing = _thingPhrase(entry);
  final after = entry.afterText?.trim();
  final text = switch (entry.action) {
    'message.sent' => '$who sent $thing$where',
    'message.edited' => '$who changed what a message$where said',
    'message.deleted' => '$who deleted $thing$where for everyone',
    'message.hidden' =>
      '$who removed $thing$where from their own view; '
          'everyone else still sees it',
    'message.expired' =>
      'A disappearing message$where was removed when its timer ran out',
    'media.deleted' => '$who deleted an attachment$where',
    'message.pinned' => '$who pinned a message$where',
    'message.unpinned' => '$who unpinned a message$where',
    'message.starred' => '$who starred a message$where',
    'message.unstarred' => '$who unstarred a message$where',
    'message.reacted' => '$who reacted to a message$where',
    'message.reaction_removed' => '$who took a reaction off a message$where',
    'message.read' => '$who read ${_readCount(entry)}$where',
    'chat.nudge' => '$who sent a nudge$where',
    'account.registered' => '$who created an account on this server',
    'account.signed_in' => '$who signed in',
    'account.password_changed' => '$who changed their password',
    'account.avatar_set' => '$who set a new profile photo',
    'account.avatar_removed' => '$who removed their profile photo',
    'account.mood_set' => '$who changed their mood',
    'account.display_name_set' => '$who changed their display name',
    'device.registered' => '$who allowed notifications on a device',
    'device.removed' => '$who stopped notifications on a device',
    'backup.saved' => '$who saved an encrypted backup of their chats',
    'conversation.members_added' => '$who added ${_addedPeople(entry)}$where',
    'call.started' => '$who started ${_callKind(entry)}$where',
    'call.ended' => _callEndedSentence(entry, who, where),
    'conversation.wallpaper_set' => '$who changed the wallpaper$where',
    'conversation.wallpaper_cleared' => '$who removed the wallpaper$where',
    'conversation.wallpaper_dimmed' =>
      '$who dimmed the wallpaper$where to ${_dimLabel(after)}',
    'conversation.disappearing_set' => _disappearingSentence(who, where, after),
    'conversation.anniversary_set' => after == null || after.isEmpty
        ? '$who cleared the anniversary$where'
        : '$who set the anniversary$where to ${_dateLabel(after)}',
    'admin.designated' =>
      '$who handed the activity log to '
          '${after == null || after.isEmpty ? "nobody" : "@$after"}',
    _ => _fallbackSentence(entry, naming),
  };
  return _endWithStop(text);
}

/// "a voice call" / "a video call", from what the server recorded.
String _callKind(AuditEntry entry) {
  final media = (entry.details?['media'] as String?)?.trim().toLowerCase();
  return switch (media) {
    'video' => 'a video call',
    'audio' => 'a voice call',
    _ => 'a call',
  };
}

/// A call is only "ended by" somebody when somebody hung up; a missed call was
/// ended by nothing at all, and saying otherwise would put it in their name.
String _callEndedSentence(AuditEntry entry, String who, String where) {
  final kind = _callKind(entry);
  final endedBy = (entry.details?['ended_by_user_id'] as num?)?.toInt();
  if (endedBy == null || entry.actorUserId == null) {
    // Nobody hung up, so the call itself opens the sentence.
    final opener = kind[0].toUpperCase() + kind.substring(1);
    return '$opener$where ended without anybody hanging up';
  }
  return '$who ended $kind$where';
}

String _addedPeople(AuditEntry entry) {
  final names = (entry.details?['member_usernames'] as List?)
      ?.whereType<String>()
      .map((n) => '@$n')
      .toList();
  if (names != null && names.isNotEmpty) {
    return names.length == 1 ? names.first : names.join(', ');
  }
  final count = (entry.details?['member_ids'] as List?)?.length;
  if (count == null || count == 0) return 'people';
  return count == 1 ? '1 person' : '$count people';
}

String _disappearingSentence(String who, String where, String? after) {
  if (after == null || after.isEmpty || after == 'off' || after == 'None') {
    return '$who turned disappearing messages off$where';
  }
  return '$who set messages$where to disappear after ${_timerLabel(after)}';
}

/// Anything the server named but this app has not: keep its sentence, but swap
/// the parts that are unreadable — "chat 1" for the chat's name, and the
/// reader's own username for "You".
String _fallbackSentence(AuditEntry entry, AuditNaming naming) {
  var text = entry.summary.trim();
  if (text.isEmpty) return auditActionLabel(entry.action);
  final chat = naming.chatName?.trim();
  final id = entry.conversationId;
  if (chat != null && chat.isNotEmpty && id != null) {
    text = text.replaceAll('chat $id', '“$chat”');
  }
  final me = naming.myUsername?.trim();
  if (me != null && me.isNotEmpty && text.startsWith('$me ')) {
    text = 'You ${text.substring(me.length + 1)}';
  }
  return text;
}

String _endWithStop(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return trimmed;
  if (trimmed.endsWith('.') || trimmed.endsWith('!') || trimmed.endsWith('?')) {
    return trimmed;
  }
  return '$trimmed.';
}

/// " in “Keiko”" when this phone knows the chat, and an honest identifier when
/// it does not — the log covers chats the reader may not be a member of.
String _wherePhrase(AuditEntry entry, AuditNaming naming) {
  final chat = naming.chatName?.trim();
  if (chat != null && chat.isNotEmpty) return ' in “$chat”';
  if (entry.conversationId != null) {
    return ' in a chat that is not on this phone (#${entry.conversationId})';
  }
  return '';
}

/// What kind of message an entry is about, never what it said.
String _thingPhrase(AuditEntry entry) {
  final type = entry.details?['type'] as String?;
  final name = (entry.details?['media_name'] as String?)?.trim();
  final named = name == null || name.isEmpty ? '' : ' “$name”';
  return switch (type) {
    'text' => 'a text message',
    'image' => 'a photo$named',
    'video' => 'a video$named',
    'voice' => 'a voice message',
    'audio' => 'an audio file$named',
    'file' => 'a file$named',
    'doodle' => 'a doodle',
    'call' => 'a call record',
    _ => 'a message',
  };
}

String _readCount(AuditEntry entry) {
  final count = (entry.details?['count'] as num?)?.toInt();
  if (count == null) return 'messages';
  return count == 1 ? '1 message' : '$count messages';
}

/// A disappearing timer as a person set it: "24 hours", not "86400".
String _timerLabel(String raw) {
  final seconds = int.tryParse(raw.trim());
  if (seconds == null) return raw;
  return formatSecondsAsWindow(seconds);
}

/// Seconds as the window someone would have chosen in the app.
String formatSecondsAsWindow(int seconds) {
  if (seconds <= 0) return 'off';
  if (seconds % 86400 == 0) {
    final days = seconds ~/ 86400;
    if (days == 1) return '24 hours';
    if (days % 7 == 0 && days >= 7) {
      final weeks = days ~/ 7;
      return weeks == 1 ? '7 days' : '$days days';
    }
    return '$days days';
  }
  if (seconds % 3600 == 0) {
    final hours = seconds ~/ 3600;
    return hours == 1 ? '1 hour' : '$hours hours';
  }
  if (seconds % 60 == 0) {
    final minutes = seconds ~/ 60;
    return minutes == 1 ? '1 minute' : '$minutes minutes';
  }
  return seconds == 1 ? '1 second' : '$seconds seconds';
}

/// "0.35" as the reader set it: 35%.
String _dimLabel(String? raw) {
  final value = double.tryParse(raw?.trim() ?? '');
  if (value == null) return raw?.trim() ?? 'a new level';
  return '${(value * 100).round()}%';
}

/// "2026-08-17" as "17 August 2026".
String _dateLabel(String raw) {
  final parsed = DateTime.tryParse(raw.trim());
  if (parsed == null) return raw.trim();
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${parsed.day} ${months[parsed.month - 1]} ${parsed.year}';
}

/// A before/after value, worded and ready to draw.
class AuditTextBlock {
  const AuditTextBlock({
    required this.label,
    required this.value,
    this.note,
    this.isBefore = false,
    this.sealed = false,
  });

  final String label;
  final String value;

  /// One line under the value saying where it came from, or why it cannot be
  /// shown. Encryption is the answer either way, so it is always worth saying:
  /// without it, "Not readable here" looks like the log is broken.
  final String? note;

  /// Drawn in the warning tone, because it is the version that no longer exists
  /// anywhere else.
  final bool isBefore;

  /// Still encrypted on this device.
  final bool sealed;
}

const String _openedHere =
    'Opened on this phone with your own key. The server only ever stored it '
    'encrypted.';
const String _stillSealed =
    'Encrypted by the phone that sent it. This device holds no key for that '
    'chat, so nobody here — server or admin — can open it.';
const String _sealedValue = 'Not readable on this device';

/// The before/after boxes for an entry, or nothing when it changed no text.
///
/// Which labels apply depends on the action: an edit has two versions of a
/// sentence, a deletion has only the one that is now gone, and a setting has an
/// old and a new value that are not text at all.
List<AuditTextBlock> auditTextBlocks(
  AuditEntry entry, {
  AuditNaming naming = const AuditNaming(),
}) {
  final before = entry.beforeText;
  final after = entry.afterText;
  switch (entry.action) {
    case 'message.edited':
      return [
        _messageBlock(
          'What it said before the edit',
          before,
          naming.revealedBefore,
          isBefore: true,
        ),
        _messageBlock('What it says now', after, naming.revealedAfter),
      ];
    case 'message.deleted':
    case 'message.hidden':
    case 'message.expired':
      return [
        _messageBlock(
          'What the deleted message said',
          before,
          naming.revealedBefore,
          isBefore: true,
        ),
      ];
    case 'conversation.disappearing_set':
      return _settingBlocks(
        before: before,
        after: after,
        format: (raw) => raw == 'off' || raw == 'None'
            ? 'Off'
            : formatSecondsAsWindow(int.tryParse(raw) ?? 0),
      );
    case 'conversation.wallpaper_dimmed':
      return _settingBlocks(before: before, after: after, format: _dimLabel);
    case 'conversation.anniversary_set':
      return _settingBlocks(
        before: before,
        after: after,
        format: (raw) => _dateLabel(raw),
      );
    case 'admin.designated':
      return _settingBlocks(before: before, after: after, format: (r) => '@$r');
    default:
      if (!entry.hasTextChange) return const [];
      return [
        if (before != null && before.isNotEmpty)
          _messageBlock('Before', before, naming.revealedBefore, isBefore: true),
        if (after != null && after.isNotEmpty)
          _messageBlock('After', after, naming.revealedAfter),
      ];
  }
}

/// A block holding message text, which may be sealed.
AuditTextBlock _messageBlock(
  String label,
  String? stored,
  String? revealed, {
  bool isBefore = false,
}) {
  final opened = revealed?.trim();
  if (opened != null && opened.isNotEmpty) {
    return AuditTextBlock(
      label: label,
      value: opened,
      note: _openedHere,
      isBefore: isBefore,
    );
  }
  final raw = stored?.trim();
  if (raw == null || raw.isEmpty) {
    return AuditTextBlock(
      label: label,
      value: raw == null ? 'Nothing recorded' : 'An empty message',
      isBefore: isBefore,
    );
  }
  if (isE2eCipherText(raw)) {
    return AuditTextBlock(
      label: label,
      value: _sealedValue,
      note: _stillSealed,
      isBefore: isBefore,
      sealed: true,
    );
  }
  return AuditTextBlock(label: label, value: raw, isBefore: isBefore);
}

/// Old and new values for a setting, which are never encrypted.
List<AuditTextBlock> _settingBlocks({
  required String? before,
  required String? after,
  required String Function(String raw) format,
}) {
  final was = before?.trim();
  final now = after?.trim();
  return [
    AuditTextBlock(
      label: 'It was',
      value: was == null || was.isEmpty ? 'Not set' : format(was),
      isBefore: true,
    ),
    AuditTextBlock(
      label: 'Changed to',
      value: now == null || now.isEmpty ? 'Not set' : format(now),
    ),
  ];
}

/// The handful of rows worth reading under an entry.
///
/// Everything that is only an identifier moves to [auditTechnicalRows]: the log
/// is evidence, so nothing is dropped, but a row that reads "Client id
/// 1786988864741361" does not belong in front of somebody trying to understand
/// what happened.
List<AuditDetailRow> auditFactRows(
  AuditEntry entry, {
  AuditNaming naming = const AuditNaming(),
  AuditTimeFormat? formatTime,
}) {
  final rows = <AuditDetailRow>[];
  final details = entry.details ?? const <String, dynamic>{};
  final sentAt = tryParseServerTime(details['created_at'] as String?);
  if (sentAt != null) {
    rows.add(
      AuditDetailRow(
        'That message was sent',
        formatTime?.call(sentAt) ?? sentAt.toLocal().toString(),
      ),
    );
  }
  rows.addAll(_partyRows(entry, naming));
  final attachment = (details['media_name'] as String?)?.trim();
  if (attachment != null && attachment.isNotEmpty) {
    rows.add(AuditDetailRow('Attachment', attachment));
  }
  final size = (details['media_size'] as num?)?.toInt();
  if (size != null && size > 0) {
    rows.add(AuditDetailRow('Attachment size', _bytesLabel(size)));
  }
  final duration = (details['duration_secs'] as num?)?.toInt();
  if (duration != null) {
    rows.add(AuditDetailRow('Call length', formatSecondsAsWindow(duration)));
  }
  final outcome = (details['outcome'] as String?)?.trim();
  if (outcome != null && outcome.isNotEmpty) {
    rows.add(AuditDetailRow('How the call ended', _prettyValue(outcome)));
  }
  final onBehalf = details['on_behalf_of_sender'];
  if (onBehalf == true) {
    rows.add(const AuditDetailRow('Deleted by', 'the person who sent it'));
  } else if (onBehalf == false) {
    // Somebody removing a message they did not write is the case a log exists
    // for, so it is said outright rather than left to be worked out from ids.
    rows.add(
      const AuditDetailRow('Deleted by', 'a chat admin, not the person who sent it'),
    );
  }
  return rows;
}

/// Who the people in an entry are, in plain words.
///
/// Every name here comes from what the server wrote down at the time — the
/// sender of the message, and who else was in that chat — because a phone can
/// only name chats it is still in, and an account can be renamed or removed.
/// The reader's own account always reads "You", and an account is never named as
/// "the other person" when it is the one that acted: an entry claiming a message
/// was sent to somebody who in fact sent it is worse than no entry at all.
List<AuditDetailRow> _partyRows(AuditEntry entry, AuditNaming naming) {
  final rows = <AuditDetailRow>[];
  final details = entry.details ?? const <String, dynamic>{};
  final senderId = (details['sender_id'] as num?)?.toInt();
  final senderName = (details['sender_username'] as String?)?.trim();
  if (senderId != null || (senderName != null && senderName.isNotEmpty)) {
    rows.add(
      AuditDetailRow(
        'That message was sent by',
        _personLabel(id: senderId, username: senderName, naming: naming),
      ),
    );
  }

  final otherId = (details['other_user_id'] as num?)?.toInt();
  final otherName =
      (details['other_username'] as String?)?.trim() ?? naming.peerName?.trim();
  final kind = details['chat_kind'] as String?;
  final memberCount = (details['chat_member_count'] as num?)?.toInt();
  if (details['chat_is_self'] == true) {
    rows.add(
      const AuditDetailRow('Who else is in that chat', 'nobody — it is a chat with yourself'),
    );
  } else if (kind == 'group') {
    rows.add(
      AuditDetailRow(
        'That chat',
        memberCount == null
            ? 'a group'
            : 'a group of $memberCount people',
      ),
    );
  } else if (otherId != null || (otherName != null && otherName.isNotEmpty)) {
    rows.add(
      AuditDetailRow(
        'The other person in that chat',
        _personLabel(id: otherId, username: otherName, naming: naming),
      ),
    );
  }

  // An account the action itself was aimed at, when that is somebody the rows
  // above have not already named.
  final targetId = entry.targetUserId;
  if (targetId != null &&
      targetId != entry.actorUserId &&
      targetId != senderId &&
      targetId != otherId) {
    rows.add(
      AuditDetailRow(
        _targetRowLabel(entry.action),
        _personLabel(id: targetId, username: naming.targetName, naming: naming),
      ),
    );
  }
  return rows;
}

String _targetRowLabel(String action) => switch (action) {
  'admin.force_logout' => 'Signed out of every device',
  'call.started' || 'call.ended' => 'The other person on the call',
  'conversation.created' => 'That chat was opened with',
  _ => 'This was about',
};

/// One account as this reader should see it: "You", a username, or an honest
/// number when the name is not on this phone.
String _personLabel({
  int? id,
  String? username,
  required AuditNaming naming,
}) {
  final name = username?.trim();
  final me = naming.myUsername?.trim();
  final sameId = id != null && naming.myUserId != null && id == naming.myUserId;
  final sameName =
      name != null &&
      name.isNotEmpty &&
      me != null &&
      me.isNotEmpty &&
      name.toLowerCase() == me.toLowerCase();
  if (sameId || sameName) return 'You';
  if (name != null && name.isNotEmpty) return '@$name';
  return 'account #$id';
}

/// Identifiers and addresses, kept for an investigation and folded away for
/// everyone else.
List<AuditDetailRow> auditTechnicalRows(AuditEntry entry) {
  final rows = <AuditDetailRow>[
    AuditDetailRow('Log entry', '#${entry.id}'),
    AuditDetailRow('Action code', entry.action),
    AuditDetailRow('Recorded at (UTC)', entry.at.toUtc().toIso8601String()),
  ];
  if (entry.messageId != null) {
    rows.add(AuditDetailRow('Message id', '${entry.messageId}'));
  }
  if (entry.conversationId != null) {
    rows.add(AuditDetailRow('Chat id', '${entry.conversationId}'));
  }
  if (entry.actorUserId != null) {
    rows.add(AuditDetailRow('Account id', '${entry.actorUserId}'));
  }
  if (entry.targetUserId != null) {
    rows.add(AuditDetailRow('Other account id', '${entry.targetUserId}'));
  }
  if (entry.ip != null && entry.ip!.isNotEmpty) {
    rows.add(AuditDetailRow('From address', entry.ip!));
  }
  final details = entry.details;
  if (details != null) {
    for (final key in details.keys.toList()..sort()) {
      if (_shownAsFact.contains(key)) continue;
      final value = details[key];
      if (value == null) continue;
      rows.add(AuditDetailRow(_prettyKey(key), '$value'));
    }
  }
  rows.add(AuditDetailRow('As the server wrote it', entry.summary));
  return rows;
}

/// Detail keys [auditFactRows] and [auditSentence] already account for.
const Set<String> _shownAsFact = {
  'created_at',
  'media_name',
  'media_size',
  'duration_secs',
  'outcome',
  'on_behalf_of_sender',
  'count',
  'type',
};

/// The whole entry as plain text, for pasting into a complaint or a report.
String auditClipboardText(
  AuditEntry entry, {
  AuditNaming naming = const AuditNaming(),
  AuditTimeFormat? formatTime,
}) {
  final when = formatTime?.call(entry.at) ?? entry.at.toLocal().toString();
  final lines = <String>[
    auditActionLabel(entry.action),
    auditSentence(entry, naming: naming),
    '',
    'When: $when',
    'Who: ${auditActorLabel(entry, myUsername: naming.myUsername)}',
    for (final block in auditTextBlocks(entry, naming: naming))
      '${block.label}: ${block.value}',
    for (final row in auditFactRows(
      entry,
      naming: naming,
      formatTime: formatTime,
    ))
      '${row.label}: ${row.value}',
    '',
    'Technical details',
    for (final row in auditTechnicalRows(entry)) '  ${row.label}: ${row.value}',
  ];
  return lines.join('\n');
}

class AuditDetailRow {
  const AuditDetailRow(this.label, this.value);

  final String label;
  final String value;
}

String _bytesLabel(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final rounded = size >= 10 || unit == 0
      ? size.toStringAsFixed(0)
      : size.toStringAsFixed(1);
  return '$rounded ${units[unit]}';
}

String _prettyKey(String key) {
  final words = key.replaceAll('_', ' ').trim();
  if (words.isEmpty) return key;
  return words[0].toUpperCase() + words.substring(1);
}

String _prettyValue(String value) {
  final words = value.replaceAll('_', ' ').trim();
  if (words.isEmpty) return value;
  return words[0].toUpperCase() + words.substring(1);
}

/// True when the newest page came back short, i.e. there is nothing older.
bool auditReachedEnd({required int received, required int pageSize}) =>
    received < pageSize;
