import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../screens/my_uploads_screen.dart';
import '../services/storage_info.dart';
import 'attachments.dart';

/// Storage summary for the server volume where uploads and the database live.
class StorageStrip extends StatefulWidget {
  const StorageStrip({super.key});

  @override
  State<StorageStrip> createState() => _StorageStripState();
}

class _StorageStripState extends State<StorageStrip> {
  StorageInfo? _info;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _failed = false;
      });
    }
    try {
      final api = context.read<AppState>().api;
      final info = await readStorageInfo(api);
      if (mounted) setState(() => _info = info);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _manageUploads() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const MyUploadsScreen()));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (_loading && info == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 14),
        child: LinearProgressIndicator(minHeight: 3),
      );
    }
    if (_failed || info == null || !info.known) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            const Expanded(child: Text('Server storage unavailable')),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    final barColor = info.low ? scheme.error : scheme.primary;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                info.low
                    ? Icons.warning_amber_rounded
                    : Icons.sd_storage_rounded,
                size: 15,
                color: info.low ? scheme.error : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Server storage: ${formatFileSize(info.freeBytes)} free of '
                  '${formatFileSize(info.totalBytes)}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: info.low ? scheme.error : scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Refresh server storage',
                onPressed: _loading ? null : _load,
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: info.usedFraction,
              minHeight: 5,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
          if (info.low)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                info.critical
                    ? 'Critically low — free server space now to prevent upload '
                          'and database failures.'
                    : 'Server space is running low. Free some space soon.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _manageUploads,
              icon: const Icon(Icons.cleaning_services_outlined, size: 17),
              label: const Text('Manage my uploads'),
            ),
          ),
        ],
      ),
    );
  }
}
