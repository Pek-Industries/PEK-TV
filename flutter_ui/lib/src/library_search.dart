import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, KeyEvent, KeyRepeatEvent, LogicalKeyboardKey;

import 'api.dart';
import 'detail.dart';
import 'fields.dart' show PekDropdown, PekField;
import 'library_pages.dart' show foldText;
import 'library_sort.dart';
import 'suggest.dart';
import 'tokens.dart';
import 'tv_nav.dart';
import 'voice.dart' show VoiceIntent, VoiceKind;
import 'voice_mic.dart';
import 'widgets.dart';

/// Keeps a remote's Up / Down from jumping over the "More filters" button.
///
/// The page is: search box, "More filters" (a short button under the long box), then whatever the list shows. The TV focus search
/// found the long search box or the item below before the short button next to it, so Down from the box and Up from the list
/// both skipped "More filters". This fixes the three moves by name: Down from the search box (or its last suggestion) lands on
/// "More filters"; Up from "More filters" lands on the search box; Up from the first row under "More filters" lands on it.
/// Every other move is left to the normal focus search.
class LibrarySearchNav {
  /// Around the search box and its suggestions.
  final FocusNode searchScope = FocusNode(debugLabel: 'LibrarySearch', canRequestFocus: false, skipTraversal: true);

  /// Around the "More filters" button and the filter chips beside it.
  final FocusNode moreScope = FocusNode(debugLabel: 'LibraryMoreFilters', canRequestFocus: false, skipTraversal: true);

  void dispose() {
    searchScope.dispose();
    moreScope.dispose();
  }

  static Rect? _rect(FocusNode n) {
    try {
      return n.context == null ? null : n.rect;
    } catch (_) {
      return null; // not laid out (yet)
    }
  }

  static bool _within(FocusNode scope, FocusNode? n) {
    for (var x = n; x != null; x = x.parent) {
      if (identical(x, scope)) return true;
    }
    return false;
  }

  /// The top-left item of [scope] (the box / the button), or with [last] the lowest one (the last suggestion).
  static FocusNode? _pick(FocusNode scope, {required bool last}) {
    FocusNode? best;
    double bestTop = 0;
    double bestLeft = 0;
    for (final n in scope.traversalDescendants) {
      final r = _rect(n);
      if (r == null) continue;
      final bool better;
      if (best == null) {
        better = true;
      } else if (last) {
        better = r.top > bestTop + 1;
      } else {
        better = r.top < bestTop - 1 || ((r.top - bestTop).abs() <= 1 && r.left < bestLeft);
      }
      if (better) {
        best = n;
        bestTop = r.top;
        bestLeft = r.left;
      }
    }
    return best;
  }

  static bool _focus(FocusNode? n) {
    if (n == null || !n.canRequestFocus) return false;
    n.requestFocus();
    final c = n.context;
    if (c != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!c.mounted) return;
        Scrollable.ensureVisible(c, duration: TvNav.scrollDuration, curve: TvNav.scrollCurve, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
        Scrollable.ensureVisible(c, duration: TvNav.scrollDuration, curve: TvNav.scrollCurve, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
      });
    }
    return true;
  }

  /// Puts the focus on "More filters". true = it moved.
  bool focusMore() => _focus(_pick(moreScope, last: false));

  /// Put this on a [Focus] around the whole page (it sees the keys of every item inside).
  KeyEventResult onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k != LogicalKeyboardKey.arrowDown && k != LogicalKeyboardKey.arrowUp) return KeyEventResult.ignored;
    final cur = FocusManager.instance.primaryFocus;
    if (cur == null) return KeyEventResult.ignored;

    if (k == LogicalKeyboardKey.arrowDown) {
      if (!_within(searchScope, cur)) return KeyEventResult.ignored;
      // Only the lowest item of the search area moves on: a middle suggestion keeps walking down the list.
      if (!identical(_pick(searchScope, last: true), cur)) return KeyEventResult.ignored;
      return focusMore() ? KeyEventResult.handled : KeyEventResult.ignored;
    }

    // Up
    if (_within(moreScope, cur)) {
      return _focus(_pick(searchScope, last: false)) ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (_within(searchScope, cur)) return KeyEventResult.ignored;
    final more = _pick(moreScope, last: false);
    final moreR = more == null ? null : _rect(more);
    final curR = _rect(cur);
    final scope = cur.nearestScope;
    if (more == null || moreR == null || curR == null || scope == null) return KeyEventResult.ignored;
    if (curR.top <= moreR.bottom) return KeyEventResult.ignored; // not under the button
    // Something else between the button and this item (the sort bar, a poster row above)? Then the normal move is right.
    for (final n in scope.traversalDescendants) {
      if (identical(n, cur) || _within(searchScope, n) || _within(moreScope, n)) continue;
      final r = _rect(n);
      if (r == null) continue;
      final sameColumn = r.right > curR.left && r.left < curR.right; // the sidebar is beside the page, not above this item
      if (sameColumn && r.top >= moreR.bottom - 2 && r.top < curR.top - 4) return KeyEventResult.ignored;
    }
    return _focus(more) ? KeyEventResult.handled : KeyEventResult.ignored;
  }
}

