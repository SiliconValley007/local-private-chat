import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/emoji.dart';

void main() {
  group('emojiOnlyCount', () {
    test('counts a single emoji', () {
      expect(emojiOnlyCount('😀'), 1);
    });

    test('counts several emoji, with or without spaces', () {
      expect(emojiOnlyCount('😀😀😀'), 3);
      expect(emojiOnlyCount(' 😀 🎉 '), 2);
    });

    test('skin tone modifiers stay part of one emoji', () {
      expect(emojiOnlyCount('👍🏽'), 1);
    });

    test('joined sequences count as one emoji', () {
      expect(emojiOnlyCount('👨‍👩‍👧‍👦'), 1);
    });

    test('a flag counts as one emoji', () {
      expect(emojiOnlyCount('🇮🇳'), 1);
      expect(emojiOnlyCount('🇮🇳🇺🇸'), 2);
    });

    test('keycaps count as emoji', () {
      expect(emojiOnlyCount('1️⃣'), 1);
    });

    test('text alongside emoji is not emoji-only', () {
      expect(emojiOnlyCount('hi 😀'), 0);
      expect(emojiOnlyCount('😀!'), 0);
      expect(emojiOnlyCount('123'), 0);
    });

    test('empty and blank bodies are not emoji-only', () {
      expect(emojiOnlyCount(null), 0);
      expect(emojiOnlyCount(''), 0);
      expect(emojiOnlyCount('   '), 0);
    });

    test('symbols that render as emoji are included', () {
      expect(emojiOnlyCount('❤️'), 1);
      expect(emojiOnlyCount('✅'), 1);
    });
  });

  group('sizing', () {
    test('shorter messages get bigger glyphs', () {
      final one = emojiOnlyFontSize(1)!;
      final two = emojiOnlyFontSize(2)!;
      final three = emojiOnlyFontSize(3)!;
      expect(one, greaterThan(two));
      expect(two, greaterThan(three));
      expect(three, greaterThan(15)); // Anything beats body text size.
    });

    test('long emoji runs and plain text fall back to normal text', () {
      expect(emojiOnlyFontSize(6), isNotNull);
      expect(emojiOnlyFontSize(7), isNull);
      expect(emojiOnlyFontSize(0), isNull);
    });

    test('only short messages lose the bubble', () {
      expect(emojiWithoutBubble(1), isTrue);
      expect(emojiWithoutBubble(3), isTrue);
      expect(emojiWithoutBubble(4), isFalse);
      expect(emojiWithoutBubble(0), isFalse);
    });
  });
}
