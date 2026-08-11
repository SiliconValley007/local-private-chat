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
      body: Padding(
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
          ],
        ),
      ),
    );
  }
}
