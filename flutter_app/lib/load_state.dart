/// Which of the three states a collection-backed screen should paint.
///
/// Screens used to decide this from emptiness alone, so a chat that simply had
/// not answered yet looked exactly like a chat with no history: "Say hello to
/// …" appeared for a moment and was then replaced by the transcript. The
/// illustration was a lie, and the swap read as a glitch.
///
/// Emptiness is only meaningful once the first load has resolved. Until then
/// there is nothing to claim, so the screen waits.
library;

/// Whether a screen's first load has finished, however it turned out.
enum LoadPhase {
  /// No answer yet: neither content nor absence has been established.
  loading,

  /// The first load resolved, so an empty collection really is empty.
  ready,
}

/// What a list-backed screen should show right now.
enum CollectionView {
  /// A placeholder standing in for rows that have not arrived yet.
  skeleton,

  /// The honest "there is nothing here" illustration.
  empty,

  /// The rows themselves.
  content,
}

/// Chooses between rows, the empty illustration, and a loading placeholder.
///
/// Anything already cached wins outright: a refresh in flight is no reason to
/// take a transcript off screen and put a spinner in its place.
CollectionView collectionView({
  required LoadPhase phase,
  required bool isEmpty,
}) {
  if (!isEmpty) return CollectionView.content;
  return phase == LoadPhase.ready
      ? CollectionView.empty
      : CollectionView.skeleton;
}

/// [LoadPhase] for a screen that tracks its own "first load done" flag.
///
/// Cached rows also count as resolved, so history restored from a backup shows
/// immediately instead of waiting for the network to confirm it.
LoadPhase loadPhaseFor({required bool resolved, required bool hasCached}) =>
    resolved || hasCached ? LoadPhase.ready : LoadPhase.loading;
