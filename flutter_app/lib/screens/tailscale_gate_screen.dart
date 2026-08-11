import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/connectivity_service.dart';
import '../theme.dart';
import 'server_setup_screen.dart';

/// Blocks the app while the private server is unreachable, and explains *why*.
///
/// The old version always blamed Tailscale, which was misleading when the VPN
/// was up and the chat server simply wasn't running.
class TailscaleGateScreen extends StatefulWidget {
  const TailscaleGateScreen({super.key, required this.child});

  final Widget child;

  @override
  State<TailscaleGateScreen> createState() => _TailscaleGateScreenState();
}

class _TailscaleGateScreenState extends State<TailscaleGateScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.serverReachable) return widget.child;

    final check = state.serverCheck;
    final details = _GateDetails.forCheck(check);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: appBackgroundGradient(scheme)),
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8, top: 4),
                  child: TextButton.icon(
                    onPressed: _openServerSettings,
                    icon: const Icon(Icons.settings_outlined, size: 18),
                    label: const Text('Server'),
                  ),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      FadeTransition(
                        opacity: Tween(
                          begin: 0.6,
                          end: 1.0,
                        ).animate(CurvedAnimation(
                          parent: _pulse,
                          curve: Curves.easeInOut,
                        )),
                        child: _StatusBadge(
                          icon: details.icon,
                          color: details.accent(scheme),
                        ),
                      ),
                      const SizedBox(height: 26),
                      Text(
                        details.title,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        details.explain(check),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 22),
                      _StepsCard(title: details.stepsTitle, steps: details.steps),
                      const SizedBox(height: 22),
                      FilledButton.icon(
                        onPressed: state.checkingConnectivity
                            ? null
                            : state.refreshConnectivity,
                        icon: state.checkingConnectivity
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh_rounded),
                        label: Text(
                          state.checkingConnectivity
                              ? 'Checking…'
                              : 'Try again',
                        ),
                      ),
                      if (details.showSettingsButton) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _openServerSettings,
                          icon: const Icon(Icons.tune_rounded, size: 18),
                          label: const Text('Change server address'),
                        ),
                      ],
                      const SizedBox(height: 24),
                      _AddressChip(address: check?.baseUrl ?? state.api.baseUrl),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openServerSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ServerSetupScreen()),
    );
  }
}

/// Copy and styling for each failure reason.
class _GateDetails {
  const _GateDetails({
    required this.icon,
    required this.title,
    required this.stepsTitle,
    required this.steps,
    required this.body,
    this.showSettingsButton = false,
    this.isWarning = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final String stepsTitle;
  final List<String> steps;
  final bool showSettingsButton;
  final bool isWarning;

  Color accent(ColorScheme scheme) =>
      isWarning ? const Color(0xFFB45309) : scheme.primary;

  String explain(ServerCheck? check) {
    final host = check?.host;
    if (host == null || host.isEmpty) return body;
    return body.replaceAll('{host}', host);
  }

  static _GateDetails forCheck(ServerCheck? check) {
    switch (check?.status) {
      case ServerStatus.badAddress:
        return const _GateDetails(
          icon: Icons.link_off_rounded,
          title: 'Server address looks wrong',
          body: "The address saved in the app isn't a valid server URL, "
              'so there is nothing to connect to.',
          stepsTitle: 'How to fix it',
          steps: [
            'Tap "Change server address" below.',
            'Enter the address shown by the server, like http://100.71.32.92:8000',
          ],
          showSettingsButton: true,
          isWarning: true,
        );

      case ServerStatus.noNetwork:
        return const _GateDetails(
          icon: Icons.wifi_off_rounded,
          title: 'This phone is offline',
          body: 'There is no Wi-Fi or mobile data connection. '
              'Tailscale needs a network underneath it to work.',
          stepsTitle: 'How to fix it',
          steps: [
            'Turn on Wi-Fi or mobile data.',
            'Make sure Airplane mode is off.',
            'Come back and tap Try again.',
          ],
          isWarning: true,
        );

      case ServerStatus.serverDown:
        return const _GateDetails(
          icon: Icons.dns_outlined,
          title: 'Chat server is not running',
          body: 'Tailscale is working on this phone, but nothing answered at '
              '{host}. The server phone needs to be awake and running Local Chat.',
          stepsTitle: 'On the server phone',
          steps: [
            'Open Termux and run: python run.py',
            'Leave that window running (tmux keeps it alive).',
            'Check Tailscale is Connected there too.',
            'Then tap Try again here.',
          ],
          showSettingsButton: true,
        );

      case ServerStatus.tailscaleOff:
      default:
        return const _GateDetails(
          icon: Icons.vpn_key_off_rounded,
          title: 'Tailscale is not connected',
          body: "This phone doesn't have a Tailscale address yet, so it can't "
              'reach your private server.',
          stepsTitle: 'On this phone',
          steps: [
            'Open the Tailscale app and sign in.',
            'Switch the toggle to Connected.',
            'Come back and tap Try again.',
          ],
        );
    }
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.22),
            blurRadius: 34,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Icon(icon, size: 52, color: color),
    );
  }
}

class _StepsCard extends StatelessWidget {
  const _StepsCard({required this.title, required this.steps});

  final String title;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < steps.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${i + 1}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    steps[i],
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _AddressChip extends StatelessWidget {
  const _AddressChip({this.address});

  final String? address;

  @override
  Widget build(BuildContext context) {
    if (address == null || address!.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lan_outlined, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            address!,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
