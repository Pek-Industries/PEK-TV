import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'api.dart';
import 'fields.dart' show PekDropdown;
import 'store.dart';
import 'tokens.dart';
import 'tv_nav.dart';
import 'watch_filter.dart';
import 'widgets.dart';

/// How a list is put in order.
enum LibrarySort {
  standard('Default'), // the list's own order (the library's, or most recently watched first in Watch History)
  oldestFirst('Oldest watched'), // Watch History only
  random('Random'),
  titleAz('Title A\u2013Z'),
  titleZa('Title Z\u2013A'),
  yearNew('Year: newest first'),
  yearOld('Year: oldest first');

  const LibrarySort(this.label);
  final String label;

  static const movies = [standard, random, titleAz, titleZa, yearNew, yearOld];
  static const shows = [standard, random, titleAz, titleZa];
  static const history = [standard, oldestFirst, random, titleAz, titleZa];
}

/// "The Matrix" sorts under M, like a shelf does.
String sortKey(String title) => title.toLowerCase().trim().replaceFirst(RegExp(r'^(the|a|an)\s+'), '');

/// [items] in the order [sort] asks for. Never changes [items]. Random uses [seed], so the same seed gives the same order
/// (a list that redraws, e.g. after marking something watched, does not reshuffle by itself). Ties keep their old order.
/// [year] is only needed for the year sorts; a title with no year goes last either way.
List<T> sortedBy<T>(List<T> items, LibrarySort sort, int seed, {required String Function(T) title, int Function(T)? year}) {
  switch (sort) {
    case LibrarySort.standard:
      return items;
    case LibrarySort.oldestFirst:
      return items.reversed.toList();
    case LibrarySort.random:
      return List.of(items)..shuffle(math.Random(seed));
    case LibrarySort.titleAz:
    case LibrarySort.titleZa:
    case LibrarySort.yearNew:
    case LibrarySort.yearOld:
      final idx = List<int>.generate(items.length, (i) => i);
      int byTitle(int a, int b) => sortKey(title(items[a])).compareTo(sortKey(title(items[b])));
      int cmp(int a, int b) {
        int c;
        if (sort == LibrarySort.titleAz) {
          c = byTitle(a, b);
        } else if (sort == LibrarySort.titleZa) {
          c = -byTitle(a, b);
        } else {
          final ya = year?.call(items[a]) ?? 0, yb = year?.call(items[b]) ?? 0;
          if (ya <= 0 || yb <= 0) {
            c = ya > 0 ? -1 : (yb > 0 ? 1 : 0); // no year: last, whichever way the years run
          } else {
            c = sort == LibrarySort.yearNew ? yb.compareTo(ya) : ya.compareTo(yb);
          }
          if (c == 0) c = byTitle(a, b);
        }
        return c != 0 ? c : a.compareTo(b);
      }

      idx.sort(cmp);
      return [for (final i in idx) items[i]];
  }
}

/// What the person picked in the filter bar: watched state, sort, genre and actor, all at once. Genre and actor are answered by
/// the server's library database (the .nfo details); the rest is worked out on the device from [Store].
///
/// One controller per list. The Movies and TV Shows tabs keep theirs while the app runs (leave the tab and come back, the
/// choices are still there); Watch History makes its own.
class LibraryFilters extends ChangeNotifier {
  LibraryFilters({this.only, this.sorts = LibrarySort.movies});

  /// 'movies' | 'shows' | null (both, for Watch History): which of the library's facets and results are read.
  final String? only;
  final List<LibrarySort> sorts;

  WatchFilter watch = WatchFilter.all;
  LibrarySort sort = LibrarySort.standard;
  String genre = '';
  String actor = '';
  int seed = math.Random().nextInt(1 << 30);

  Facets? facets;
  bool _facetsLoading = false;

  /// True while a genre / actor answer is on its way (the list should wait for it, not show everything meanwhile).
  bool pending = false;

  /// True when the server could not answer the genre / actor question.
  bool failed = false;

  ({Set<String> movies, Set<String> shows})? _match; // null = no genre / actor chosen
  int _ticket = 0;

