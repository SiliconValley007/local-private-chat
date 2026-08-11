import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api_client.dart';
import 'app_state.dart';
import 'navigation.dart';
import 'screens/auth_screen.dart';
import 'screens/inbox_screen.dart';
import 'screens/tailscale_gate_screen.dart';
import 'services/notification_service.dart';
import 'services/theme_store.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.ready) {
      return Scaffold(
        body: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: appBackgroundGradient(Theme.of(context).colorScheme),
          ),
          child: const CircularProgressIndicator(),
        ),
      );
    }

    Widget child;
    if (!state.isLoggedIn) {
      child = const AuthScreen();
    } else {
      child = const InboxScreen();
    }

    return TailscaleGateScreen(child: child);
  }
}
