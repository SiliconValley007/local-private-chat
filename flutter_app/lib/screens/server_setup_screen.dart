import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_config.dart';
import '../app_state.dart';
import '../errors.dart';
import '../widgets/error_banner.dart';

/// Settings screen: change the Tailscale/LAN server URL (optional).
class ServerSetupScreen extends StatefulWidget {
  const ServerSetupScreen({super.key});

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  late final TextEditingController _controller;
  String? _error;
  String? _savedMessage;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing =
        context.read<AppState>().api.baseUrl ?? AppConfig.defaultServerUrl;
    _controller = TextEditingController(text: existing);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _controller.text.trim().replaceAll(RegExp(r'/+$'), '');
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      setState(() {
        _error =
            'The address has to start with http:// — for example '
            '${AppConfig.defaultServerUrl}';
        _savedMessage = null;
      });
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      setState(() {
        _error =
            'That address looks incomplete. Enter it like '
            '${AppConfig.defaultServerUrl}';
        _savedMessage = null;
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _savedMessage = null;
    });
    try {
      await context.read<AppState>().saveServerUrl(url);
      if (mounted) {
        setState(
          () => _savedMessage = 'Saved. New chats will use this server.',
        );
      }
    } catch (e) {
      setState(() => _error = friendlyMessage(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetDefault() async {
    setState(() {
      _controller.text = AppConfig.defaultServerUrl;
      _error = null;
    });
    await context.read<AppState>().resetServerUrlToDefault();
    setState(() => _savedMessage = 'Reset to default Tailscale URL.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Server settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Default (hardcoded for your Tailscale mesh):\n'
              '  ${AppConfig.defaultServerUrl}\n\n'
              'Change this only if the server Tailscale IP changes '
              '(Settings → Server settings). Clients must still have '
              'Tailscale Connected.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              ErrorBanner(message: _error!),
            ],
            if (_savedMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _savedMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _saving ? null : _resetDefault,
              child: const Text('Reset to default'),
            ),
            const Divider(height: 40),
            const _TailscaleAutomationCard(),
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

/// The two switches that decide how far Local Chat may drive Tailscale.
class _TailscaleAutomationCard extends StatelessWidget {
  const _TailscaleAutomationCard();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final prefs = state.tailscalePrefs;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'TAILSCALE',
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: prefs.autoConnect,
          onChanged: (value) =>
              state.setTailscalePrefs(prefs.copyWith(autoConnect: value)),
          title: const Text('Connect when the app opens'),
          subtitle: const Text(
            'Asks the Tailscale app to connect on launch, on resume, and when a '
            'notification opens a chat.',
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: prefs.autoDisconnectOnExit,
          onChanged: (value) => state.setTailscalePrefs(
            prefs.copyWith(autoDisconnectOnExit: value),
          ),
          title: const Text('Disconnect when you leave the app'),
          subtitle: const Text(
            'About half a minute after Local Chat goes out of sight, and only '
            'when Local Chat switched Tailscale on. A tunnel you turned on '
            'yourself is left alone, and a call in progress keeps its tunnel.',
          ),
        ),
        const SizedBox(height: 4),
        _StatusLine(
          icon: state.tailscaleStartedByApp
              ? Icons.check_circle_outline_rounded
              : Icons.info_outline_rounded,
          text: state.tailscaleStartedByApp
              ? 'Local Chat turned Tailscale on, so closing the app will turn '
                    'it off.'
              : 'Tailscale is not Local Chat\'s to switch off, so it will be '
                    'left running.',
        ),
        if (state.tailscaleAutoConnectPaused) ...[
          const SizedBox(height: 6),
          _StatusLine(
            icon: Icons.pause_circle_outline_rounded,
            text:
                'You disconnected Tailscale here, so the app will not '
                'reconnect it until you ask or reopen the app.',
          ),
        ],
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            final sent = await state.disconnectTailscaleNow();
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  sent
                      ? 'Asked Tailscale to disconnect.'
                      : 'Could not reach the Tailscale app.',
                ),
              ),
            );
          },
          icon: const Icon(Icons.link_off_rounded, size: 18),
          label: const Text('Disconnect Tailscale now'),
        ),
        const SizedBox(height: 12),
        Text(
          'Tailscale owns the VPN, so these are requests to it. Keep its battery '
          'usage Unrestricted, or Android may ignore them.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}
