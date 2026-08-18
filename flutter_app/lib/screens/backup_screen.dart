import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../errors.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _status;
  bool _obscure = true;
  String? _lastBackupAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMeta());
  }

  Future<void> _loadMeta() async {
    final state = context.read<AppState>();
    try {
      final blob = await state.backup.downloadFromServer();
      final raw = blob['updated_at'];
      if (!mounted || raw == null || raw.isEmpty) return;
      final parsed = DateTime.tryParse(raw)?.toLocal();
      setState(() {
        _lastBackupAt = parsed == null
            ? raw
            : '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')} '
                  '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
      });
    } catch (_) {
      // No backup yet is fine.
    }
  }

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _createBackup({required bool toFirestore}) async {
    final pwd = _password.text;
    if (pwd.length < 8) {
      setState(
        () => _status = 'Use a backup password of at least 8 characters.',
      );
      return;
    }
    if (pwd != _confirm.text) {
      setState(() => _status = "The two passwords don't match.");
      return;
    }
    final state = context.read<AppState>();
    final me = state.me;
    if (me == null) return;

    setState(() {
      _busy = true;
      _status = 'Preparing chats…';
    });
    try {
      await state.refreshInbox();
      await state.prefetchAllMessagesForBackup();
      await state.refreshLocalContacts();
      final plaintext = await state.backup.buildPlaintextExport(
        me: me,
        conversations: state.conversations,
        messagesByConv: state.messagesByConv,
        localContacts: state.localContacts,
        contactAliases: state.contactAliases,
        starredMessageIds: state.starredIds,
      );
      setState(() => _status = 'Encrypting on this device…');
      final enc = await state.backup.encrypt(
        password: pwd,
        plaintext: plaintext,
      );

      setState(() => _status = 'Uploading ciphertext to your private server…');
      await state.backup.uploadToServer(
        ciphertextB64: enc.ciphertextB64,
        saltB64: enc.saltB64,
        nonceB64: enc.nonceB64,
      );

      var cloudOk = false;
      if (toFirestore) {
        setState(() => _status = 'Mirroring ciphertext to Firestore…');
        cloudOk = await state.backup.uploadCiphertextToFirestore(
          username: me.username,
          ciphertextB64: enc.ciphertextB64,
          saltB64: enc.saltB64,
          nonceB64: enc.nonceB64,
        );
      }

      // Local encrypted file (WhatsApp-style portable backup).
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/localchat_backup_${me.username}.json');
      await file.writeAsString(
        jsonEncode({
          'ciphertext_b64': enc.ciphertextB64,
          'salt_b64': enc.saltB64,
          'nonce_b64': enc.nonceB64,
          'username': me.username,
        }),
      );

      if (mounted) {
        setState(() {
          _status = cloudOk
              ? 'Backup saved on server + Firestore. Encrypted file also kept on device.'
              : 'Backup saved on private server. Encrypted file kept on device'
                    '${toFirestore ? ' (Firestore unavailable — add google-services.json).' : '.'}';
        });
      }
    } catch (e) {
      setState(() => _status = 'Backup failed. ${friendlyMessage(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore({required bool fromFirestore}) async {
    final pwd = _password.text;
    if (pwd.isEmpty) {
      setState(() => _status = 'Enter the password you used for the backup.');
      return;
    }
    final when = _lastBackupAt;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore backup?'),
        content: Text(
          when == null
              ? 'This replaces local chat data with the encrypted backup from the server.'
              : 'Last server backup was $when.\n\n'
                    'This replaces local chat data with that backup.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final state = context.read<AppState>();
    final me = state.me;
    if (me == null) return;

    setState(() {
      _busy = true;
      _status = 'Downloading ciphertext…';
    });
    try {
      Map<String, String>? blob;
      if (fromFirestore) {
        blob = await state.backup.downloadCiphertextFromFirestore(me.username);
      }
      blob ??= await state.backup.downloadFromServer();

      setState(() => _status = 'Decrypting on this device…');
      final data = await state.backup.decrypt(
        password: pwd,
        ciphertextB64: blob['ciphertext_b64']!,
        saltB64: blob['salt_b64']!,
        nonceB64: blob['nonce_b64']!,
      );
      final summary = await state.applyRestoredBackup(data);
      if (mounted) {
        setState(() {
          final names = summary['names'] as int? ?? 0;
          final stars = summary['stars'] as int? ?? 0;
          _status =
              'Restored ${summary['contacts']} contacts, ${summary['messages']} messages'
              '${names > 0 ? ', $names renamed ${names == 1 ? 'person' : 'people'}' : ''}'
              '${stars > 0 ? ', $stars starred ${stars == 1 ? 'message' : 'messages'}' : ''}'
              '${(summary['dms'] as int) > 0 ? ', reopened ${summary['dms']} DMs' : ''}.';
        });
      }
    } catch (e) {
      setState(() => _status = 'Restore failed. ${friendlyMessage(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyBackup() async {
    final pwd = _password.text;
    if (pwd.isEmpty) {
      setState(() => _status = 'Enter the backup password to verify.');
      return;
    }
    final state = context.read<AppState>();
    setState(() {
      _busy = true;
      _status = 'Downloading ciphertext…';
    });
    try {
      final blob = await state.backup.downloadFromServer();
      setState(() => _status = 'Checking password & headers…');
      final data = await state.backup.decrypt(
        password: pwd,
        ciphertextB64: blob['ciphertext_b64']!,
        saltB64: blob['salt_b64']!,
        nonceB64: blob['nonce_b64']!,
      );
      final convs = (data['conversations'] as List?)?.length ?? 0;
      final msgs =
          (data['messages'] as List?)?.length ??
          (data['messages_by_conv'] as Map?)?.values.fold<int>(
            0,
            (sum, v) => sum + ((v as List?)?.length ?? 0),
          ) ??
          0;
      if (mounted) {
        setState(() {
          _status =
              'Backup OK — password works. Export has $convs chats'
              '${msgs > 0 ? ' and about $msgs messages' : ''}. Nothing was restored.';
          final raw = blob['updated_at'];
          if (raw != null && raw.isNotEmpty) {
            final parsed = DateTime.tryParse(raw)?.toLocal();
            _lastBackupAt = parsed == null
                ? raw
                : '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')} '
                      '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
          }
        });
      }
    } catch (e) {
      setState(() => _status = 'Verify failed. ${friendlyMessage(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareLocalFile() async {
    final state = context.read<AppState>();
    final me = state.me;
    if (me == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/localchat_backup_${me.username}.json');
    if (!await file.exists()) {
      setState(
        () => _status = 'Create a backup first, then you can share the file.',
      );
      return;
    }
    await Share.shareXFiles([
      XFile(file.path),
    ], text: 'Local Chat encrypted backup');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & restore')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(
              'Encryption keys and your backup password stay on your phones. '
              'Your private server stores ciphertext only — it cannot read chats. '
              'Optional Firestore mirror is the same ciphertext, never plaintext.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
          ),
          if (_lastBackupAt != null) ...[
            const SizedBox(height: 12),
            Text(
              'Last server backup: $_lastBackupAt',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 20),
          TextField(
            controller: _password,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'Backup password',
              suffixIcon: IconButton(
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirm,
            obscureText: _obscure,
            decoration: const InputDecoration(
              labelText: 'Confirm password (for backup)',
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : () => _createBackup(toFirestore: true),
            icon: const Icon(Icons.cloud_upload_outlined),
            label: const Text('Create encrypted backup'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _restore(fromFirestore: false),
            icon: const Icon(Icons.dns_outlined),
            label: const Text('Restore from private server'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _restore(fromFirestore: true),
            icon: const Icon(Icons.cloud_download_outlined),
            label: const Text('Restore from Firestore'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _verifyBackup,
            icon: const Icon(Icons.verified_user_outlined),
            label: const Text('Verify backup'),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: _busy ? null : _shareLocalFile,
            icon: const Icon(Icons.ios_share_rounded),
            label: const Text('Share encrypted backup file'),
          ),
          if (_busy) ...[
            const SizedBox(height: 20),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_status != null) ...[
            const SizedBox(height: 16),
            Text(_status!, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}