  List<Movie> _library = const []; // Watch History: lets a history entry (title + year) be matched to a library movie id
  Set<String>? _movieKeys;

  /// Anything other than "all, default order, any genre, any actor".
  bool get active => watch != WatchFilter.all || sort != LibrarySort.standard || genre.isNotEmpty || actor.isNotEmpty;

  bool get _byDetails => genre.isNotEmpty || actor.isNotEmpty;

  /// Reads the genre and actor lists once.
  Future<void> loadFacets() async {
    if (facets != null || _facetsLoading) return;
    _facetsLoading = true;
    final f = await Api.libraryFacets('', only: only);
    _facetsLoading = false;
    if (f == null) return; // tried again the next time the page opens
    facets = f;
    notifyListeners();
  }

  void setWatch(WatchFilter f) {
    if (f == watch) return;
    watch = f;
    notifyListeners();
  }

  void setSort(LibrarySort s) {
    if (s == sort) return;
    sort = s;
    if (s == LibrarySort.random) seed = math.Random().nextInt(1 << 30); // choosing Random is a fresh shuffle
    notifyListeners();
  }

  void reshuffle() {
    seed = math.Random().nextInt(1 << 30);
    notifyListeners();
  }

  void setGenre(String g) {
    if (g == genre) return;
    genre = g;
    _refresh();
  }

  void setActor(String a) {
    if (a == actor) return;
    actor = a;
    _refresh();
  }

  /// Everything back to "all, default order, any genre, any actor".
  void clear() {
    watch = WatchFilter.all;
    sort = LibrarySort.standard;
    genre = '';
    actor = '';
    _refresh();
  }

  /// Watch History: the library's movies, so a finished movie can be recognised as one the server listed for a genre / actor.
  void bindLibraryMovies(List<Movie> movies) {
    _library = movies;
    _movieKeys = null;
    if (_byDetails) notifyListeners();
  }

