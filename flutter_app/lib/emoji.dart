/// Detection of "emoji-only" messages, so they can be drawn big like WhatsApp.
///
/// A single 15px 😀 inside a bubble is unreadable, so a message made only of
/// emoji is rendered large and — for short ones — without a bubble at all.
library;

const int _zwj = 0x200D; // joins 👨‍👩‍👧 into one glyph
const int _variationSelector16 = 0xFE0F;
const int _variationSelector15 = 0xFE0E;
const int _combiningKeycap = 0x20E3;

bool _isWhitespace(int cp) =>
    cp == 0x20 || cp == 0x09 || cp == 0x0A || cp == 0x0D || cp == 0xA0;

bool _isSkinTone(int cp) => cp >= 0x1F3FB && cp <= 0x1F3FF;

/// Tag characters used by subdivision flags (e.g. the Scotland flag).
bool _isTag(int cp) => cp >= 0xE0020 && cp <= 0xE007F;

/// Half of a flag; two in a row form one country flag.
bool _isRegionalIndicator(int cp) => cp >= 0x1F1E6 && cp <= 0x1F1FF;

/// Keycap bases: 0-9, # and *, which only count as emoji with a keycap mark.
bool _isKeycapBase(int cp) =>
    (cp >= 0x30 && cp <= 0x39) || cp == 0x23 || cp == 0x2A;

bool _isEmojiBase(int cp) {
  if (_isRegionalIndicator(cp)) return true;
  return (cp >= 0x1F300 && cp <= 0x1FAFF) || // pictographs, emoticons, symbols
      (cp >= 0x1F004 && cp <= 0x1F0CF) || // mahjong tile, playing card
      (cp >= 0x1F170 && cp <= 0x1F251) || // enclosed characters
      (cp >= 0x2600 && cp <= 0x27BF) || // misc symbols and dingbats
      (cp >= 0x2B00 && cp <= 0x2BFF) ||
      (cp >= 0x2190 && cp <= 0x21FF) ||
      (cp >= 0x2900 && cp <= 0x297F) ||
      (cp >= 0x231A && cp <= 0x231B) ||
      (cp >= 0x23E9 && cp <= 0x23FA) ||
      (cp >= 0x25AA && cp <= 0x25FE) ||
      (cp >= 0x3030 && cp <= 0x303D) ||
      cp == 0x2328 ||
      cp == 0x23CF ||
      cp == 0x203C ||
      cp == 0x2049 ||
      cp == 0x2122 ||
      cp == 0x2139 ||
      cp == 0x3297 ||
      cp == 0x3299 ||
      cp == 0x00A9 ||
      cp == 0x00AE;
}

/// Number of emoji when [text] is nothing but emoji, otherwise 0.
///
/// Joined sequences (family, skin tones, flags) count as one emoji, which is
/// what a reader sees on screen.
int emojiOnlyCount(String? text) {
  final raw = text?.trim() ?? '';
  if (raw.isEmpty) return 0;

  final runes = raw.runes.toList();
  final hasKeycap = runes.contains(_combiningKeycap);

  var count = 0;
  var afterZwj = false;
  var openFlag = false;

  for (final cp in runes) {
    if (_isWhitespace(cp)) {
      openFlag = false;
      continue;
    }
    if (cp == _zwj) {
      afterZwj = true;
      continue;
    }
    if (cp == _variationSelector16 ||
        cp == _variationSelector15 ||
        cp == _combiningKeycap ||
        _isSkinTone(cp) ||
        _isTag(cp)) {
      continue;
    }

    final isBase = _isEmojiBase(cp) || (hasKeycap && _isKeycapBase(cp));
    if (!isBase) {
      return 0; // A single ordinary letter makes this a text message.
    }

    if (_isRegionalIndicator(cp)) {
      if (openFlag) {
        openFlag = false; // Second half of the same flag.
        continue;
      }
      openFlag = true;
      count++;
      continue;
    }

    openFlag = false;
    if (afterZwj) {
      afterZwj = false; // Part of the previous glyph, not a new emoji.
      continue;
    }
    count++;
  }

  return count;
}

/// Font size for an emoji-only message, or null to render it as normal text.
double? emojiOnlyFontSize(int count) => switch (count) {
  1 => 46,
  2 => 38,
  3 => 32,
  4 || 5 || 6 => 24,
  _ => null,
};

/// Short emoji-only messages drop the bubble entirely, as WhatsApp does.
bool emojiWithoutBubble(int count) => count >= 1 && count <= 3;
