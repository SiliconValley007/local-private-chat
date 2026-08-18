import 'package:flutter/material.dart';

import '../services/privacy_onboarding_store.dart';
import '../theme.dart';

/// Short first-run privacy walkthrough (skippable).
class PrivacyOnboardingScreen extends StatefulWidget {
  const PrivacyOnboardingScreen({super.key, required this.onFinished});

  final VoidCallback onFinished;

  @override
  State<PrivacyOnboardingScreen> createState() =>
      _PrivacyOnboardingScreenState();
}

class _PrivacyOnboardingScreenState extends State<PrivacyOnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _pages = [
    (
      icon: Icons.dns_rounded,
      title: 'Your server',
      body:
          'Messages live on the chat server you host — not in a corporate cloud inbox. '
          'You pick who is on the server.',
    ),
    (
      icon: Icons.vpn_lock_rounded,
      title: 'Tailscale mesh',
      body:
          'Phones reach each other over a private Tailscale network. '
          'No public chat ports on the open internet.',
    ),
    (
      icon: Icons.lock_person_rounded,
      title: 'No cloud account',
      body:
          'Local Chat does not sell accounts or ads. Backups are encrypted on your phone; '
          'the server only stores ciphertext.',
    ),
  ];

  Future<void> _finish() async {
    await PrivacyOnboardingStore.markDone();
    widget.onFinished();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: appBackgroundGradient(scheme)),
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _finish,
                  child: const Text('Skip'),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _pages.length,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (context, i) {
                    final page = _pages[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(page.icon, size: 72, color: AppColors.brand),
                          const SizedBox(height: 28),
                          Text(
                            page.title,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 14),
                          Text(
                            page.body,
                            style: Theme.of(
                              context,
                            ).textTheme.bodyLarge?.copyWith(height: 1.45),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _pages.length; i++)
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _page
                            ? AppColors.brand
                            : scheme.outlineVariant,
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                child: FilledButton(
                  onPressed: () {
                    if (_page >= _pages.length - 1) {
                      _finish();
                    } else {
                      _controller.nextPage(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOut,
                      );
                    }
                  },
                  child: Text(
                    _page >= _pages.length - 1 ? 'Get started' : 'Next',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
