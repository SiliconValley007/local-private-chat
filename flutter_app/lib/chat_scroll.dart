/// Geometry for the chat transcript, which is built bottom-up.
///
/// The transcript used to be an ordinary top-anchored list that was scrolled to
/// the end after opening. Row heights are only known once images, quotes and
/// video thumbnails have measured themselves, so "the end" kept moving and the
/// chat opened a little above the newest message and then visibly caught up.
///
/// A reversed list removes the problem instead of chasing it: offset zero *is*
/// the newest message, so a chat opens anchored there with nothing to animate,
/// growing rows push older history away rather than shifting the anchor, and
/// loading older pages appends beyond the far edge without moving the view.
library;

/// Scroll offset of the newest message in a reversed transcript.
const double newestMessageOffset = 0;

/// Distance from the newest message before the "jump to latest" button appears.
const double jumpToLatestThreshold = 320;

/// How close to the oldest loaded message triggers the next page.
const double loadOlderThreshold = 40;

/// Rows in the reversed transcript: the messages plus the typing bubble, which
/// sits below the newest message and therefore first in reversed order.
int transcriptItemCount({required int messageCount, required bool typing}) =>
    messageCount + (typing ? 1 : 0);

/// Message index for a reversed row, or null when the row is the typing bubble.
///
/// Row zero is painted at the bottom of the viewport, so it holds the typing
/// bubble when someone is typing and the newest message otherwise.
int? transcriptMessageIndex({
  required int itemIndex,
  required int messageCount,
  required bool typing,
}) {
  if (typing && itemIndex == 0) return null;
  final row = typing ? itemIndex - 1 : itemIndex;
  return messageCount - 1 - row;
}

/// True while the newest message is on screen, so arrivals may follow it down.
bool isAtNewest(double pixels) => pixels < jumpToLatestThreshold;

/// True once the reader has moved far enough back for the jump button to help.
bool shouldShowJumpToLatest(double pixels) => pixels >= jumpToLatestThreshold;

/// True when the oldest loaded message is close enough to fetch the next page.
///
/// Older messages live at the far end of a reversed list, so this is the top of
/// the screen in reading terms. A transcript shorter than the viewport has no
/// extent at all, and would otherwise ask for another page on every stray
/// overscroll, so it is excluded.
bool shouldLoadOlder({
  required double pixels,
  required double maxScrollExtent,
}) => maxScrollExtent > 0 && pixels >= maxScrollExtent - loadOlderThreshold;

/// Offset that keeps the same messages on screen after the list grew by
/// [extentDelta] at the anchored (newest) end.
///
/// Inserting a message shifts everything above it away from the anchor, which
/// would drag history under the reader's eyes. Adding the same amount to the
/// offset holds the view still.
double offsetAfterGrowth({
  required double pixels,
  required double extentDelta,
  required double maxScrollExtent,
}) {
  if (extentDelta <= 0) return pixels;
  final target = pixels + extentDelta;
  return target.clamp(newestMessageOffset, maxScrollExtent);
}

/// Where to land when jumping to a message that has not been laid out yet.
///
/// Used as a rough first hop before `Scrollable.ensureVisible` settles it: the
/// oldest message sits at the far end of a reversed list, so the ratio is
/// counted from the newest message backwards.
double approximateOffsetForIndex({
  required int index,
  required int messageCount,
  required double maxScrollExtent,
}) {
  if (messageCount <= 1 || maxScrollExtent <= 0) return newestMessageOffset;
  final fromNewest = (messageCount - 1 - index).clamp(0, messageCount - 1);
  final ratio = fromNewest / (messageCount - 1);
  return ratio * maxScrollExtent;
}
