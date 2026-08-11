import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_config.dart';
import '../app_state.dart';

class QrInviteScreen extends StatelessWidget {
  const QrInviteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AppState>().me;
    if (me == null) {
      return const Scaffold(body: Center(child: Text('Not signed in')));
    }
    final uri = AppConfig.inviteUri(me.username);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Your invite QR')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Friends scan this to add you — no phone numbers, no cloud contacts.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 28),
          Center(
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.12),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: QrImageView(
                data: uri,
                size: 220,
                eyeStyle: QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: scheme.primary,
                ),
                dataModuleStyle: QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            me.displayName,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          Text(
            '@${me.username}',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.primary),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: uri));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Invite link copied')),
                );
              }
            },
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy invite link'),
          ),
        ],
      ),
    );
  }
}
