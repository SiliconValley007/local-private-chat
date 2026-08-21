import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/app_lock_store.dart';

class _PinSubmitButton extends StatelessWidget {
  const _PinSubmitButton({
    required this.emphasised,
    required this.busy,
    required this.onPressed,
  });

  final bool emphasised;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final label = busy
        ? const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(emphasised ? 'Unlock' : 'Unlock with PIN');
    return emphasised
        ? FilledButton(onPressed: onPressed, child: label)
        : OutlinedButton(onPressed: onPressed, child: label);
  }
}

/// Opaque privacy gate shown before any chat content is built.
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final _pin = TextEditingController();
  final _focus = FocusNode();
  bool _checkingPin = false;
  bool _automaticBiometricOffered = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _offerPreferredAuth();
    });
  }

  void _offerPreferredAuth() {
    final state = context.read<AppState>();
    final prefersBiometric =
        state.appLockSettings.preferredAuth ==
        AppLockPreferredAuth.biometric;
    if (prefersBiometric &&
        state.appLockSettings.biometricsEnabled &&
        state.biometricAvailable &&
        !_automaticBiometricOffered) {
      _automaticBiometricOffered = true;
      _offerBiometrics();
      return;
    }
    if (!prefersBiometric) _focus.requestFocus();
  }

  @override
  void dispose() {
    _pin.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _offerBiometrics() async {
    if (!mounted) return;
    final state = context.read<AppState>();
    if (state.biometricUnlocking) return;
    if (!state.biometricAvailable || !state.appLockSettings.biometricsEnabled) {
      _focus.requestFocus();
      return;
    }
    final unlocked = await state.unlockWithBiometrics();
    if (mounted && !unlocked) _focus.requestFocus();
  }

  Future<void> _unlockPin() async {
    if (_checkingPin) return;
    setState(() {
      _checkingPin = true;
      _error = null;
    });
    final unlocked = await context.read<AppState>().unlockWithPin(_pin.text);
    if (!mounted) return;
    if (!unlocked) {
      HapticFeedback.mediumImpact();
      _pin.clear();
      setState(() {
        _checkingPin = false;
        _error = 'That PIN is not correct.';
      });
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final biometricsUsable =
        state.biometricAvailable && state.appLockSettings.biometricsEnabled;
    final leadWithBiometrics =
        biometricsUsable &&
        state.appLockSettings.preferredAuth == AppLockPreferredAuth.biometric;
    if (!_automaticBiometricOffered &&
        state.appLockSettings.preferredAuth ==
            AppLockPreferredAuth.biometric &&
        state.appLockSettings.biometricsEnabled &&
        state.biometricAvailable) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _offerPreferredAuth();
      });
    }
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: AutofillGroup(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Semantics(
                        label: 'Local Chat is locked',
                        child: Container(
                          width: 84,
                          height: 84,
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            leadWithBiometrics
                                ? Icons.fingerprint_rounded
                                : Icons.lock_rounded,
                            size: 40,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Local Chat is locked',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        leadWithBiometrics
                            ? 'Unlock with your fingerprint, or use the app PIN '
                                  'below. Both stay only on this phone.'
                            : 'Enter your app PIN. It stays only on this phone.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (leadWithBiometrics) ...[
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: state.biometricUnlocking
                                ? null
                                : _offerBiometrics,
                            icon: const Icon(Icons.fingerprint_rounded),
                            label: Text(
                              state.biometricUnlocking
                                  ? 'Waiting for your fingerprint…'
                                  : 'Unlock with fingerprint',
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                      ],
                      TextField(
                        controller: _pin,
                        focusNode: _focus,
                        obscureText: true,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        maxLength: 8,
                        autofillHints: const [AutofillHints.password],
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: (_) => setState(() => _error = null),
                        onSubmitted: (_) => _unlockPin(),
                        decoration: InputDecoration(
                          labelText: leadWithBiometrics
                              ? 'Or enter your app PIN'
                              : 'App PIN',
                          errorText: _error,
                          prefixIcon: const Icon(Icons.pin_rounded),
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: _PinSubmitButton(
                          // Fingerprint is the primary action when it leads, so
                          // the PIN keeps the quieter of the two styles.
                          emphasised: !leadWithBiometrics,
                          busy: _checkingPin,
                          onPressed: _checkingPin || _pin.text.length < 4
                              ? null
                              : _unlockPin,
                        ),
                      ),
                      if (biometricsUsable && !leadWithBiometrics) ...[
                        const SizedBox(height: 10),
                        TextButton.icon(
                          onPressed: state.biometricUnlocking
                              ? null
                              : _offerBiometrics,
                          icon: const Icon(Icons.fingerprint_rounded),
                          label: Text(
                            state.biometricUnlocking
                                ? 'Checking…'
                                : 'Use fingerprint or face',
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Text(
                        'Message text is never shown in Local Chat notifications.',
                        textAlign: TextAlign.center,
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: scheme.outline),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
