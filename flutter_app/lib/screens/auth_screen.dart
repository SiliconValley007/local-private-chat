import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../errors.dart';
import '../theme.dart';
import '../widgets/error_banner.dart';
import 'server_setup_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _displayName = TextEditingController();
  bool _registerMode = true;
  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _displayName.dispose();
    super.dispose();
  }

  /// Same rules the server enforces, checked here so people get instant feedback.
  String? _validate(String username, String password) {
    if (username.isEmpty) return 'Please enter a username.';
    if (password.isEmpty) return 'Please enter your password.';
    if (!_registerMode) return null;
    if (username.length < 3 || username.length > 40) {
      return 'Username must be 3 to 40 characters long.';
    }
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(username)) {
      return 'Username can only use letters, numbers, underscores or hyphens.';
    }
    if (password.length < 6) {
      return 'Password must be at least 6 characters long.';
    }
    return null;
  }

  Future<void> _submit() async {
    final state = context.read<AppState>();
    final username = _username.text.trim();
    final password = _password.text;
    final problem = _validate(username, password);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    state.clearError();
    try {
      if (_registerMode) {
        await state.register(username, password, _displayName.text.trim());
      } else {
        await state.login(username, password);
      }
    } catch (e) {
      setState(() => _error = friendlyMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // An expired session logs the user out from elsewhere; show why they're here.
    final message = _error ?? context.watch<AppState>().error;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: appBackgroundGradient(scheme)),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const ServerSetupScreen(),
                            ),
                          );
                        },
                        child: const Text('Server'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: scheme.surface,
                          shape: BoxShape.circle,
                          boxShadow: softShadow(
                            color: scheme.primary,
                            opacity: 0.18,
                            blur: 30,
                            offset: const Offset(0, 12),
                          ),
                        ),
                        child: Image.asset(
                          'assets/branding/chat.png',
                          width: 64,
                          height: 64,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Local Chat',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _registerMode
                          ? 'Private mesh messaging. Create your account once — you stay signed in.'
                          : 'Welcome back to your private Tailscale chat.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _ModeSwitch(
                      registerMode: _registerMode,
                      onChanged: _busy
                          ? null
                          : (value) => setState(() {
                              _registerMode = value;
                              _error = null;
                            }),
                    ),
                    const SizedBox(height: 22),
                    TextField(
                      controller: _username,
                      decoration: InputDecoration(
                        labelText: 'Username',
                        helperText: _registerMode
                            ? 'Letters, numbers, _ or - (3 to 40 characters)'
                            : null,
                      ),
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                    ),
                    const SizedBox(height: 12),
                    if (_registerMode) ...[
                      TextField(
                        controller: _displayName,
                        decoration: const InputDecoration(
                          labelText: 'Display name',
                        ),
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: _password,
                      obscureText: !_showPassword,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        helperText: _registerMode
                            ? 'At least 6 characters'
                            : null,
                        suffixIcon: IconButton(
                          tooltip: _showPassword ? 'Hide' : 'Show',
                          icon: Icon(
                            _showPassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 20,
                          ),
                          onPressed: () =>
                              setState(() => _showPassword = !_showPassword),
                        ),
                      ),
                      onSubmitted: (_) => _submit(),
                    ),
                    if (message != null) ...[
                      const SizedBox(height: 14),
                      ErrorBanner(message: message),
                    ],
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Colors.white,
                              ),
                            )
                          : Text(_registerMode ? 'Create account' : 'Sign in'),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Messages never leave your private Tailscale network.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Two-up toggle between signing in and creating an account.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.registerMode, required this.onChanged});

  final bool registerMode;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        children: [
          _ModeTab(
            label: 'Create account',
            selected: registerMode,
            onTap: onChanged == null ? null : () => onChanged!(true),
          ),
          _ModeTab(
            label: 'Sign in',
            selected: !registerMode,
            onTap: onChanged == null ? null : () => onChanged!(false),
          ),
        ],
      ),
    );
  }
}

class _ModeTab extends StatelessWidget {
  const _ModeTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: selected ? scheme.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            boxShadow: selected ? softShadow(opacity: 0.07, blur: 8) : null,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
