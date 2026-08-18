import 'services/contacts_store.dart';

/// Resolves a caller/sender display name using the same alias rules as chat
/// notifications: local nickname wins when [username] is known.
Future<String> resolveCallerDisplayName({
  required String username,
  required String serverName,
  String fallback = 'Incoming call',
}) async {
  final trimmedUsername = username.trim();
  var name = serverName.trim();
  if (trimmedUsername.isNotEmpty) {
    final aliases = await ContactsStore().aliases();
    name = aliases[trimmedUsername] ?? name;
  }
  return name.isEmpty ? fallback : name;
}

/// Synchronous alias lookup when the alias map is already in memory.
String resolveCallerDisplayNameSync({
  required String username,
  required String serverName,
  required Map<String, String> aliases,
  String fallback = 'Incoming call',
}) {
  final trimmedUsername = username.trim();
  var name = serverName.trim();
  if (trimmedUsername.isNotEmpty) {
    name = aliases[trimmedUsername] ?? name;
  }
  return name.isEmpty ? fallback : name;
}
