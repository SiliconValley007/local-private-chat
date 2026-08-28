import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../chat_navigation.dart';
import '../errors.dart';
import '../media_ttl.dart';
import '../services/app_lock_store.dart';
import '../services/privacy_onboarding_store.dart';
import '../widgets/change_password_dialog.dart';
import 'activity_log_screen.dart';
import 'backup_screen.dart';
import 'privacy_onboarding_screen.dart';
import 'qr_invite_screen.dart';
import 'self_profile_screen.dart';
import 'server_info_screen.dart';
import 'server_setup_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _openSaved(BuildContext context) async {
    try {
      final conversation = await context
          .read<AppState>()
          .savedMessagesConversation();
      if (context.mounted) {
        await pushChat(context, conversation: conversation);
      }
    } catch (failure) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendlyMessage(failure))));
    }
  }

  Future<void> _chooseAppearance(BuildContext context) async {
    final state = context.read<AppState>();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: RadioGroup<ThemeMode>(
          groupValue: state.themeMode,
          onChanged: (mode) {
            if (mode != null) state.setThemeMode(mode);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('Appearance'),
                subtitle: Text('Your choice stays on this phone.'),
              ),
              for (final mode in ThemeMode.values)
                RadioListTile<ThemeMode>(
                  value: mode,
                  title: Text(switch (mode) {
                    ThemeMode.system => 'Same as system',
                    ThemeMode.light => 'Light',
                    ThemeMode.dark => 'Dark',
                  }),
                ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _configureLock(BuildContext context) async {
    final state = context.read<AppState>();
    // First time only: create a PIN. After that, the Settings switch owns
    // on/off and this sheet is for timeout / biometrics / PIN management.
    if (!state.appLockSettings.hasPin) {
      await _enableLock(context, state);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final live = sheetContext.watch<AppState>();
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  live.appLockSettings.armed
                      ? Icons.lock_rounded
                      : Icons.lock_open_rounded,
                ),
                title: Text(
                  live.appLockSettings.armed
                      ? 'App lock is on'
                      : 'App lock is off',
                ),
                subtitle: const Text(
                  'Use the switch on Settings to turn it on or off.',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('Lock after'),
                subtitle: Text(
                  appLockTimeoutLabel(live.appLockSettings.timeout),
                ),
                enabled: live.appLockSettings.armed,
                onTap: () async {
                  final picked = await _pickTimeout(
                    sheetContext,
                    live.appLockSettings.timeout,
                  );
                  if (picked != null) await live.updateAppLockTimeout(picked);
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                },
              ),
              if (live.biometricAvailable)
                SwitchListTile(
                  secondary: const Icon(Icons.fingerprint_rounded),
                  title: const Text('Fingerprint or face'),
                  subtitle: const Text('The app PIN always remains available.'),
                  value: live.appLockSettings.biometricsEnabled,
                  onChanged: live.appLockSettings.armed
                      ? live.updateBiometricUnlock
                      : null,
                ),
              if (live.biometricAvailable &&
                  live.appLockSettings.biometricsEnabled)
                ListTile(
                  leading: Icon(
                    live.appLockSettings.preferredAuth ==
                            AppLockPreferredAuth.biometric
                        ? Icons.fingerprint_rounded
                        : Icons.pin_rounded,
                  ),
                  title: const Text('Default unlock'),
                  subtitle: Text(
                    appLockPreferredAuthLabel(
                      live.appLockSettings.preferredAuth,
                    ),
                  ),
                  enabled: live.appLockSettings.armed,
                  onTap: () async {
                    final picked = await _pickPreferredAuth(
                      sheetContext,
                      live.appLockSettings.preferredAuth,
                    );
                    if (picked != null) {
                      await live.updatePreferredAppLockAuth(picked);
                    }
                  },
                ),
              ListTile(
                leading: const Icon(Icons.pin_rounded),
                title: const Text('Change PIN'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await _changePin(context, live);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: Theme.of(sheetContext).colorScheme.error,
                ),
                title: Text(
                  'Remove PIN',
                  style: TextStyle(
                    color: Theme.of(sheetContext).colorScheme.error,
                  ),
                ),
                subtitle: const Text('Deletes the saved PIN from this phone'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await _removePin(context, live);
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  Future<void> _toggleLockFromRow(BuildContext context, bool enable) async {
    final state = context.read<AppState>();
    if (enable && !state.appLockSettings.hasPin) {
      await _enableLock(context, state);
      return;
    }
    await state.setAppLockEnabled(enable);
  }

  Future<void> _enableLock(BuildContext context, AppState state) async {
    final pin = TextEditingController();
    final confirm = TextEditingController();
    var timeout = AppLockTimeout.immediately;
    var biometrics = state.biometricAvailable;
    var preferredAuth = biometrics
        ? AppLockPreferredAuth.biometric
        : AppLockPreferredAuth.pin;
    String? error;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Set an app PIN'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'You can turn this lock on or off later without creating a new PIN.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: pin,
                    autofocus: true,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 8,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'New app PIN'),
                  ),
                  TextField(
                    controller: confirm,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 8,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: 'Confirm PIN',
                      errorText: error,
                    ),
                  ),
                  DropdownButtonFormField<AppLockTimeout>(
                    initialValue: timeout,
                    decoration: const InputDecoration(labelText: 'Lock after'),
                    items: [
                      for (final option in AppLockTimeout.values)
                        DropdownMenuItem(
                          value: option,
                          child: Text(appLockTimeoutLabel(option)),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => timeout = value);
                      }
                    },
                  ),
                  if (state.biometricAvailable)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Use fingerprint or face'),
                      value: biometrics,
                      onChanged: (value) {
                        setDialogState(() {
                          biometrics = value;
                          if (!value) {
                            preferredAuth = AppLockPreferredAuth.pin;
                          }
                        });
                      },
                    ),
                  if (state.biometricAvailable && biometrics)
                    DropdownButtonFormField<AppLockPreferredAuth>(
                      initialValue: preferredAuth,
                      decoration: const InputDecoration(
                        labelText: 'Default unlock',
                      ),
                      items: [
                        for (final option in AppLockPreferredAuth.values)
                          DropdownMenuItem(
                            value: option,
                            child: Text(appLockPreferredAuthLabel(option)),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => preferredAuth = value);
                        }
                      },
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  if (!isValidAppLockPin(pin.text)) {
                    setDialogState(
                      () => error = 'Use 4 to 8 digits for the PIN.',
                    );
                    return;
                  }
                  if (pin.text != confirm.text) {
                    setDialogState(() => error = 'The PINs do not match.');
                    return;
                  }
                  try {
                    await state.setAppLock(
                      pin: pin.text,
                      timeout: timeout,
                      biometricsEnabled: biometrics,
                      preferredAuth: preferredAuth,
                    );
                  } catch (failure) {
                    setDialogState(() => error = friendlyMessage(failure));
                    return;
                  }
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                },
                child: const Text('Turn on'),
              ),
            ],
          ),
        ),
      );
    } finally {
      pin.dispose();
      confirm.dispose();
    }
  }

  Future<AppLockTimeout?> _pickTimeout(
    BuildContext context,
    AppLockTimeout current,
  ) {
    return showModalBottomSheet<AppLockTimeout>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Lock Local Chat')),
            for (final option in AppLockTimeout.values)
              ListTile(
                leading: Icon(
                  option == current
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                ),
                title: Text(appLockTimeoutLabel(option)),
                onTap: () => Navigator.pop(sheetContext, option),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<AppLockPreferredAuth?> _pickPreferredAuth(
    BuildContext context,
    AppLockPreferredAuth current,
  ) {
    return showModalBottomSheet<AppLockPreferredAuth>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Default unlock'),
              subtitle: Text(
                'This choice is used whenever Local Chat locks.',
              ),
            ),
            for (final option in AppLockPreferredAuth.values)
              ListTile(
                leading: Icon(
                  option == current
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                ),
                title: Text(appLockPreferredAuthLabel(option)),
                onTap: () => Navigator.pop(sheetContext, option),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _changePin(BuildContext context, AppState state) async {
    final current = TextEditingController();
    final next = TextEditingController();
    try {
      await _pinActionDialog(
        context,
        title: 'Change app PIN',
        first: current,
        firstLabel: 'Current PIN',
        second: next,
        secondLabel: 'New PIN',
        actionLabel: 'Change',
        action: () =>
            state.changeAppLockPin(currentPin: current.text, newPin: next.text),
      );
    } finally {
      current.dispose();
      next.dispose();
    }
  }

  Future<void> _removePin(BuildContext context, AppState state) async {
    final pin = TextEditingController();
    try {
      await _pinActionDialog(
        context,
        title: 'Remove app PIN?',
        first: pin,
        firstLabel: 'App PIN',
        actionLabel: 'Remove',
        helper:
            'This deletes the PIN from this phone. You can set a new one later.',
        action: () => state.removeAppLockPin(pin.text),
      );
    } finally {
      pin.dispose();
    }
  }

  Future<void> _pinActionDialog(
    BuildContext context, {
    required String title,
    required TextEditingController first,
    required String firstLabel,
    TextEditingController? second,
    String? secondLabel,
    String? helper,
    required String actionLabel,
    required Future<void> Function() action,
  }) {
    String? error;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (helper != null) ...[
                Text(helper, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: first,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: firstLabel),
              ),
              if (second != null) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: second,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(labelText: secondLabel),
                ),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await action();
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } catch (failure) {
                  setDialogState(
                    () => error = failure is ArgumentError
                        ? '${failure.message}'
                        : friendlyMessage(failure),
                  );
                }
              },
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _logout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
          'Messages remain on your private server. Local cached data is cleared.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await context.read<AppState>().logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final lockOn = state.appLockSettings.armed;
    final hasPin = state.appLockSettings.hasPin;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _SectionTitle('Account'),
          ListTile(
            leading: const Icon(Icons.person_outline_rounded),
            title: const Text('Profile'),
            subtitle: Text('@${state.me?.username ?? ''}'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SelfProfileScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.bookmark_rounded),
            title: const Text('Saved messages'),
            subtitle: const Text('Private notes, files, and checklists'),
            onTap: () => _openSaved(context),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code_2_rounded),
            title: const Text('My invite QR'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const QrInviteScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.password_rounded),
            title: const Text('Change account password'),
            onTap: () => showChangePasswordDialog(context),
          ),
          _SectionTitle('Privacy'),
          SwitchListTile(
            secondary: Icon(
              lockOn ? Icons.lock_rounded : Icons.lock_outline_rounded,
            ),
            title: const Text('App lock'),
            subtitle: Text(
              !hasPin
                  ? 'Protect chats with fingerprint, face, or a PIN'
                  : lockOn
                  ? 'On · ${appLockTimeoutLabel(state.appLockSettings.timeout)}'
                  : 'Off · PIN saved for when you leave home',
            ),
            value: lockOn,
            onChanged: (value) => _toggleLockFromRow(context, value),
          ),
          ListTile(
            leading: const Icon(Icons.tune_rounded),
            title: const Text('App lock options'),
            subtitle: Text(
              hasPin
                  ? 'Timeout, default unlock, biometrics, and PIN'
                  : 'Set a PIN the first time',
            ),
            onTap: () => _configureLock(context),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy guide'),
            subtitle: const Text(
              'Review what stays local and what the server sees',
            ),
            onTap: () async {
              await PrivacyOnboardingStore.reset();
              if (!context.mounted) return;
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PrivacyOnboardingScreen(
                    onFinished: () => Navigator.pop(context),
                  ),
                ),
              );
            },
          ),
          if (state.offersActivityLog)
            ListTile(
              leading: const Icon(Icons.fact_check_outlined),
              title: const Text('Activity log'),
              subtitle: const Text('Admin-only append-only audit trail'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ActivityLogScreen()),
              ),
            ),
          _SectionTitle('Chats and media'),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: const Text('Appearance'),
            subtitle: Text(switch (state.themeMode) {
              ThemeMode.system => 'Same as system',
              ThemeMode.light => 'Light',
              ThemeMode.dark => 'Dark',
            }),
            onTap: () => _chooseAppearance(context),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.wifi_rounded),
            title: const Text('Wi-Fi only for videos'),
            subtitle: const Text('Ask before saving videos on mobile data'),
            value: state.mediaPrefs.wifiOnlyVideoDownload,
            onChanged: (value) => state.setMediaPrefs(
              state.mediaPrefs.copyWith(wifiOnlyVideoDownload: value),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: const Text('Default for chats I start'),
            subtitle: Text(
              state.mediaPolicy == null
                  ? 'How long they stay on the server'
                  : composerMediaTimerLabel(state.mediaPolicy),
            ),
            onTap: () => _chooseMyMediaTtl(context, state),
          ),
          if (state.offersActivityLog)
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Server attachment expiry'),
              subtitle: Text(
                'Default for everyone: '
                '${state.mediaPolicy?.defaultDays ?? 30} days',
              ),
              onTap: () => _chooseServerMediaTtl(context, state),
            ),
          ListTile(
            leading: const Icon(Icons.cloud_upload_outlined),
            title: const Text('Backup and restore'),
            subtitle: const Text('Client-encrypted backup'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BackupScreen()),
            ),
          ),
          _SectionTitle('Connection and server'),
          ListTile(
            leading: const Icon(Icons.monitor_heart_outlined),
            title: const Text('Server status'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ServerInfoScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Server and Tailscale'),
            subtitle: const Text(
              'Address, private connection, and exit policy',
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ServerSetupScreen()),
            ),
          ),
          const Divider(height: 28),
          ListTile(
            leading: Icon(Icons.logout_rounded, color: scheme.error),
            title: Text('Log out', style: TextStyle(color: scheme.error)),
            onTap: () => _logout(context),
          ),
        ],
      ),
    );
  }
}

