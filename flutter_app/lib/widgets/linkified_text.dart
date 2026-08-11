import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Matches http(s) URLs in plain text without pulling a third-party linkify package.
final _urlPattern = RegExp(
  r'(https?:\/\/[^\s<>"{}|\\^`\[\]]+)',
  caseSensitive: false,
);

/// Text that turns URLs into tappable links. No network fetch — privacy-safe.
class LinkifiedText extends StatelessWidget {
  const LinkifiedText(
    this.text, {
    super.key,
    this.style,
    this.linkStyle,
  });

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
        spans.add(TextSpan(text: text.substring(start, match.start), style: base));
      }
      final url = match.group(0)!;
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
