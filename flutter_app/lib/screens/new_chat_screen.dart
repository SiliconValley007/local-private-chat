import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../errors.dart';
import '../models.dart';
import '../widgets/avatar.dart';
import '../widgets/error_banner.dart';
import '../widgets/rename_dialog.dart';
import 'qr_invite_screen.dart';
import 'qr_scan_screen.dart';

class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key});

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final state = context.read<AppState>();
      await Future.wait([state.refreshUsers(), state.refreshLocalContacts()]);
    } catch (e) {
      _error = friendlyMessage(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 280), () async {
      try {
        await context.read<AppState>().refreshUsers(
          q: q.trim().isEmpty ? null : q,
        );
        if (mounted) setState(() => _error = null);
      } catch (e) {
        if (mounted) setState(() => _error = friendlyMessage(e));
      }
    });
  }

  Future<void> _openUser(ChatUser user) async {
    final conv = await context.read<AppState>().openDmWithUser(user);
    if (mounted) Navigator.of(context).pop(conv);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final q = _search.text.trim().toLowerCase();
    final contacts = state.localContacts.where((c) {
      if (q.isEmpty) return true;
      return state.nameFor(c.username, c.displayName).toLowerCase().contains(q) ||
          c.displayName.toLowerCase().contains(q) ||
          c.username.toLowerCase().contains(q);
    }).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('New chat')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: TextField(
                    controller: _search,
                    onChanged: _onQueryChanged,
                    decoration: InputDecoration(
                      hintText: 'Search username or name',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _search.clear();
                                _onQueryChanged('');
                                setState(() {});
                              },
                            ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _QuickAction(
                          icon: Icons.qr_code_2_rounded,
                          label: 'My QR',
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const QrInviteScreen(),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _QuickAction(
                          icon: Icons.qr_code_scanner_rounded,
                          label: 'Scan',
                          onTap: () async {
                            final conv = await Navigator.of(context)
                                .push<Conversation>(
                                  MaterialPageRoute(
                                    builder: (_) => const QrScanScreen(),
                                  ),
                                );
                            if (conv != null && context.mounted) {
                              Navigator.of(context).pop(conv);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: ErrorBanner(message: _error!),
                  ),
                Expanded(
                  child: ListView(
                    children: [
                      if (contacts.isNotEmpty) ...[
                        _SectionLabel('Saved contacts'),
                        ...contacts.map((c) {
                          final shown = state.nameFor(c.username, c.displayName);
                          return ListTile(
                            leading: Avatar(
                              name: shown,
                              seed: c.username,
                              radius: 21,
                            ),
                            title: Text(shown),
                            subtitle: Text(
                              state.hasCustomName(c.username)
                                  ? '@${c.username} · really ${c.displayName}'
                                  : '@${c.username}',
                            ),
                            trailing: IconButton(
                              tooltip: 'Rename',
                              icon: const Icon(
                                Icons.drive_file_rename_outline_rounded,
                              ),
                              onPressed: () => showRenameContactDialog(
                                context,
                                username: c.username,
                                serverName: c.displayName,
                              ),
                            ),
                            onTap: () async {
                              try {
                                final user = await state.resolveUsername(
                                  c.username,
                                );
                                await _openUser(user);
                              } catch (e) {
                                setState(() => _error = friendlyMessage(e));
                              }
                            },
                          );
                        }),
                      ],
                      _SectionLabel('On this server'),
                      if (state.users.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No users found. Try a username search or scan a QR.',
                          ),
                        )
                      else
                        ...state.users.map((u) {
                          final online = state.onlineByUser[u.id] ?? u.isOnline;
                          final shown = state.nameFor(u.username, u.displayName);
                          return ListTile(
                            leading: Avatar(
                              name: shown,
                              seed: u.id,
                              radius: 21,
                              online: online,
                            ),
                            title: Text(shown),
                            subtitle: Text(
                              '@${u.username}'
                              '${state.hasCustomName(u.username) ? ' · really ${u.displayName}' : ''}'
                              '${online ? ' · online' : ''}',
                            ),
                            trailing: IconButton(
                              tooltip: 'Save contact',
                              icon: const Icon(Icons.person_add_alt_1_outlined),
                              onPressed: () => state.saveLocalContact(u),
                            ),
                            onTap: () => _openUser(u),
                          );
                        }),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 6),
              Text(label, style: Theme.of(context).textTheme.labelLarge),
            ],
          ),
        ),
      ),
    );
  }
}