  Future<void> _refresh() async {
    final ticket = ++_ticket;
    _movieKeys = null;
    failed = false;
    if (!_byDetails) {
      _match = null;
      pending = false;
      notifyListeners();
      return;
    }
    pending = true;
    notifyListeners();
    // 5000 is the most the server gives; a genre or an actor is never near that.
    final r = await Api.librarySearch('', genre: genre, actor: actor, limit: 5000, only: only);
    if (ticket != _ticket) return; // a newer pick replaced this one
    pending = false;
    if (r == null) {
      failed = true;
      _match = (movies: <String>{}, shows: <String>{});
    } else {
      _match = (movies: r.movies.toSet(), shows: {for (final t in r.shows) t.toLowerCase().trim()});
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------- does a title pass the genre / actor choice?

  bool allowsMovie(Movie m) => _match == null || _match!.movies.contains(m.id);

  bool allowsShow(Show s) => _match == null || _match!.shows.contains(s.title.toLowerCase().trim());

  /// A Watch History row. Movies are matched by title and year, episodes by their show.
  bool allowsHistory(HistoryEntry e) {
    final m = _match;
    if (m == null) return true;
    if (e.kind == 'episode') return m.shows.contains(e.title.toLowerCase().trim());
    return (_movieKeys ??= _buildKeys()).contains(_movieKey(e.title, e.year));
  }

  /// A Continue watching row.
  bool allowsProgress(Progress r) {
    final m = _match;
    if (m == null) return true;
    if (r.kind == 'episode') return m.shows.contains(r.showTitle.toLowerCase().trim());
    return m.movies.contains(r.id);
  }

  static String _movieKey(String title, int year) => '${title.toLowerCase().trim()}|$year';

  Set<String> _buildKeys() {
    final ids = _match?.movies ?? const <String>{};
    return {for (final m in _library) if (ids.contains(m.id)) _movieKey(m.title, m.year)};
  }
}

/// The filter bar: drop-downs for what to show (watched state), the order, genre and actor, combinable. Genre and actor appear once
/// the library has any (they come from .nfo files). With Random chosen a button shuffles again.
class LibraryFilterBar extends StatelessWidget {
  const LibraryFilterBar({
    super.key,
    required this.filters,
    this.watchOptions = const [WatchFilter.all, WatchFilter.unwatched, WatchFilter.watching, WatchFilter.watched],
    this.counts,
    this.standardLabel = 'Default',
    this.watchTitle = 'Show',
  });

  final LibraryFilters filters;

  /// Which watched states the first drop-down offers (Watch History has no "Unwatched": nothing there is unwatched).
  final List<WatchFilter> watchOptions;

  /// How many titles each watched state would show ("Watching (4)"); null = no numbers.
  final Map<WatchFilter, int>? counts;

  /// What the default order is called here ("Recently watched" in Watch History).
  final String standardLabel;
  final String watchTitle;

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    return ListenableBuilder(
      listenable: filters,
      builder: (context, _) {
        final f = filters.facets;
        final gap = 0.75 * rem;

        List<(String, String)> named(List<MapEntry<String, int>> list, String any, String current) {
          final out = <(String, String)>[('', any)];
          var seen = current.isEmpty;
          for (final e in list) {
            out.add((e.key, '${e.key} (${e.value})'));
            if (e.key == current) seen = true;
          }
          if (!seen) out.insert(1, (current, current)); // a pick that is not among the top names is still shown
          return out;
        }

        Widget field(double w, String label, Widget dropdown) => SizedBox(
              width: w,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(padding: EdgeInsets.only(left: 0.25 * rem, bottom: 0.25 * rem), child: Text(label, style: TextStyle(fontSize: 0.85 * rem, color: t.textMuted))),
                dropdown,
              ]),
            );

        return TvNav.region(
          memoryKey: 'library-filters-${filters.only ?? 'history'}',
          child: LayoutBuilder(builder: (context, box) {
            final avail = box.maxWidth.isFinite ? box.maxWidth : 600.0;
            final double w = p.compact ? (avail - gap) / 2 : ((avail - 3 * gap) / 4).clamp(180.0, 260.0).toDouble();
            final hasDetails = f != null && (f.genres.isNotEmpty || f.actors.isNotEmpty);
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: gap, runSpacing: 0.6 * rem, children: [
                field(
                  w,
                  watchTitle,
                  PekDropdown<WatchFilter>(
                    label: watchTitle,
                    value: filters.watch,
                    items: [for (final o in watchOptions) (o, counts?[o] == null ? o.label : '${o.label} (${counts![o]})')],
                    onChanged: filters.setWatch,
                  ),
                ),
                field(
                  w,
                  'Sort by',
                  PekDropdown<LibrarySort>(
                    label: 'Sort by',
                    value: filters.sort,
                    items: [for (final s in filters.sorts) (s, s == LibrarySort.standard ? standardLabel : s.label)],
                    onChanged: filters.setSort,
                  ),
                ),
                if (f != null && f.genres.isNotEmpty)
                  field(
                    w,
                    'Genre',
                    PekDropdown<String>(label: 'Genre', value: filters.genre, items: named(f.genres, 'Any genre', filters.genre), onChanged: filters.setGenre),
                  ),
                if (f != null && f.actors.isNotEmpty)
                  field(
                    w,
                    'Actor',
                    PekDropdown<String>(label: 'Actor', value: filters.actor, items: named(f.actors, 'Any actor', filters.actor), onChanged: filters.setActor),
                  ),
              ]),
              SizedBox(height: 0.6 * rem),
              Wrap(spacing: gap, runSpacing: 0.5 * rem, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (filters.sort == LibrarySort.random)
                  PekButton(compact: true, label: 'Shuffle again', leading: Icon(Icons.shuffle, size: 1.1 * rem, color: t.accent), onTap: filters.reshuffle),
                if (filters.active) PekButton(compact: true, label: 'Clear filters', onTap: filters.clear),
                if (filters.pending) Text('Filtering\u2026', style: TextStyle(color: t.textMuted)),
              ]),
              if (f != null && !hasDetails)
                Padding(
                  padding: EdgeInsets.only(top: 0.5 * rem),
                  child: Text('Genre and actor filters appear once PEK TV has read .nfo files (the Kodi kind) saved next to your titles.', style: TextStyle(fontSize: 0.9 * rem, color: t.textMuted)),
                ),
            ]);
          }),
        );
      },
    );
  }
}
