import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../errors.dart';
import '../services/server_health.dart';
import '../theme.dart';
import '../widgets/attachments.dart';
import '../widgets/error_banner.dart';
import '../widgets/loading_placeholders.dart';
import 'my_uploads_screen.dart';

/// Health of the machine hosting the chat, for whoever wants to check on it.
///
/// The server is usually a spare phone under Termux, so it can be killed by low
/// memory, a full disk, or a flat battery. The reading is taken when this screen
/// opens and on pull-to-refresh only: a background poll would drain the very
/// battery this screen exists to protect.
class ServerInfoScreen extends StatefulWidget {
  const ServerInfoScreen({super.key});

  @override
  State<ServerInfoScreen> createState() => _ServerInfoScreenState();
}

class _ServerInfoScreenState extends State<ServerInfoScreen> {
  ServerHealth? _health;
  String? _error;
  bool _loading = true;
  DateTime? _readAt;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<AppState>().api;
      final health = await readServerHealth(api);
      if (!mounted) return;
      setState(() {
        _health = health;
        _readAt = DateTime.now();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = friendlyMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final health = _health;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Server status'),
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
        child: _loading && health == null
            ? const ListSkeleton(rows: 4, label: 'Reading server status')
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  if (_error != null) ...[
                    ErrorBanner(message: _error!),
                    const SizedBox(height: 12),
                  ],
                  if (health == null)
                    const Text(
                      'Server status is unavailable. Pull down to try again.',
                    )
                  else
                    ..._sections(health),
                ],
              ),
      ),
    );
  }

  List<Widget> _sections(ServerHealth health) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final host = health.host;
    final memory = health.memory;
    final battery = health.battery;

    return [
      _Summary(level: health.level, advice: healthAdvice(health)),
      const SizedBox(height: 16),
      _Card(
        icon: host.isPhone
            ? Icons.smartphone_rounded
            : Icons.desktop_windows_rounded,
        title: 'Host',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(host.label, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Chip(label: hostBadge(host.kind), tone: scheme.primary),
                if (host.lowMemory)
                  _Chip(label: 'Low-memory mode', tone: scheme.tertiary),
                if (host.python.isNotEmpty)
                  _Chip(label: 'Python ${host.python}', tone: scheme.outline),
              ],
            ),
          ],
        ),
      ),
      if (memory != null)
        _Card(
          icon: Icons.memory_rounded,
          title: 'Memory',
          level: memoryLevel(memory),
          child: _Meter(
            fraction: memory.usedFraction,
            level: memoryLevel(memory),
            headline:
                '${formatFileSize(memory.availableBytes)} free of '
                '${formatFileSize(memory.totalBytes)}',
            detail: memory.processBytes == null
                ? null
                : 'Chat server is using ${formatFileSize(memory.processBytes)}',
          ),
        )
      else
        _Card(
          icon: Icons.memory_rounded,
          title: 'Memory',
          child: const Text('This host does not report memory.'),
        ),
      _Card(
        icon: Icons.sd_storage_rounded,
        title: 'Storage',
        level: diskLevel(health.disk),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Meter(
              fraction: health.disk.usedFraction,
              level: diskLevel(health.disk),
              headline:
                  '${formatFileSize(health.disk.freeBytes)} free of '
                  '${formatFileSize(health.disk.totalBytes)}',
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
      ),
      if (battery != null)
        _Card(
          icon: battery.charging
              ? Icons.battery_charging_full_rounded
              : Icons.battery_5_bar_rounded,
          title: 'Battery',
          level: batteryLevel(battery),
          child: _Meter(
            fraction: battery.percent / 100,
            level: batteryLevel(battery),
            headline: '${battery.percent}%',
            detail: battery.charging
                ? 'Charging — safe to leave running'
                : 'On battery — plug the server in for long chats',
          ),
        ),
      _Card(
        icon: Icons.schedule_rounded,
        title: 'Uptime',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Chat server: ${formatUptime(health.uptime.serverSeconds)}'),
            if (health.uptime.hostSeconds != null)
              Text('Device: ${formatUptime(health.uptime.hostSeconds)}'),
          ],
        ),
      ),
      const SizedBox(height: 4),
      Text(
        _readAt == null
            ? 'Read once per visit — nothing polls in the background.'
            : 'Read at '
                  '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(_readAt!))}'
                  ' — nothing polls in the background.',
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    ];
  }

  Future<void> _manageUploads() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const MyUploadsScreen()));
    if (mounted) await _load();
  }
}

/// One-line verdict at the top, so trouble is visible without reading numbers.
class _Summary extends StatelessWidget {
  const _Summary({required this.level, required this.advice});

  final HealthLevel level;
  final String advice;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, icon) = switch (level) {
      HealthLevel.ok => (scheme.primary, Icons.check_circle_rounded),
      HealthLevel.warn => (scheme.tertiary, Icons.info_rounded),
      HealthLevel.critical => (scheme.error, Icons.warning_amber_rounded),
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              advice,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.icon,
    required this.title,
    required this.child,
    this.level = HealthLevel.ok,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final HealthLevel level;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tone = switch (level) {
      HealthLevel.ok => scheme.onSurfaceVariant,
      HealthLevel.warn => scheme.tertiary,
      HealthLevel.critical => scheme.error,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: tone),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: tone,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

/// A used/total bar with its headline, shared by memory, disk, and battery.
class _Meter extends StatelessWidget {
  const _Meter({
    required this.fraction,
    required this.level,
    required this.headline,
    this.detail,
  });

  final double fraction;
  final HealthLevel level;
  final String headline;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = switch (level) {
      HealthLevel.ok => scheme.primary,
      HealthLevel.warn => scheme.tertiary,
      HealthLevel.critical => scheme.error,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          headline,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: scheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
        if (detail != null) ...[
          const SizedBox(height: 6),
          Text(
            detail!,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.tone});

  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: tone,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
