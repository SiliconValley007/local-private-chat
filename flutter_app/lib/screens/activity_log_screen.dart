import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../audit.dart';
import '../e2e_text.dart';
import '../errors.dart';
import '../theme.dart';
import '../time_format.dart';
import '../widgets/error_banner.dart';
import '../widgets/loading_placeholders.dart';

/// The server's record of everything anybody did, for the admin account.
///
/// Read-only on purpose. Messages can be edited and deleted in a chat, so if the
/// chat were the only account of what happened, the past could be rewritten;
/// this is the copy that cannot be, and letting anyone prune it from here would
/// undo the point of keeping it.
class ActivityLogScreen extends StatefulWidget {
  const ActivityLogScreen({super.key});

  @override
  State<ActivityLogScreen> createState() => _ActivityLogScreenState();
}

class _ActivityLogScreenState extends State<ActivityLogScreen> {
  static const _pageSize = 50;

  final _scroll = ScrollController();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  AdminStatus? _status;
  AuditSummary? _summary;
  final List<AuditEntry> _entries = [];

  String _category = 'all';
  String _query = '';
  bool _loading = true;
  bool _loadingMore = false;
  bool _end = false;
  String? _error;
  Timer? _debounce;

  /// Bumped for every fresh query so a slow reply from an old filter cannot
  /// overwrite the list the reader is looking at now.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  ApiClient get _api => context.read<AppState>().api;

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var status = await _api.fetchAdminStatus();
      if (!mounted || generation != _generation) return;
      setState(() => _status = status);
      if (!status.isAdmin) {
        setState(() {
          _loading = false;
          _entries.clear();
          _summary = null;
        });
        return;
      }
      // Admin on a phone that is not the trusted device still sees the setup
      // card (and how to unlock), but must not pull the log itself.
      if (!status.canReadLog) {
        setState(() {
          _loading = false;
          _entries.clear();
          _summary = null;
        });
        return;
      }
      // First successful open pins this install so a second phone of the same
      // account cannot quietly read the log afterwards.
      if (status.needsDeviceTrust) {
        status = await _api.setAdminDevice(clear: false);
        if (!mounted || generation != _generation) return;
        setState(() => _status = status);
      }
      final results = await Future.wait([
        _api.fetchAuditSummary(),
        _api.listAuditEvents(
          category: _category,
          query: _query,
          limit: _pageSize,
        ),
      ]);
      if (!mounted || generation != _generation) return;
      setState(() {
        _summary = results[0] as AuditSummary;
        _entries
          ..clear()
          ..addAll(results[1] as List<AuditEntry>);
        _end = auditReachedEnd(received: _entries.length, pageSize: _pageSize);
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = friendlyMessage(error));
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loading || _loadingMore || _end) return;
    final position = _scroll.position;
    if (position.pixels > position.maxScrollExtent - 400) _loadMore();
  }

  Future<void> _loadMore() async {
    if (_entries.isEmpty) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final older = await _api.listAuditEvents(
        beforeId: _entries.last.id,
        category: _category,
        query: _query,
        limit: _pageSize,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries.addAll(older);
        _end = auditReachedEnd(received: older.length, pageSize: _pageSize);
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = friendlyMessage(error));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() => _query = value);
      _load();
    });
  }

  void _pickCategory(String id) {
    if (_category == id) return;
    setState(() => _category = id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity log'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => _searchFocus.unfocus(),
          child: _body(status),
        ),
      ),
    );
  }

  Widget _body(AdminStatus? status) {
    if (_loading && status == null) {
      return const ListSkeleton(rows: 5, label: 'Opening the activity log');
    }
    if (status != null && !status.isAdmin) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          if (_error != null) ...[
            ErrorBanner(message: _error!),
            const SizedBox(height: 12),
          ],
          _AdminSetupCard(status: status, onChanged: _load),
        ],
      );
    }
    if (status != null && status.isAdmin && !status.canReadLog) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          if (_error != null) ...[
            ErrorBanner(message: _error!),
            const SizedBox(height: 12),
          ],
          _AdminSetupCard(status: status, onChanged: _load),
        ],
      );
    }

    final summary = _summary;
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
      itemCount: _entries.length + 2 + (_loadingMore ? 1 : 0),
      separatorBuilder: (_, index) =>
          SizedBox(height: index == 0 || index == 1 ? 12 : 8),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_error != null) ...[
                ErrorBanner(message: _error!),
                const SizedBox(height: 12),
              ],
              if (summary != null) _SummaryCard(summary: summary),
              if (status != null) ...[
                const SizedBox(height: 12),
                _AdminSetupCard(status: status, onChanged: _load),
              ],
            ],
          );
        }
        if (index == 1) return _filters();
        final entryIndex = index - 2;
        if (entryIndex >= _entries.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return _AuditRow(entry: _entries[entryIndex]);
      },
    );
  }

  Widget _filters() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const Key('activity-log-search'),
          controller: _searchController,
          focusNode: _searchFocus,
          textInputAction: TextInputAction.search,
          onChanged: _onSearchChanged,
          onTapOutside: (_) => _searchFocus.unfocus(),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded),
            hintText: 'Search text, usernames, or actions',
            suffixIcon: _searchController.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      _searchController.clear();
                      _searchFocus.unfocus();
                      setState(() => _query = '');
                      _load();
                    },
                  ),
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final category in auditCategories)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(category.label),
                    selected: _category == category.id,
                    onSelected: (_) => _pickCategory(category.id),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        if (!_loading && _entries.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Center(
              child: Text(
                'Nothing recorded for this filter yet.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Counts at the top: how much is on record, and how much of it rewrote history.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final AuditSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final oldest = summary.oldestAt;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history_rounded, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  'On record',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _Stat(value: summary.total, label: 'actions'),
                _Stat(value: summary.lastDay, label: 'last 24 hours'),
                _Stat(
                  value: summary.edits,
                  label: 'edits',
                  tone: scheme.tertiary,
                ),
                _Stat(
                  value: summary.deletions,
                  label: 'deletions',
                  tone: scheme.error,
                ),
              ],
            ),
            if (oldest != null) ...[
              const SizedBox(height: 10),
              Text(
                'Oldest entry ${formatMomentWithDay(context, oldest)}.',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.tone});

  final int value;
  final String label;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tone ?? theme.colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$value',
            style: theme.textTheme.titleMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Who holds the admin role, and the one control that changes it.
class _AdminSetupCard extends StatefulWidget {
  const _AdminSetupCard({required this.status, required this.onChanged});

  final AdminStatus status;
  final Future<void> Function() onChanged;

  @override
  State<_AdminSetupCard> createState() => _AdminSetupCardState();
}

class _AdminSetupCardState extends State<_AdminSetupCard> {
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = widget.status;
    final holder = status.unclaimed ? 'nobody yet' : '@${status.adminUsername}';

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.admin_panel_settings_rounded,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Admin',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('The log is readable by $holder.'),
            const SizedBox(height: 4),
            Text(
              status.lockedByServer
                  ? 'Set on the server itself, so it cannot be changed from the app.'
                  : status.isAdmin &&
                        status.adminDevicePinned &&
                        !status.thisDeviceTrusted
                  ? 'Another phone is trusted for the activity log. Open it there, or clear the pin from the server with SetAdmin.'
                  : status.isAdmin
                  ? 'You can hand this over to another username, trust this phone, or sign someone out.'
                  : status.canClaim
                  ? 'Nobody has claimed it. Claim it with your own username.'
                  : 'Ask @${status.adminUsername} if you need access.',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (status.isAdmin) ...[
              const SizedBox(height: 8),
              Text(
                status.thisDeviceTrusted
                    ? 'This phone is the trusted admin device.'
                    : status.needsDeviceTrust
                    ? 'Trust this phone so only this install can open the log.'
                    : status.adminDevicePinned
                    ? 'This phone is not the trusted admin device.'
                    : 'No trusted device pin is set yet.',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (status.canClaim && !status.lockedByServer) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  key: const Key('activity-log-set-admin'),
                  onPressed: _saving ? null : _promptForUsername,
                  icon: const Icon(Icons.person_outline_rounded, size: 18),
                  label: Text(
                    status.unclaimed ? 'Claim as admin' : 'Change the admin',
                  ),
                ),
              ),
            ],
            if (status.isAdmin &&
                (status.needsDeviceTrust || !status.adminDevicePinned)) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  key: const Key('activity-log-trust-device'),
                  onPressed: _saving ? null : () => _trustDevice(clear: false),
                  icon: const Icon(Icons.phonelink_lock_rounded, size: 18),
                  label: const Text('Trust this phone'),
                ),
              ),
            ],
            if (status.isAdmin && status.thisDeviceTrusted) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('activity-log-clear-device'),
                  onPressed: _saving ? null : () => _trustDevice(clear: true),
                  icon: const Icon(Icons.link_off_rounded, size: 18),
                  label: const Text('Clear trusted device'),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('activity-log-force-logout'),
                  onPressed: _saving ? null : _forceLogoutPicker,
                  icon: const Icon(Icons.logout_rounded, size: 18),
                  label: const Text('Sign someone out'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _trustDevice({required bool clear}) async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<AppState>().api.setAdminDevice(clear: clear);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            clear
                ? 'Trusted device pin cleared.'
                : 'This phone is now the trusted admin device.',
          ),
        ),
      );
      await widget.onChanged();
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(friendlyMessage(error))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _forceLogoutPicker() async {
    final messenger = ScaffoldMessenger.of(context);
    List<OnlineAdminUser> online;
    try {
      online = await context.read<AppState>().api.listOnlineUsers();
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(friendlyMessage(error))));
      return;
    }
    if (!mounted) return;
    final me = widget.status.myUsername;
    online = online.where((u) => u.username != me).toList();
    if (online.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Nobody else is online right now.')),
      );
      return;
    }
    final chosen = await showModalBottomSheet<OnlineAdminUser>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Sign someone out'),
              subtitle: Text(
                'Their phones will need to sign in again. Use this if a stolen session is open.',
              ),
            ),
            for (final user in online)
              ListTile(
                leading: const Icon(Icons.person_outline_rounded),
                title: Text('@${user.username}'),
                subtitle: Text(user.displayName),
                onTap: () => Navigator.pop(sheetContext, user),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Sign out @${chosen.username}?'),
        content: const Text(
          'Every device signed in as this account will be disconnected immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await context.read<AppState>().api.forceLogoutUser(chosen.id);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('@${chosen.username} was signed out.')),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(friendlyMessage(error))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _promptForUsername() async {
    final status = widget.status;
    final controller = TextEditingController(
      text: status.unclaimed
          ? status.myUsername
          : (status.adminUsername ?? status.myUsername),
    );
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(status.unclaimed ? 'Claim as admin' : 'Admin username'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              status.unclaimed
                  ? 'While nobody is admin yet, you can only claim the role for your own username (@${status.myUsername}).'
                  : 'Usernames are unique on this server, so one name is one account.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin-username-field'),
              controller: controller,
              autofocus: true,
              readOnly: status.unclaimed,
              inputFormatters: [FilteringTextInputFormatter.deny(' ')],
              decoration: const InputDecoration(
                prefixText: '@',
                labelText: 'Username',
              ),
              onSubmitted: (value) =>
                  Navigator.pop(dialogContext, value.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (chosen == null || chosen.isEmpty || !mounted) return;

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final updated = await context.read<AppState>().api.setAdminUsername(
        chosen,
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('@${updated.adminUsername} is now the admin.')),
      );
      await widget.onChanged();
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(friendlyMessage(error))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// One recorded action, expandable to what changed and who did it.
///
/// A direct message is sealed by the phone that sent it, so the log holds a
/// token no server can read. This phone, however, is a member of its own chats
/// and already holds those keys — so on expanding an entry it tries to open the
/// text locally. Nothing is decrypted anywhere but here, and an entry from a
/// chat this account is not in stays sealed, which is the whole point.
class _AuditRow extends StatefulWidget {
  const _AuditRow({required this.entry});

  final AuditEntry entry;

  @override
  State<_AuditRow> createState() => _AuditRowState();
}

class _AuditRowState extends State<_AuditRow> {
  String? _before;
  String? _after;
  bool _expanded = false;
  bool _opened = false;
  bool _opening = false;
  bool _primed = false;
  bool _showTechnical = false;

  AuditEntry get entry => widget.entry;

  bool get _hasSealedText =>
      isE2eCipherText(entry.beforeText) || isE2eCipherText(entry.afterText);

  /// Tries to open the sealed text with this phone's own key.
  ///
  /// The first try may run before the keys or the chat list are there, so it is
  /// allowed to fetch what it needs ([prepare]); a try that still comes up empty
  /// is not the end of it — [build] asks again the moment this account holds the
  /// key for that chat. Latching on one failed attempt was what left an entry
  /// reading "not readable on this device" until the screen was reopened.
  Future<void> _openSealedText({bool prepare = false}) async {
    if (_opened || _opening || !_hasSealedText) return;
    _opening = true;
    final state = context.read<AppState>();
    try {
      final before = await state.revealSealedAuditText(
        entry.conversationId,
        entry.beforeText,
        prepare: prepare,
      );
      final after = await state.revealSealedAuditText(
        entry.conversationId,
        entry.afterText,
      );
      if (!mounted || (before == null && after == null)) return;
      setState(() {
        _before = before;
        _after = after;
        _opened = true;
      });
    } finally {
      _opening = false;
    }
  }

  AuditNaming _naming(AppState state) => AuditNaming(
    myUsername: state.me?.username,
    myUserId: state.me?.id,
    chatName: state.chatNameFor(entry.conversationId),
    peerName: state.chatPeerUsername(entry.conversationId),
    targetName: state.usernameForUserId(entry.targetUserId),
    revealedBefore: _before,
    revealedAfter: _after,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = context.watch<AppState>();
    // A key can land after the entry was opened — the inbox answering, or the
    // other phone finally replying to a key swap — so an entry left sealed asks
    // again as soon as this account can read that chat.
    if (_expanded &&
        !_opened &&
        !_opening &&
        _hasSealedText &&
        state.canRevealSealedChat(entry.conversationId)) {
      unawaited(_openSealedText());
    }
    final naming = _naming(state);
    final sensitive = isSensitiveCategory(entry.category);
    final tone = sensitive ? scheme.error : scheme.onSurfaceVariant;
    final blocks = auditTextBlocks(entry, naming: naming);
    final facts = auditFactRows(
      entry,
      naming: naming,
      formatTime: (when) => formatMomentWithDay(context, when),
    );

    return Card(
      margin: EdgeInsets.zero,
      color: sensitive ? scheme.errorContainer.withValues(alpha: 0.22) : null,
      child: Theme(
        // The divider a plain ExpansionTile draws cuts the card in half.
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          onExpansionChanged: (open) {
            _expanded = open;
            if (!open) return;
            // Only the first look is allowed to fetch; every later try uses
            // what this phone already holds.
            final prepare = !_primed;
            _primed = true;
            unawaited(_openSealedText(prepare: prepare));
          },
          leading: Icon(_iconFor(entry.category), color: tone),
          title: Text(
            auditActionLabel(entry.action),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            '${auditActorLabel(entry, myUsername: naming.myUsername)} · '
            '${formatMomentWithDay(context, entry.at)}',
            style: theme.textTheme.labelMedium?.copyWith(color: tone),
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                auditSentence(entry, naming: naming),
                style: theme.textTheme.bodyMedium,
              ),
            ),
            for (final block in blocks) ...[
              const SizedBox(height: 8),
              _TextBlockCard(
                block: block,
                tone: block.isBefore ? scheme.error : scheme.primary,
              ),
            ],
            if (facts.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final row in facts) _DetailLine(row: row),
            ],
            const SizedBox(height: 2),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () =>
                      setState(() => _showTechnical = !_showTechnical),
                  icon: Icon(
                    _showTechnical
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                  ),
                  label: Text(
                    _showTechnical
                        ? 'Hide technical details'
                        : 'Technical details',
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _copy(naming),
                  icon: const Icon(Icons.copy_all_rounded, size: 16),
                  label: const Text('Copy entry'),
                ),
              ],
            ),
            if (_showTechnical) ...[
              Text(
                'Exactly as the server recorded it, for an investigation.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              for (final row in auditTechnicalRows(entry))
                _DetailLine(row: row, muted: true),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _copy(AuditNaming naming) async {
    final text = auditClipboardText(
      entry,
      naming: naming,
      formatTime: (when) => formatMomentWithDay(context, when),
    );
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Entry copied')));
  }

  IconData _iconFor(String category) => switch (category) {
    'edits' => Icons.edit_rounded,
    'deletions' => Icons.delete_forever_rounded,
    'messages' => Icons.chat_bubble_outline_rounded,
    'calls' => Icons.call_rounded,
    'accounts' => Icons.person_outline_rounded,
    'settings' => Icons.tune_rounded,
    'reads' => Icons.done_all_rounded,
    _ => Icons.bolt_rounded,
  };
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.row, this.muted = false});

  final AuditDetailRow row;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = muted
        ? theme.textTheme.labelSmall
        : theme.textTheme.labelMedium;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 148,
            child: Text(
              row.label,
              style: style?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(child: Text(row.value, style: style)),
        ],
      ),
    );
  }
}

/// One version of what a message said, or one side of a changed setting.
class _TextBlockCard extends StatelessWidget {
  const _TextBlockCard({required this.block, required this.tone});

  final AuditTextBlock block;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: tone.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (block.sealed) ...[
                Icon(Icons.lock_outline_rounded, size: 13, color: tone),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  block.label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: tone,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            block.value,
            style: block.sealed
                ? theme.textTheme.bodyMedium?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: scheme.onSurfaceVariant,
                  )
                : theme.textTheme.bodyMedium,
          ),
          if (block.note != null) ...[
            const SizedBox(height: 6),
            Text(
              block.note!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
