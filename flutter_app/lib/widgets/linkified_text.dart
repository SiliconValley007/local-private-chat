import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Matches http(s) URLs in plain text without pulling a third-party linkify package.
final _urlPattern = RegExp(
  r'(https?:\/\/[^\s<>"{}|\\^`\[\]]+)',
  caseSensitive: false,
);

/// Sentence punctuation that follows a URL rather than belonging to it.
///
/// Same set the server trims when building the Links gallery, so a link reads
/// the same in both places.
final _trailingPunctuation = RegExp(r'[.,;)\]!?]+$');

String _withoutTrailingPunctuation(String url) =>
    url.replaceFirst(_trailingPunctuation, '');

/// Text that turns URLs into tappable links. No network fetch — privacy-safe.
class LinkifiedText extends StatelessWidget {
  const LinkifiedText(this.text, {super.key, this.style, this.linkStyle});

  final String text;
  final TextStyle? style;
  final TextStyle? linkStyle;

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final link =
        linkStyle ??
        base.copyWith(
          color: Theme.of(context).colorScheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: Theme.of(context).colorScheme.primary,
        );

    final spans = <InlineSpan>[];
    var start = 0;
    for (final match in _urlPattern.allMatches(text)) {
      if (match.start > start) {
        spans.add(
          TextSpan(text: text.substring(start, match.start), style: base),
        );
      }
      final matched = match.group(0)!;
      // A full stop after a link is part of the sentence: leave it out of the
      // tap target, or the browser is handed "example.com/page." and fails.
      final url = _withoutTrailingPunctuation(matched);
      spans.add(
        TextSpan(
          text: url,
          style: link,
          recognizer: TapGestureRecognizer()
            ..onTap = () async {
              final uri = Uri.tryParse(url);
              if (uri == null) return;
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            },
        ),
      );
      if (url.length < matched.length) {
        spans.add(TextSpan(text: matched.substring(url.length), style: base));
      }
      start = match.end;
    }
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start), style: base));
    }
    if (spans.isEmpty) {
      return Text(text, style: base);
    }
    return Text.rich(TextSpan(children: spans));
  }
}

/// True when [text] contains at least one http(s) URL.
bool containsUrl(String? text) {
  if (text == null || text.isEmpty) return false;
  return _urlPattern.hasMatch(text);
}

/// Every http(s) URL found in [text], in order of appearance.
List<String> extractUrls(String? text) {
  if (text == null || text.isEmpty) return const [];
  return [
    for (final match in _urlPattern.allMatches(text))
      _withoutTrailingPunctuation(match.group(0)!),
  ];
}
