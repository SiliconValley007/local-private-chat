/// Which shell the first Flutter frame should paint.
///
/// Lock outranks connectivity: an armed lock must never sit behind the
/// Tailscale "Connecting privately…" gate or a cached inbox.
enum AppEntryKind { lock, connecting, auth, onboarding, inbox, launch }

AppEntryKind appEntryKind({
  required bool isLoggedIn,
  required bool appLocked,
  required bool ready,
  bool? onboardingDone,
  bool hasStableShell = false,
}) {
  if (isLoggedIn && appLocked) return AppEntryKind.lock;
  if (!ready) return AppEntryKind.connecting;
  if (!isLoggedIn) return AppEntryKind.auth;
  if (onboardingDone == false) return AppEntryKind.onboarding;
  if (onboardingDone == null) {
    return hasStableShell ? AppEntryKind.inbox : AppEntryKind.launch;
  }
  return AppEntryKind.inbox;
}
