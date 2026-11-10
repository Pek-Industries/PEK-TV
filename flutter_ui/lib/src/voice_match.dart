/// Matches the words the speech engine heard against the titles that are really in the library, so "the beer" finds "The Bear"
/// and "open her mer" finds "Oppenheimer". Pure Dart (no I/O, no Flutter), easy to test.
library;

class TitleMatch {
  const TitleMatch(this.title, this.score);

  /// The library's own spelling.
  final String title;

  /// 1 = the same, 0.8 and up = close enough to trust.
  final double score;

  /// The same title, apart from capitals, accents and a leading "the".
  bool get exact => score >= 0.98;

  @override
  String toString() => 'TitleMatch("$title", ${score.toStringAsFixed(2)})';
}

const _accents = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ñ': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y', 'ÿ': 'y', 'ß': 'ss', 'æ': 'ae', 'œ': 'oe',
};

/// Lower case, no accents, only letters and digits, single spaces.
String foldTitle(String s) {
  final sb = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    final c = String.fromCharCode(r);
    sb.write(_accents[c] ?? c);
  }
  return sb.toString().replaceAll("'", '').replaceAll('&', ' and ').replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}

String _noArticle(String s) => s.replaceFirst(RegExp(r'^(the|a|an) '), '');

int _lev(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var cur = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      var v = prev[j] + 1; // deletion
      if (cur[j - 1] + 1 < v) v = cur[j - 1] + 1; // insertion
      if (prev[j - 1] + cost < v) v = prev[j - 1] + cost; // substitution
      cur[j] = v;
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[b.length];
}

double _sim(String a, String b) {
  final m = a.length > b.length ? a.length : b.length;
  if (m == 0) return 0;
  if ((a.length - b.length).abs() > m * 0.4) return 0; // too different in length to be the same words
  final d = _lev(a, b);
  var s = 1 - d / m;
  if (d <= 1 && m >= 4 && s < 0.82) s = 0.82; // one wrong letter in a short title ("beer" / "bear") still counts
  return s;
}

/// How well [heard] fits [title], both already folded with [foldTitle]. 0..1.
double scoreFolded(String heard, String title) {
  if (heard.isEmpty || title.isEmpty) return 0;
  if (heard == title) return 1;
  final a = _noArticle(heard), b = _noArticle(title);
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 0.98;
  if (a.length >= 4 && b.startsWith('$a ')) return 0.9; // said only the start of the title
  if (b.length >= 4 && a.startsWith('$b ')) return 0.86; // said extra words after the title
  final s1 = _sim(a, b);
  final s2 = _sim(a.replaceAll(' ', ''), b.replaceAll(' ', '')); // "open her mer" = "oppenheimer"
  final s = s1 > s2 ? s1 : s2;
  return s > 0.96 ? 0.96 : s; // fuzzy never beats a real match
}

/// The best matches, best first. Only scores of [min] and up.
List<TitleMatch> rankTitles(String heard, Iterable<String> titles, {int limit = 5, double min = 0.8}) {
  final h = foldTitle(heard);
  if (h.isEmpty) return const [];
  final seen = <String>{};
  final out = <TitleMatch>[];
  for (final t in titles) {
    final f = foldTitle(t);
    if (f.isEmpty || !seen.add(f)) continue;
    final s = scoreFolded(h, f);
    if (s >= min) out.add(TitleMatch(t, s));
  }
  out.sort((x, y) => y.score.compareTo(x.score));
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// The one title to use, or null when nothing fits well enough or two different titles fit equally well (then the spoken
/// words are kept, and the search list shows the choices).
TitleMatch? bestTitle(String heard, Iterable<String> titles) {
  final r = rankTitles(heard, titles, limit: 2);
  if (r.isEmpty) return null;
  if (r.length > 1 && !r.first.exact && r.first.score - r[1].score < 0.03) return null;
  return r.first;
}
