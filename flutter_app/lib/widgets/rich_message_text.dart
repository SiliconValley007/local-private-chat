import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../rich_text.dart';

/// Renders [parseRichText] output: inline styles, tappable spoilers, and
/// fenced code blocks with a copy button.
class RichMessageText extends StatelessWidget {
  const RichMessageText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base = style ?? const TextStyle(height: 1.35, fontSize: 15);
    final spans = parseRichText(text);
    if (spans.isEmpty) return Text(text, style: base);

    final children = <Widget>[];
    final inline = <InlineSpan>[];

    void flushInline() {
      if (inline.isEmpty) return;
      children.add(
        Text.rich(
          TextSpan(style: base, children: List<InlineSpan>.from(inline)),
        ),
      );
      inline.clear();
    }

    for (final span in spans) {
      switch (span.kind) {
        case RichKind.codeBlock:
          flushInline();
          children.add(_CodeBlock(code: span.text, language: span.language));
        case RichKind.text:
          inline.add(TextSpan(text: span.text));
        case RichKind.bold:
          inline.add(
            TextSpan(
              text: span.text,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          );
        case RichKind.italic:
          inline.add(
            TextSpan(
              text: span.text,
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
          );
        case RichKind.strike:
          inline.add(
            TextSpan(
              text: span.text,
              style: const TextStyle(decoration: TextDecoration.lineThrough),
            ),
          );
        case RichKind.code:
          inline.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _InlineCode(span.text, style: base),
            ),
          );
        case RichKind.spoiler:
          inline.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _Spoiler(span.text, style: base),
            ),
          );
        case RichKind.link:
          inline.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _Link(span.text, style: base),
            ),
          );
      }
    }
    flushInline();

    if (children.length == 1) return children.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          children[i],
        ],
      ],
    );
  }
}

class _InlineCode extends StatelessWidget {
  const _InlineCode(this.text, {required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: style.copyWith(
          fontFamily: 'monospace',
          fontSize: (style.fontSize ?? 15) * 0.92,
        ),
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code, this.language});

  final String code;
  final String? language;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    language?.isNotEmpty == true ? language! : 'code',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Copied'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_rounded),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: SelectableText(
              code,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.35,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Spoiler extends StatefulWidget {
  const _Spoiler(this.text, {required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_Spoiler> createState() => _SpoilerState();
}

class _SpoilerState extends State<_Spoiler> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_revealed) {
      return GestureDetector(
        onTap: () => setState(() => _revealed = false),
        child: Text(widget.text, style: widget.style),
      );
    }
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _revealed = true);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          widget.text,
          style: widget.style.copyWith(
            color: Colors.transparent,
            shadows: const [],
          ),
        ),
      ),
    );
  }
}

class _Link extends StatelessWidget {
  const _Link(this.url, {required this.style});

  final String url;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: () async {
        final uri = Uri.tryParse(url);
        if (uri == null) return;
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      child: Text(
        url,
        style: style.copyWith(
          color: color,
          decoration: TextDecoration.underline,
          decorationColor: color,
        ),
      ),
    );
  }
}
