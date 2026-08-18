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

/// True when a scroll notification should fetch another page of history.
///
/// Two states say no however close to the top the list is. A chat still opening
/// has not settled on the newest message yet, and a jump in progress is walking
/// deliberately: its hops land near the old end, and a page arriving mid-walk
/// renumbers every row — including the one being walked towards, which is how a
/// jump used to stride straight past its target and give up in the wrong decade.
bool shouldPageHistory({
  required bool opening,
  required bool jumping,
  required double pixels,
  required double maxScrollExtent,
}) {
  if (opening || jumping) return false;
  return shouldLoadOlder(pixels: pixels, maxScrollExtent: maxScrollExtent);
}

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

/// Largest hop a hunt may take, counted in viewports.
///
/// Beyond the handful of rows it has built, a lazy list only has an *estimate*
/// of where anything is, and the estimate is drawn from the rows it happens to
/// have measured: in a chat where one photo is worth a dozen lines of text it is
/// wrong by whole screens. So a hop is deliberately bounded. Landing far past
/// the real content leaves the viewport in layout that does not exist, with no
/// rows to walk back from — which is how a jump used to end on a blank canvas.
const double messageHuntMaxViewports = 8;

/// Smallest hop, so a walk still moves when its own estimate collapses.
const double messageHuntMinViewports = 0.25;

/// How many hops to allow before giving up on reaching a message.
///
/// One hop costs one frame, so this is the time budget as much as the distance
/// one: crossing a year of history takes tens of hops, and giving up early is
/// what stranded a jump halfway with nothing to show for it.
const int messageHuntAttempts = 90;

/// Consecutive hops that may fail to move the list before a hunt gives up.
///
/// A lazy list's extent grows as rows are measured, so one hop pinned against
/// the far end is ordinary; several in a row means the row is not in this
/// transcript after all.
const int messageHuntStallLimit = 6;

/// Frames a hunt tolerates with nothing built before it retreats to the anchor.
const int messageHuntBlankLimit = 2;

/// Message indices the list has laid out, oldest and newest.
typedef BuiltRows = ({int oldest, int newest});

/// What the scroll position looks like at the moment a hop is decided.
typedef HuntGeometry = ({
  double pixels,
  double viewportExtent,
  double maxScrollExtent,
});

/// How walking towards a message ended.
enum HuntResult {
  /// The row is laid out, so it can be centred and lit.
  arrived,

  /// The message left the transcript while the walk was in progress.
  gone,

  /// The walk ran out of hops, or of room, without the row appearing.
  missed,
}

/// Next offset while walking towards a message that is still off screen.
///
/// The step is measured from the rows on screen *now* rather than from an
/// average over the whole transcript: their count against the viewport gives the
/// height of a row in this neighbourhood, and the distance in rows times that
/// height is how far there is to go. Feeding each hop's result back in is what
/// makes the walk converge even where a screen of photos and a screen of one
/// liners differ tenfold in height.
///
/// Indices count upwards towards newer messages while offsets count upwards
/// towards older ones, so the two run in opposite directions.
double huntOffsetTowardIndex({
  required int targetIndex,
  required int builtOldestIndex,
  required int builtNewestIndex,
  required double pixels,
  required double viewportExtent,
  required double maxScrollExtent,
  double reachViewports = messageHuntMaxViewports,
}) {
  if (maxScrollExtent <= 0) return newestMessageOffset;
  if (targetIndex >= builtOldestIndex && targetIndex <= builtNewestIndex) {
    return pixels;
  }
  final view = viewportExtent <= 0 ? 240.0 : viewportExtent;
  final older = targetIndex < builtOldestIndex;
  final rowsBuilt = builtNewestIndex - builtOldestIndex + 1;
  final rowHeight = rowsBuilt > 0 ? view / rowsBuilt : view;
  final rowsAway = older
      ? builtOldestIndex - targetIndex
      : targetIndex - builtNewestIndex;
  final reach = (rowsAway * rowHeight).clamp(
    view * messageHuntMinViewports,
    view * reachViewports.clamp(messageHuntMinViewports, double.infinity),
  );
  final target = older ? pixels + reach : pixels - reach;
  return target.clamp(newestMessageOffset, maxScrollExtent);
}

/// True once a hop has run out of room to move the list any further.
///
/// Without this a jump to a message that has since been deleted would keep
/// nudging a list that is already pinned at one end.
bool huntIsStuck({required double previousPixels, required double pixels}) =>
    (pixels - previousPixels).abs() < 0.5;

/// Walks a reversed transcript until the wanted row has been laid out.
///
/// Everything the walk needs to see is read fresh on every hop through the
/// callbacks, because all of it moves underneath a jump: a page of history
/// renumbers the rows, a hop changes which rows exist, and a list that has been
/// hopped clean past the end of its content has no rows at all. The last case
/// heals itself by retreating to the newest message, which is the one offset a
/// reversed list is always certain about.
///
/// Returns [HuntResult.arrived] with the row built but not yet centred; the
/// caller finishes with `Scrollable.ensureVisible`, which can only work once
/// there is a laid-out row to work with.
Future<HuntResult> huntForMessage({
  required int Function() indexOfTarget,
  required bool Function() targetIsBuilt,
  required BuiltRows? Function() builtRows,
  required HuntGeometry Function() geometry,
  required void Function(double offset) jumpTo,
  required Future<void> Function() nextFrame,
  required bool Function() keepGoing,
  int attempts = messageHuntAttempts,
}) async {
  var reach = messageHuntMaxViewports;
  var stalls = 0;
  var blanks = 0;
  int? lastDirection;

  for (var hop = 0; hop < attempts; hop++) {
    if (!keepGoing()) return HuntResult.missed;
    if (targetIsBuilt()) return HuntResult.arrived;
    final index = indexOfTarget();
    if (index < 0) return HuntResult.gone;

    final rows = builtRows();
    if (rows == null) {
      // Parked where the list has nothing: give it a frame to catch up, then go
      // back to the anchor and walk again from solid ground.
      if (++blanks > messageHuntBlankLimit) {
        blanks = 0;
        reach = messageHuntMaxViewports;
        lastDirection = null;
        jumpTo(newestMessageOffset);
      }
      await nextFrame();
      continue;
    }
    blanks = 0;

    if (index >= rows.oldest && index <= rows.newest) {
      // The row is in the built range but has no context yet, which is what a
      // frame still settling looks like.
      await nextFrame();
      continue;
    }

    final direction = index < rows.oldest ? 1 : -1;
    if (lastDirection != null && direction != lastDirection) {
      // Overshot. Close in rather than swinging back and forth over the row.
      reach = (reach / 2).clamp(
        messageHuntMinViewports,
        messageHuntMaxViewports,
      );
    }
    lastDirection = direction;

    final before = geometry();
    jumpTo(
      huntOffsetTowardIndex(
        targetIndex: index,
        builtOldestIndex: rows.oldest,
        builtNewestIndex: rows.newest,
        pixels: before.pixels,
        viewportExtent: before.viewportExtent,
        maxScrollExtent: before.maxScrollExtent,
        reachViewports: reach,
      ),
    );
    await nextFrame();
    if (!keepGoing()) return HuntResult.missed;

    if (huntIsStuck(previousPixels: before.pixels, pixels: geometry().pixels)) {
      if (++stalls >= messageHuntStallLimit) {
        return targetIsBuilt() ? HuntResult.arrived : HuntResult.missed;
      }
    } else {
      stalls = 0;
    }
  }
  return targetIsBuilt() ? HuntResult.arrived : HuntResult.missed;
}