/// The search bar of the Movies and TV Shows tabs, with its drop-down of matching titles and the "More filters" panel.
///
/// What it reads: the title, year and everything the title's .nfo says (genres, cast, director, studio, collection, rating,
/// runtime, certificate). Where a title has a .nfo, the .nfo's title and details are used; a title without one is still found by
/// its title and year, and simply has no genre, cast or rating to match on.
///
/// How it behaves while typing (the same logic as the plugins' search):
///  * the drop-down narrows on every letter, from titles already known (the library on this device and every earlier answer),
///    so there is no wait and no blank gap between two letters;
///  * the server is asked a moment after the typing slows down, and its answer only adds to the list (cast, genre and studio
///    matches, ratings); the order is the same every time, so rows do not shuffle under the finger;
///  * an answer that arrives late never reopens a list that was closed, and one for older text never replaces newer text;
///  * the grid under the box follows the typed text too, a little later, and keeps showing its last answer until the new one is there.
class LibrarySearchPanel extends StatefulWidget {
  const LibrarySearchPanel({super.key, required this.filters, required this.tab, required this.library, required this.nav});

  final LibraryFilters filters;

  /// 'movies' | 'shows'
  final String tab;

  /// The Movie / Show objects of the library as loaded now (read when needed, so it follows reloads).
  final List<Object> Function() library;

  /// Marks the search box and the "More filters" row so the remote's Up / Down land on each (the page's key handler is [LibrarySearchNav.onKey]).
  final LibrarySearchNav nav;

  @override
  State<LibrarySearchPanel> createState() => _LibrarySearchPanelState();
}

class _Row {
  const _Row({required this.key, required this.isShow, required this.id, required this.title, required this.year, required this.fold, this.s});
  final String key; // 'm:<id>' | 's:<title, lower case>'
  final bool isShow;
  final String id;
  final String title;
  final int year;
  final String fold; // the title, folded (no capitals, no accents)
  final LibSuggest? s; // the server's details (from the .nfo); null = only known from the library list
}

class _LibrarySearchPanelState extends State<LibrarySearchPanel> {
  static const _maxRows = 6;
  static final String _plainScope = LibraryFilters().scope; // the scope with no filter on

  final _q = TextEditingController();
  Timer? _fetchTimer;
  Timer? _liveTimer;

  final Map<String, List<LibSuggest>> _cache = {}; // scope#folded text -> the server's rows
  final Map<String, String> _hay = {}; // row key -> everything searchable about it, folded
  List<LibSuggest> _pool = const []; // every row the server has sent for this scope, newest first
  final Set<String> _busy = {};
  String _scope = '';
  String _typed = ''; // the folded text the drop-down is for; '' = closed
  String _typedRaw = '';
  List<_Row> _rows = const [];
  final Map<String, Future<String>> _thumbs = {}; // one poster look-up per title, so the list does not blink while typing

  Object? _libSeen;
  Map<String, Movie> _movies = const {};
  Map<String, Show> _shows = const {};

  bool _more = false;
  int _seenClear = 0;

