import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'plugin_host.dart' show PluginHost;
import 'tokens.dart';

/// Opens a link the person tapped. https:// links, bare "pekindustries.com/pektv" style addresses (made https) and, on
/// Windows, e-mail addresses (mailto:) go to the system's default app. Returns false when nothing could open it.
class Links {
  Links._();

  static final _url = RegExp(r'((?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?:/[^\s<>"]*)?)|([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})', caseSensitive: false);

  /// Link-shaped pieces of [text]: (start, end, target). Trailing sentence punctuation stays outside the link.
  static List<(int, int, String)> find(String text) {
    final out = <(int, int, String)>[];
    for (final m in _url.allMatches(text)) {
      var s = m.group(0)!;
      var end = m.end;
      while (s.isNotEmpty && '.,;:!?)]}\'"'.contains(s[s.length - 1])) {
        s = s.substring(0, s.length - 1);
        end--;
      }
      if (s.isEmpty) continue;
      if (m.group(2) != null) {
        out.add((m.start, end, 'mailto:$s'));
      } else {
        // A file name such as "backend.py" or "ui.js" is not an address: a bare host needs a real-looking ending.
        final bare = !s.toLowerCase().startsWith('http');
        if (bare && !RegExp(r'\.(com|net|org|io|tv|dev|app|co|uk|de|fr|nl|eu|me|info|gg|ly)(/|$)', caseSensitive: false).hasMatch(s)) continue;
        out.add((m.start, end, bare ? 'https://$s' : s));
      }
    }
    return out;
  }

  static Future<bool> open(String target) => PluginHost.openUrl(target);
}

/// Text in which web and e-mail addresses are tappable (and underlined), for news, messages and anything else that can
/// carry a link. Same look as [Text]: pass the same [style].
class LinkText extends StatefulWidget {
  const LinkText(this.text, {super.key, this.style, this.maxLines, this.textAlign});
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextAlign? textAlign;

  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  final List<TapGestureRecognizer> _taps = [];

  void _dispose() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _dispose();
    final base = DefaultTextStyle.of(context).style.merge(widget.style);
    final links = Links.find(widget.text);
    if (links.isEmpty) return Text(widget.text, style: widget.style, maxLines: widget.maxLines, textAlign: widget.textAlign);
    final accent = context.pek.tokens.accent;
    final spans = <InlineSpan>[];
    var at = 0;
    for (final (s, e, target) in links) {
      if (s > at) spans.add(TextSpan(text: widget.text.substring(at, s)));
      final tap = TapGestureRecognizer()..onTap = () => Links.open(target);
      _taps.add(tap);
      spans.add(TextSpan(
        text: widget.text.substring(s, e),
        style: TextStyle(color: accent, decoration: TextDecoration.underline, decorationColor: accent),
        recognizer: tap,
        mouseCursor: SystemMouseCursors.click,
      ));
      at = e;
    }
    if (at < widget.text.length) spans.add(TextSpan(text: widget.text.substring(at)));
    return Text.rich(TextSpan(style: base, children: spans), maxLines: widget.maxLines, textAlign: widget.textAlign);
  }
}
