/// Lightweight chat markup: bold, italic, strike, code, spoilers, and URLs.
///
/// Stored as plain text on the server; rendering is client-only. Deliberately
/// tiny — no nested HTML, no raw tags — so a message body cannot become a
/// mini browser.
library;

enum RichKind { text, bold, italic, strike, code, codeBlock, spoiler, link }

class RichSpan {
  const RichSpan(this.kind, this.text, {this.language});

  final RichKind kind;
  final String text;

  /// Optional language tag on a fenced code block (```dart ... ```).
  final String? language;

  @override
  bool operator ==(Object other) =>
      other is RichSpan &&
      other.kind == kind &&
      other.text == text &&
      other.language == language;

  @override
  int get hashCode => Object.hash(kind, text, language);
}

final _urlPattern = RegExp(
  r'(https?:\/\/[^\s<>"{}|\\^`\[\]]+)',
  caseSensitive: false,
);
final _trailingPunctuation = RegExp(r'[.,;)\]!?]+$');

String _trimUrl(String url) => url.replaceFirst(_trailingPunctuation, '');

/// Tokenises [input] into styled spans. Order of precedence:
/// fenced code → inline code → spoiler → bold → strike → italic → URLs → text.
List<RichSpan> parseRichText(String input) {
  if (input.isEmpty) return const [];

  final out = <RichSpan>[];
  var i = 0;
  while (i < input.length) {
    // Fenced code block: ```lang?\n...\n```
    if (input.startsWith('```', i)) {
      final afterTicks = i + 3;
      final nl = input.indexOf('\n', afterTicks);
      final end = input.indexOf('```', afterTicks);
      if (end != -1) {
        String? language;
        String body;
        if (nl != -1 && nl < end) {
          language = input.substring(afterTicks, nl).trim();
          if (language.isEmpty) language = null;
          body = input.substring(nl + 1, end);
          if (body.endsWith('\n')) body = body.substring(0, body.length - 1);
        } else {
          body = input.substring(afterTicks, end);
        }
        out.add(RichSpan(RichKind.codeBlock, body, language: language));
        i = end + 3;
        continue;
      }
    }

    // Inline code: `...`
    if (input[i] == '`') {
      final end = input.indexOf('`', i + 1);
      if (end != -1 && !input.substring(i + 1, end).contains('\n')) {
        out.add(RichSpan(RichKind.code, input.substring(i + 1, end)));
        i = end + 1;
        continue;
      }
    }

    // Spoiler: ||...||
    if (input.startsWith('||', i)) {
      final end = input.indexOf('||', i + 2);
      if (end != -1) {
        out.add(RichSpan(RichKind.spoiler, input.substring(i + 2, end)));
        i = end + 2;
        continue;
      }
    }

    // Bold: **...**
    if (input.startsWith('**', i)) {
      final end = input.indexOf('**', i + 2);
      if (end != -1) {
        out.add(RichSpan(RichKind.bold, input.substring(i + 2, end)));
        i = end + 2;
        continue;
      }
    }

    // Strike: ~~...~~
    if (input.startsWith('~~', i)) {
      final end = input.indexOf('~~', i + 2);
      if (end != -1) {
        out.add(RichSpan(RichKind.strike, input.substring(i + 2, end)));
        i = end + 2;
        continue;
      }
    }

    // Italic: *...* (single asterisks, not part of **)
    if (input[i] == '*' && (i + 1 >= input.length || input[i + 1] != '*')) {
      final end = input.indexOf('*', i + 1);
      if (end != -1 && (end + 1 >= input.length || input[end + 1] != '*')) {
        out.add(RichSpan(RichKind.italic, input.substring(i + 1, end)));
        i = end + 1;
        continue;
      }
    }

    // Plain run until the next special marker or URL.
    final next = _nextSpecial(input, i);
    if (next > i) {
      _emitPlainWithLinks(input.substring(i, next), out);
      i = next;
      continue;
    }

    // Standing on a URL the marker checks did not consume.
    final rest = input.substring(i);
    final urlMatch = _urlPattern.matchAsPrefix(rest);
    if (urlMatch != null) {
      final matched = urlMatch.group(0)!;
      final url = _trimUrl(matched);
      out.add(RichSpan(RichKind.link, url));
      if (url.length < matched.length) {
        out.add(RichSpan(RichKind.text, matched.substring(url.length)));
      }
      i += matched.length;
      continue;
    }

    // Unknown single character — keep moving so we never hang.
    out.add(RichSpan(RichKind.text, input[i]));
    i++;
  }
  return out;
}

int _nextSpecial(String input, int from) {
  for (var j = from; j < input.length; j++) {
    if (input.startsWith('```', j)) return j;
    if (input[j] == '`') return j;
    if (input.startsWith('||', j)) return j;
    if (input.startsWith('**', j)) return j;
    if (input.startsWith('~~', j)) return j;
    if (input[j] == '*') return j;
    final rest = input.substring(j);
    final m = _urlPattern.matchAsPrefix(rest);
    if (m != null) return j;
  }
  return input.length;
}

void _emitPlainWithLinks(String chunk, List<RichSpan> out) {
  if (chunk.isEmpty) return;
  var start = 0;
  for (final match in _urlPattern.allMatches(chunk)) {
    if (match.start > start) {
      out.add(RichSpan(RichKind.text, chunk.substring(start, match.start)));
    }
    final matched = match.group(0)!;
    final url = _trimUrl(matched);
    out.add(RichSpan(RichKind.link, url));
    if (url.length < matched.length) {
      out.add(RichSpan(RichKind.text, matched.substring(url.length)));
    }
    start = match.end;
  }
  if (start < chunk.length) {
    out.add(RichSpan(RichKind.text, chunk.substring(start)));
  }
}

/// True when [input] contains any markup beyond plain text/URLs.
bool hasRichMarkup(String? input) {
  if (input == null || input.isEmpty) return false;
  return input.contains('**') ||
      input.contains('~~') ||
      input.contains('||') ||
      input.contains('`') ||
      RegExp(r'(^|[^*])\*[^*]').hasMatch(input);
}
