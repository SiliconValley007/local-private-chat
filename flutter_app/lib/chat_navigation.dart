import 'package:flutter/material.dart';

import 'models.dart';
import 'screens/chat_screen.dart';

/// Route name prefix for chat screens — used to detect duplicates on the stack.
const chatRoutePrefix = '/chat/';

/// Builds a chat route tagged with its conversation id.
Route<void> chatRoute({
  required Conversation conversation,
  int? initialMessageId,
}) {
  return MaterialPageRoute<void>(
    settings: RouteSettings(name: '$chatRoutePrefix${conversation.id}'),
    builder: (_) => ChatScreen(
      conversation: conversation,
      initialMessageId: initialMessageId,
    ),
  );
}

bool isChatRoute(Route<dynamic>? route) =>
    route?.settings.name?.startsWith(chatRoutePrefix) ?? false;

int? chatRouteConversationId(Route<dynamic>? route) {
  final name = route?.settings.name;
  if (name == null || !name.startsWith(chatRoutePrefix)) return null;
  return int.tryParse(name.substring(chatRoutePrefix.length));
}

/// Every chat back action lands on the inbox root, not an intermediate screen.
void popChatToInbox(NavigatorState nav) {
  nav.popUntil((route) => route.isFirst);
}

/// Removes stacked chat routes while keeping inbox and intermediate screens
/// such as starred messages or search.
void popStackedChatRoutes(NavigatorState nav) {
  nav.popUntil((route) => route.isFirst || !isChatRoute(route));
}

/// Opens a chat on the nearest navigator.
Future<void> pushChat(
  BuildContext context, {
  required Conversation conversation,
  int? initialMessageId,
}) {
  final nav = Navigator.of(context);
  popStackedChatRoutes(nav);
  return nav.push<void>(
    chatRoute(conversation: conversation, initialMessageId: initialMessageId),
  );
}

/// Notification and deep-link entry: collapse to inbox, then open one chat.
Future<void> openChatFromRoot(
  NavigatorState nav, {
  required Conversation conversation,
  int? initialMessageId,
  int? activeConversationId,
}) {
  if (activeConversationId == conversation.id) return Future.value();
  popChatToInbox(nav);
  return nav.push<void>(
    chatRoute(conversation: conversation, initialMessageId: initialMessageId),
  );
}