  @override
  void initState() {
    super.initState();
    final f = widget.filters;
    _scope = f.scope;
    _seenClear = f.clearEpoch;
    _q.text = f.query; // the tab remembers what was typed while the app runs
    f.addListener(_onFilters);
  }

  @override
  void dispose() {
    widget.filters.removeListener(_onFilters);
    _fetchTimer?.cancel();
    _liveTimer?.cancel();
    _q.dispose();
    super.dispose();
  }

  /// A filter changed (or "Clear filters" was pressed).
  void _onFilters() {
    if (!mounted) return;
    final f = widget.filters;
    if (f.clearEpoch != _seenClear) {
      _seenClear = f.clearEpoch;
      _q.clear();
      _closeList();
    }
    if (f.scope != _scope) {
      // Drop-down answers are only right for the filters they were asked with.
      _scope = f.scope;
      _cache.clear();
      _pool = const [];
      _busy.clear();
      if (_typed.isNotEmpty) {
        _recompute();
        _fetchTimer?.cancel();
        _fetchTimer = Timer(const Duration(milliseconds: 120), _fetch);
      }
    }
    setState(() {});
  }

  // ---------------------------------------------------------------- the library on this device

  void _index() {
    final lib = widget.library();
    if (identical(lib, _libSeen)) return;
    _libSeen = lib;
    _movies = {for (final o in lib) if (o is Movie) o.id: o};
    _shows = {for (final o in lib) if (o is Show) o.title.toLowerCase().trim(): o};
  }

  // ---------------------------------------------------------------- typing

  void _onChanged(String v) {
    _typedRaw = v;
    _typed = foldText(v);
    _liveTimer?.cancel();
    if (v.trim().isEmpty) {
      widget.filters.setQuery(''); // an emptied box shows everything again at once
    } else {
      _liveTimer = Timer(const Duration(milliseconds: 350), () => widget.filters.setQuery(v));
    }
    _recompute(); // narrowing from what is known: on every letter, no timer
    _fetchTimer?.cancel();
    if (_typed.length >= 2) _fetchTimer = Timer(const Duration(milliseconds: 120), _fetch);
    setState(() {});
  }