Future<int?> _pickTtlDays(
  BuildContext context, {
  required String title,
  required int? selected,
  bool includeServerDefault = false,
}) {
  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(title: Text(title)),
          if (includeServerDefault)
            ListTile(
              title: const Text('Use server default'),
              trailing: selected == null
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.pop(ctx, 0),
            ),
          for (final days in const [1, 7, 30, 90, 365])
            ListTile(
              title: Text(days == 1 ? '1 day' : '$days days'),
              trailing: selected == days
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.pop(ctx, days),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

Future<void> _chooseMyMediaTtl(BuildContext context, AppState state) async {
  await state.refreshMediaPolicy();
  if (!context.mounted) return;
  final picked = await _pickTtlDays(
    context,
    title: 'New photos and videos leave the server after',
    selected: state.mediaPolicy?.myDays,
    includeServerDefault: true,
  );
  if (picked == null) return;
  await state.setMyMediaTtl(picked == 0 ? null : picked);
}

Future<void> _chooseServerMediaTtl(BuildContext context, AppState state) async {
  await state.refreshMediaPolicy();
  if (!context.mounted) return;
  final picked = await _pickTtlDays(
    context,
    title: 'Server default for new attachments',
    selected: state.mediaPolicy?.defaultDays,
  );
  if (picked == null) return;
  await state.setServerMediaTtl(picked);
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}
