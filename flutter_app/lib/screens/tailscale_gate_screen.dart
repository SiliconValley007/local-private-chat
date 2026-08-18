import 'dart:async';

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

    // While the tunnel is still coming up, any diagnosis would be a guess — and
    // "server is not running" was the wrong guess often enough to be annoying.
    if (state.settling) {
      return _ConnectingView(onOpenTailscale: state.openTailscaleApp);
    }

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
                        opacity: Tween(begin: 0.6, end: 1.0).animate(
                          CurvedAnimation(
                            parent: _pulse,
                            curve: Curves.easeInOut,
                          ),
                        ),
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
                      _StepsCard(
                        title: details.stepsTitle,
                        steps: details.steps,
                      ),
                      const SizedBox(height: 22),
                      if (details.showConnectTailscale) ...[
                        FilledButton.icon(
                          onPressed:
                              state.connectingTailscale ||
                                  state.checkingConnectivity
                              ? null
                              : () => _connectTailscale(state),
                          icon: state.connectingTailscale
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.vpn_key_rounded),
                          label: Text(
                            state.connectingTailscale
                                ? 'Connecting Tailscale…'
                                : 'Connect Tailscale',
                          ),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: state.connectingTailscale
                              ? null
                              : () => _openTailscale(state),
                          icon: const Icon(Icons.open_in_new_rounded, size: 18),
                          label: const Text('Open Tailscale app'),
                        ),
                        const SizedBox(height: 8),
                      ],
                      FilledButton.tonalIcon(
                        onPressed:
                            state.checkingConnectivity ||
                                state.connectingTailscale
                            ? null
                            : state.refreshConnectivity,
                        icon: state.checkingConnectivity
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
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
                      _AddressChip(
                        address: check?.baseUrl ?? state.api.baseUrl,
                      ),
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

  Future<void> _connectTailscale(AppState state) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await state.connectTailscaleAndWait();
    if (!mounted) return;
    if (ok) return;
    final installed = await state.tailscale.isInstalled();
    if (!mounted) return;
    final message = !installed
        ? 'Tailscale is not installed on this phone.'
        : 'Still waiting for Tailscale. Open the Tailscale app, '
              'confirm it says Connected, then come back.';
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openTailscale(AppState state) async {
    final opened = await state.openTailscaleApp();
    if (!mounted) return;
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open Tailscale. Is it installed?'),
        ),
      );
    }
  }

  void _openServerSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ServerSetupScreen()));
  }
}

/// Shown while Local Chat is still bringing the private link up.
///
/// Deliberately reason-free: it appears in the seconds after Tailscale is asked
/// to connect, when the VPN interface may exist but is not routing yet.
class _ConnectingView extends StatefulWidget {
  const _ConnectingView({required this.onOpenTailscale});

  final Future<bool> Function() onOpenTailscale;

  @override
  State<_ConnectingView> createState() => _ConnectingViewState();
}

class _ConnectingViewState extends State<_ConnectingView> {
  Timer? _slowTimer;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    // Only offer the manual escape hatch once this is genuinely taking a while.
    _slowTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: appBackgroundGradient(scheme)),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const _StatusBadge(
                    icon: Icons.vpn_lock_rounded,
                    color: AppColors.brand,
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'Connecting privately…',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Bringing Tailscale up and reaching your server.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 26),
                  const SizedBox(
                    width: 120,
                    child: LinearProgressIndicator(minHeight: 4),
                  ),
                  if (_slow) ...[
                    const SizedBox(height: 26),
                    OutlinedButton.icon(
                      onPressed: () => widget.onOpenTailscale(),
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('Open Tailscale app'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
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
    this.showConnectTailscale = false,
    this.isWarning = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final String stepsTitle;
  final List<String> steps;
  final bool showSettingsButton;
  final bool showConnectTailscale;
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
          body:
              "The address saved in the app isn't a valid server URL, "
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
          body:
              'There is no Wi-Fi or mobile data connection. '
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
          body:
              'Tailscale is working on this phone, but nothing answered at '
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
          body:
              "This phone doesn't have a Tailscale address yet, so it can't "
              'reach your private server. Local Chat already asked Tailscale '
              'to connect — tap the button if it is still off.',
          stepsTitle: 'On this phone',
          steps: [
            'Tap "Connect Tailscale" below (works when Tailscale is installed '
                'and already signed in).',
            'If nothing changes, tap "Open Tailscale app" and switch it to '
                'Connected.',
            'Come back — this screen unlocks automatically.',
          ],
          showConnectTailscale: true,
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
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
