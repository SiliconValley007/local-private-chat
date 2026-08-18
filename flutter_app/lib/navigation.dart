import 'package:flutter/widgets.dart';

/// Global navigator for notification taps → chat screen.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Pending conversation to open after Tailscale gate / login.
int? pendingOpenConversationId;

/// Pending call id to open after Tailscale gate / login.
String? pendingOpenCallId;