  void _submit() {
    _liveTimer?.cancel();
    widget.filters.setQuery(_q.text);
    _closeList();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {});
  }

  /// A spoken request from the mic button: fill the box with the title and run the search.
  void _onVoice(VoiceIntent i) {
    if (i.kind != VoiceKind.play && i.kind != VoiceKind.search) return; // open / resume are handled by the shell
    // A show is searched by its title alone ("lioness season 2 episode 1" -> "lioness"); a movie may have "Episode 1" in its name.
    final title = widget.tab == 'movies' ? i.full : i.text;
    _q.text = title;
    _onChanged(title);
    _submit();
  }

  /// The titles of this tab (movies or shows) as loaded now: the mic matches what it heard against them.
  List<String> _titles() {
    _index();
    return widget.tab == 'movies' ? [for (final m in _movies.values) m.title] : [for (final s in _shows.values) s.title];
  }

  void _closeList() {
    _typed = '';
    _typedRaw = '';
    _rows = const [];
    _fetchTimer?.cancel();
  }

  Future<void> _fetch() async {
    final raw = _typedRaw;
    final qn = foldText(raw);
    if (qn.length < 2) return;
    final scope = _scope;
    final key = '$scope#$qn';
    if (_cache.containsKey(key) || !_busy.add(key)) return;
    final f = widget.filters;
    final rows = await Api.librarySuggest(
      raw.trim(),
      type: widget.tab == 'movies' ? 'movies' : 'shows',
      limit: 15, // the server answers in title order; the best few of these are picked here
      genre: f.genre,
      actor: f.actor,
      director: f.director,
      studio: f.studio,
      collection: f.collection,
      mpaa: f.mpaa,
      decade: f.decade,
      year: f.year,
      minRating: f.minRating,
      minRuntime: f.runtime.min,
      maxRuntime: f.runtime.max,
      nfo: f.nfo.server,
    );
    _busy.remove(key);
    if (!mounted || rows == null || scope != _scope) return; // no answer, or the filters changed meanwhile
    if (_cache.length >= 60) _cache.remove(_cache.keys.first);
    _cache[key] = rows;
    final fresh = {for (final r in rows) r.key};
    _pool = [...rows, ..._pool.where((p) => !fresh.contains(p.key))].take(300).toList();
    setState(_recompute); // for whatever is typed now (which may be longer than what was asked)
  }

  String _hayOf(LibSuggest s) => _hay.putIfAbsent(s.key, () => foldText('${s.title} ${s.year > 0 ? s.year : ''} ${s.genres.join(' ')} ${s.cast.join(' ')} ${s.directors.join(' ')} ${s.studio} ${s.mpaa}'));

  _Row? _rowOf(LibSuggest s) {
    _index();
    if (s.isShow ? !_shows.containsKey(s.id.toLowerCase().trim()) : !_movies.containsKey(s.id)) return null; // gone from the library
    return _Row(key: s.key, isShow: s.isShow, id: s.id, title: s.title, year: s.year, fold: foldText(s.title), s: s);
  }

  int _score(String title, String qn, List<String> words) {
    if (title == qn) return 0;
    if (title.startsWith(qn)) return 1;
    final tw = title.split(' ');
    if (words.every((w) => tw.any((x) => x.startsWith(w)))) return 2;
    if (title.contains(qn)) return 3;
    return 4; // came up through its cast, genre, studio ...
  }

  /// The rows for the text now in the box, worked out from what is known. Always the same order for the same rows.
  void _recompute() {
    final qn = _typed;
    if (qn.length < 2) {
      _rows = const [];
      return;
    }
    _index();
    final words = qn.split(' ').where((w) => w.isNotEmpty).toList();
    final seen = <String>{};
    final cands = <_Row>[];
    void add(_Row? r) {
      if (r != null && seen.add(r.key)) cands.add(r);
    }

    final answer = _cache['$_scope#$qn'];
    if (answer != null) {
      for (final s in answer) {
        add(_rowOf(s));
      }
    } else {
      for (final s in _pool) {
        if (words.every(_hayOf(s).contains)) add(_rowOf(s));
      }
      // Titles on this device answer at once when no other filter is on (with a filter on, only the server knows what fits).
      if (_scope == _plainScope) {
        for (final m in _movies.values) {
          final f = foldText('${m.title} ${m.year > 0 ? m.year : ''}');
          if (words.every(f.contains)) add(_Row(key: 'm:${m.id}', isShow: false, id: m.id, title: m.title, year: m.year, fold: foldText(m.title)));
        }
        for (final sh in _shows.values) {
          final f = foldText(sh.title);
          if (words.every(f.contains)) add(_Row(key: 's:${sh.title.toLowerCase().trim()}', isShow: true, id: sh.title, title: sh.title, year: 0, fold: f));
        }
      }
    }
    final scored = [for (final r in cands) (_score(r.fold, qn, words), r)];
    scored.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : (a.$2.fold != b.$2.fold ? a.$2.fold.compareTo(b.$2.fold) : a.$2.key.compareTo(b.$2.key)));
    _rows = [for (final e in scored.take(_maxRows)) e.$2];
  }

  // ---------------------------------------------------------------- the drop-down

  String _sub(_Row r) {
    final s = r.s;
    final parts = <String>[];
    if (r.year > 0) parts.add('${r.year}');
    parts.add(r.isShow ? 'TV show' : 'Movie');
    if (s != null) {
      if (s.match.isNotEmpty) {
        parts.add(s.match);
      } else if (s.genres.isNotEmpty) {
        parts.add(s.genres.take(2).join(', '));
      }
      if (s.rating > 0) parts.add('\u2605 ${s.rating.toStringAsFixed(1)}');
    }
    return parts.join(' \u00b7 ');
  }

  Future<String> _thumb(_Row r) => _thumbs.putIfAbsent(r.key, () => (r.isShow ? Api.showDetails(r.id) : Api.movieDetails(r.id)).then((x) => x.poster).catchError((_) => ''));

  void _open(_Row r) {
    _index();
    final nav = Navigator.of(context);
    FocusManager.instance.primaryFocus?.unfocus();
    setState(_closeList);
    if (r.isShow) {
      final sh = _shows[r.id.toLowerCase().trim()];
      if (sh != null) nav.push(MaterialPageRoute<void>(builder: (_) => ShowScreen(show: sh)));
    } else {
      final m = _movies[r.id];
      if (m != null) nav.push(MaterialPageRoute<void>(builder: (_) => MovieScreen(movie: m)));
    }
  }

  List<SuggestItem> _items() => [
        for (final r in _rows) SuggestItem(title: r.title, sub: _sub(r), imageLater: _thumb(r), onTap: () => _open(r)),
      ];

  // ---------------------------------------------------------------- the panel

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final rem = p.rem;
    final movies = widget.tab == 'movies';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end, // the mic lines up with the box, not with the label above it
          children: [
            Expanded(
              child: Focus(
                  focusNode: widget.nav.searchScope,
                  canRequestFocus: false,
                  skipTraversal: true,
                  child: SuggestAnchor(
                    controller: _q,
                    items: _items(),
                    onDownWithoutList: widget.nav.focusMore, // typing in the box: Down goes straight to "More filters"
                    field: PekField(
                      label: movies ? 'Search your movies' : 'Search your TV shows',
                      controller: _q,
                      hint: 'Title, actor, director, genre, studio or year',
                      onChanged: _onChanged,
                      onSubmitted: _submit,
                    ),
                  ),
                ),
            ),
            SizedBox(width: 0.6 * rem),
            VoiceMic(onIntent: _onVoice, titles: _titles),
          ],
        ),
        SizedBox(height: 0.6 * rem),
        ListenableBuilder(listenable: widget.filters, builder: (context, _) => _moreFilters(context)),
        SizedBox(height: (p.isTv ? 1.25 : 1) * rem),
      ],
    );
  }

  List<(String, String)> _named(List<MapEntry<String, int>> list, String any, String current) {
    final out = <(String, String)>[('', any)];
    var seen = current.isEmpty;
    for (final e in list) {
      out.add((e.key, '${e.key} (${e.value})'));
      if (e.key == current) seen = true;
    }
    if (!seen) out.insert(1, (current, current)); // a pick that is not among the top names is still shown
    return out;
  }

  Widget _moreFilters(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final f = widget.filters;
    final fa = f.facets;

    Widget chip(String label, VoidCallback off) => PekButton(compact: true, primary: true, label: '$label \u2715', onTap: off);

    final top = Wrap(
      spacing: 0.5 * rem,
      runSpacing: 0.5 * rem,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        PekButton(
          compact: true,
          primary: _more,
          label: f.moreCount > 0 ? 'More filters (${f.moreCount})' : 'More filters',
          leading: Icon(_more ? Icons.expand_less : Icons.expand_more, size: 1.2 * rem, color: _more ? t.bg : t.accent),
          onTap: () => setState(() => _more = !_more),
        ),
        if (f.director.isNotEmpty) chip('Dir. ${f.director}', () => f.setDirector('')),
        if (f.studio.isNotEmpty) chip(f.studio, () => f.setStudio('')),
        if (f.collection.isNotEmpty) chip(f.collection, () => f.setCollection('')),
        if (f.mpaa.isNotEmpty) chip('Rated ${f.mpaa}', () => f.setMpaa('')),
        if (f.year > 0) chip('${f.year}', () => f.setYear(0)) else if (f.decade > 0) chip('${f.decade}s', () => f.setDecade(0)),
        if (f.minRating > 0) chip('\u2605 ${f.minRating.toStringAsFixed(0)}+', () => f.setMinRating(0)),
        if (f.runtime != RuntimeBand.any) chip(f.runtime.label, () => f.setRuntime(RuntimeBand.any)),
        if (f.nfo != NfoFilter.any) chip(f.nfo.label, () => f.setNfo(NfoFilter.any)),
      ],
    );
    // Always the same widgets in the same place (a Column whose first child is this row): opening or closing the panel used to
    // rebuild the button from scratch, and a focused button that is rebuilt loses the focus.
    final topRow = Focus(focusNode: widget.nav.moreScope, canRequestFocus: false, skipTraversal: true, child: top);
    if (!_more) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [topRow]);

    Widget field(double w, String label, Widget dropdown) => SizedBox(
          width: w,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: EdgeInsets.only(left: 0.25 * rem, bottom: 0.25 * rem), child: Text(label, style: TextStyle(fontSize: 0.85 * rem, color: t.textMuted))),
            dropdown,
          ]),
        );

    final panel = TvNav.region(
      memoryKey: 'library-more-${widget.tab}',
      child: LayoutBuilder(builder: (context, box) {
        final avail = box.maxWidth.isFinite ? box.maxWidth : 600.0;
        final gap = 0.75 * rem;
        final double w = p.compact ? (avail - gap) / 2 : ((avail - 3 * gap) / 4).clamp(180.0, 260.0).toDouble();
        final fields = <Widget>[
          if (fa != null && fa.directors.isNotEmpty)
            field(w, 'Director', PekDropdown<String>(label: 'Director', value: f.director, items: _named(fa.directors, 'Any director', f.director), onChanged: f.setDirector)),
          if (fa != null && fa.studios.isNotEmpty)
            field(w, 'Studio', PekDropdown<String>(label: 'Studio', value: f.studio, items: _named(fa.studios, 'Any studio', f.studio), onChanged: f.setStudio)),
          if (fa != null && fa.collections.isNotEmpty)
            field(w, 'Collection', PekDropdown<String>(label: 'Collection', value: f.collection, items: _named(fa.collections, 'Any collection', f.collection), onChanged: f.setCollection)),
          if (fa != null && fa.mpaas.isNotEmpty)
            field(w, 'Rated', PekDropdown<String>(label: 'Rated', value: f.mpaa, items: _named(fa.mpaas, 'Any rating', f.mpaa), onChanged: f.setMpaa)),
          if (fa != null && fa.decades.isNotEmpty)
            field(
              w,
              'Decade',
              PekDropdown<int>(
                label: 'Decade',
                value: f.decade,
                items: [(0, 'Any decade'), for (final e in fa.decades) (int.tryParse(e.key) ?? 0, '${e.key}s (${e.value})')],
                onChanged: f.setDecade,
              ),
            ),
          if (fa != null && fa.years.isNotEmpty)
            field(
              w,
              'Year',
              PekDropdown<int>(
                label: 'Year',
                value: f.year,
                items: [(0, 'Any year'), for (final e in fa.years) (int.tryParse(e.key) ?? 0, '${e.key} (${e.value})')],
                onChanged: f.setYear,
              ),
            ),
          field(
            w,
            'Rating',
            PekDropdown<double>(
              label: 'Rating',
              value: f.minRating,
              items: const [(0.0, 'Any rating'), (6.0, '6 and up'), (7.0, '7 and up'), (8.0, '8 and up'), (9.0, '9 and up')],
              onChanged: f.setMinRating,
            ),
          ),
          field(
            w,
            'Runtime',
            PekDropdown<RuntimeBand>(label: 'Runtime', value: f.runtime, items: [for (final b in RuntimeBand.values) (b, b.label)], onChanged: f.setRuntime),
          ),
          field(
            w,
            'Details from',
            PekDropdown<NfoFilter>(
              label: 'Details from',
              value: f.nfo,
              items: [
                for (final o in NfoFilter.values)
                  (o, fa == null || o == NfoFilter.any ? o.label : '${o.label} (${o == NfoFilter.hasNfo ? fa.nfoWith : fa.nfoWithout})'),
              ],
              onChanged: f.setNfo,
            ),
          ),
        ];
        return Wrap(spacing: gap, runSpacing: 0.6 * rem, children: fields);
      }),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      topRow,
      SizedBox(height: 0.75 * rem),
      panel,
      if (fa != null && fa.directors.isEmpty && fa.studios.isEmpty && fa.mpaas.isEmpty)
        Padding(
          padding: EdgeInsets.only(top: 0.5 * rem),
          child: Text('Director, studio, collection and rating filters appear once PEK TV has read .nfo files (the Kodi kind) saved next to your titles.', style: TextStyle(fontSize: 0.9 * rem, color: t.textMuted)),
        ),
    ]);
  }
}
