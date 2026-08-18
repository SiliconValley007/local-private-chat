import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api_client.dart';
import 'app_state.dart';
import 'navigation.dart';
import 'screens/auth_screen.dart';
import 'screens/inbox_screen.dart';
import 'screens/privacy_onboarding_screen.dart';
import 'screens/tailscale_gate_screen.dart';
import 'services/notification_service.dart';
import 'services/privacy_onboarding_store.dart';
import 'services/theme_store.dart';
import 'theme.dart';
import 'widgets/launch_surface.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Cap decoded image RAM so a wallpaper + a few photo bubbles cannot push a
  // 3 GB phone into Android's low-memory killer. Display sizes still look sharp
  // because each Image.network also requests a resized decode.
  PaintingBinding.instance.imageCache
    ..maximumSize = 180
    ..maximumSizeBytes = 40 << 20; // 40 MB
  // Must be registered before runApp so Android can start this entry point when
  // the UI isolate does not exist (backgrounded or swiped away).
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  // Read before the first frame, otherwise a dark-mode phone flashes white.
  final themeMode = await ThemeStore.load();
  runApp(LocalChatApp(initialThemeMode: themeMode));
}

class LocalChatApp extends StatelessWidget {
  const LocalChatApp({super.key, this.initialThemeMode = ThemeMode.system});

  final ThemeMode initialThemeMode;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) {
        final state = AppState(ApiClient(), themeMode: initialThemeMode);
        state.bootstrap();
        return state;
      },
      // Rebuilds MaterialApp when the appearance choice changes.
      child: Consumer<AppState>(
        builder: (context, state, _) => MaterialApp(
          title: 'Local Chat',
          debugShowCheckedModeBanner: false,
          navigatorKey: appNavigatorKey,
          theme: buildAppTheme(),
          darkTheme: buildAppTheme(brightness: Brightness.dark),
          themeMode: state.themeMode,
          home: const _Root(),
        ),
      ),
    );
  }
}

class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  bool? _onboardingDone;
  int? _checkedForUserId;

  /// Last signed-in shell once shown. Mid-session `ready` flaps and onboarding
  /// reloads must not replace this with a lone spinner after a call.
  Widget? _stableShell;

  Future<void> _loadOnboardingFlag(int? userId) async {
    if (userId == null) {
      setState(() {
        _onboardingDone = true;
        _checkedForUserId = null;
        _stableShell = null;
      });
      return;
    }
    if (_checkedForUserId == userId && _onboardingDone != null) return;
    final done = await PrivacyOnboardingStore.isDone();
    if (!mounted) return;
    setState(() {
      _onboardingDone = done;
      _checkedForUserId = userId;
    });
  }

  /// Continuation of the Android splash window, never a spinner on its own.
  Widget _launchSurface() => const LaunchSurface();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    // Only the very first boot may blank the tree. Once the inbox (or auth)
    // has painted, keep that shell through brief readiness flaps after a call.
    if (!state.ready) {
      return TailscaleGateScreen(child: _stableShell ?? _launchSurface());
    }

    Widget child;
    if (!state.isLoggedIn) {
      _stableShell = null;
      child = const AuthScreen();
    } else {
      final uid = state.me?.id;
      if (_checkedForUserId != uid || _onboardingDone == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _loadOnboardingFlag(uid);
        });
      }
      if (_onboardingDone == false) {
        child = PrivacyOnboardingScreen(
          onFinished: () => setState(() => _onboardingDone = true),
        );
      } else if (_onboardingDone == null) {
        // Same user already reached the inbox: do not flash a spinner while
        // the onboarding flag is re-read after a lifecycle churn.
        child = _stableShell ?? _launchSurface();
      } else {
        child = const InboxScreen();
        _stableShell = child;
      }
    }

    return TailscaleGateScreen(child: child);
  }
}
