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
  yearOld('Year: oldest first'),
  // These four are put in order by the server's library database (the .nfo details), not on the device.
  ratingHigh('Rating: highest first'),
  recentlyAdded('Recently added'),
  runtimeLong('Runtime: longest first'),
  runtimeShort('Runtime: shortest first');

  const LibrarySort(this.label);
  final String label;

  /// The server's name for the order ('' = worked out on the device).
  String get server => switch (this) {
        LibrarySort.ratingHigh => 'rating',
        LibrarySort.recentlyAdded => 'added',
        LibrarySort.runtimeLong => 'runtime',
        LibrarySort.runtimeShort => 'runtime_asc',
        _ => '',
      };

  static const movies = [standard, random, titleAz, titleZa, yearNew, yearOld, ratingHigh, recentlyAdded, runtimeLong, runtimeShort];
  static const shows = [standard, random, titleAz, titleZa, ratingHigh, recentlyAdded];
  static const history = [standard, oldestFirst, random, titleAz, titleZa];
}

/// How long a title runs (the .nfo's runtime). Titles whose .nfo has no runtime are in none of the bands.
enum RuntimeBand {
  any('Any length', 0, 0),
  short('Under 90 min', 0, 89),
  medium('90 min to 2 hours', 90, 120),
  long('Over 2 hours', 121, 0);

  const RuntimeBand(this.label, this.min, this.max);
  final String label;
  final int min; // minutes, 0 = no lower limit
  final int max; // minutes, 0 = no upper limit
}

/// Which titles to read from: all, only those with a .nfo (the details are the .nfo's own), or only those without one.
enum NfoFilter {
  any('Any', ''),
  hasNfo('Has a .nfo', 'with'),
  noNfo('No .nfo', 'without');

  const NfoFilter(this.label, this.server);
  final String label;
  final String server;
}

/// "The Matrix" sorts under M, like a shelf does.
String sortKey(String title) => title.toLowerCase().trim().replaceFirst(RegExp(r'^(the|a|an)\s+'), '');

/// [items] in the order [sort] asks for. Never changes [items]. Random uses [seed], so the same seed gives the same order
/// (a list that redraws, e.g. after marking something watched, does not reshuffle by itself). Ties keep their old order.
/// [year] is only needed for the year sorts; a title with no year goes last either way.
List<T> sortedBy<T>(List<T> items, LibrarySort sort, int seed, {required String Function(T) title, int Function(T)? year}) {
  switch (sort) {
    case LibrarySort.standard:
    case LibrarySort.ratingHigh: // the server's order, applied by the page (LibraryFilters.rankOf...)
    case LibrarySort.recentlyAdded:
    case LibrarySort.runtimeLong:
    case LibrarySort.runtimeShort:
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
  LibraryFilters({this.only, this.sorts = LibrarySort.movies}) {
    // Movies / TV Shows tabs keep their sort order between launches (Settings > Library > Remember sort order).
    if (only == 'movies' || only == 'shows') {
      restoreSort();
      Store.profile.addListener(restoreSort); // another profile has its own saved order
    }
  }

  /// Puts the saved sort order back (or "Default" when none is kept, e.g. another profile or the setting is off).
  void restoreSort() {
    final tab = only;
    if (tab == null) return;
    final saved = Store.savedSort(tab);
    final want = sorts.firstWhere((x) => x.name == saved, orElse: () => LibrarySort.standard);
    if (want != sort) setSort(want, save: false);
  }

  /// 'movies' | 'shows' | null (both, for Watch History): which of the library's facets and results are read.
  final String? only;
  final List<LibrarySort> sorts;

  WatchFilter watch = WatchFilter.all;
  LibrarySort sort = LibrarySort.standard;
  String genre = '';
  String actor = '';
  // The rest of the library search (Movies / TV Shows tabs). All of them read what the title's .nfo says.
  String query = ''; // free text: a title, actor, director, genre, studio, collection or year (every word has to match)
  String director = '';
  String studio = '';
  String collection = '';
  String mpaa = '';
  int decade = 0;
  int year = 0; // one exact year (wins over the decade)
  double minRating = 0; // 0 = any
  RuntimeBand runtime = RuntimeBand.any;
  NfoFilter nfo = NfoFilter.any;
  int clearEpoch = 0; // bumped by clear(), so a search box knows to empty itself
  int seed = math.Random().nextInt(1 << 30);

  Facets? facets;
  bool _facetsLoading = false;

  /// True while a genre / actor answer is on its way (the list should wait for it, not show everything meanwhile).
  bool pending = false;

  /// True when the server could not answer the genre / actor question.
  bool failed = false;

  ({Set<String> movies, Set<String> shows})? _match; // null = no genre / actor chosen
  Map<String, int>? _rankMovies; // the server's own order (movie id -> place), for the orders it makes
  Map<String, int>? _rankShows; // (show title, lower case -> place)
  int _ticket = 0;

  /// The list should wait for the server's answer: nothing to show yet. (While one answer is replaced by a newer one, typing
  /// for example, the last answer stays on screen, so the grid does not blink.)
  bool get blocking => pending && _match == null && query.trim().isEmpty;

  /// True when the server's order is known and should be used ([sort] is one of its orders).
  bool get ordered => sort.server.isNotEmpty && _rankMovies != null;

  int rankOfMovie(Movie m) => _rankMovies?[m.id] ?? (1 << 30);

  int rankOfShow(Show s) => _rankShows?[s.title.toLowerCase().trim()] ?? (1 << 30);

  List<Movie> _library = const []; // Watch History: lets a history entry (title + year) be matched to a library movie id
  Set<String>? _movieKeys;

  /// How many of the extra filters (everything but watched state, sort, genre, actor and the typed text) are on.
  int get moreCount =>
      (director.isNotEmpty ? 1 : 0) +
      (studio.isNotEmpty ? 1 : 0) +
      (collection.isNotEmpty ? 1 : 0) +
      (mpaa.isNotEmpty ? 1 : 0) +
      (decade > 0 || year > 0 ? 1 : 0) +
      (minRating > 0 ? 1 : 0) +
      (runtime != RuntimeBand.any ? 1 : 0) +
      (nfo != NfoFilter.any ? 1 : 0);

  /// Anything other than "all, default order, nothing typed, no filter".
  bool get active => watch != WatchFilter.all || sort != LibrarySort.standard || genre.isNotEmpty || actor.isNotEmpty || query.trim().isNotEmpty || moreCount > 0;

  /// True when the server's library database has to answer (a typed search, a filter or one of its orders).
  bool get _byDetails => genre.isNotEmpty || actor.isNotEmpty || query.trim().isNotEmpty || moreCount > 0 || sort.server.isNotEmpty;

  /// Every filter except the typed text, as one string: the search box's drop-down is only reused while this is the same.
  String get scope => '$genre|$actor|$director|$studio|$collection|$mpaa|$decade|$year|$minRating|${runtime.index}|${nfo.index}';

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

  void setSort(LibrarySort s, {bool save = true}) {
    if (s == sort) return;
    final before = sort.server;
    sort = s;
    if (save && only != null) Store.saveSort(only!, s.name);
    if (s == LibrarySort.random) seed = math.Random().nextInt(1 << 30); // choosing Random is a fresh shuffle
    if (s.server != before) {
      _refresh(); // one of the server's orders (or back to the device's): ask again
      return;
    }
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

  void setQuery(String v) {
    v = v.trim();
    if (v == query) return;
    query = v;
    _refresh();
  }

  void setDirector(String v) {
    if (v == director) return;
    director = v;
    _refresh();
  }

  void setStudio(String v) {
    if (v == studio) return;
    studio = v;
    _refresh();
  }

  void setCollection(String v) {
    if (v == collection) return;
    collection = v;
    _refresh();
  }

  void setMpaa(String v) {
    if (v == mpaa) return;
    mpaa = v;
    _refresh();
  }

  /// A decade and one exact year replace each other.
  void setDecade(int v) {
    if (v == decade && year == 0) return;
    decade = v;
    year = 0;
    _refresh();
  }

  void setYear(int v) {
    if (v == year && decade == 0) return;
    year = v;
    decade = 0;
    _refresh();
  }

  void setMinRating(double v) {
    if (v == minRating) return;
    minRating = v;
    _refresh();
  }

  void setRuntime(RuntimeBand v) {
    if (v == runtime) return;
    runtime = v;
    _refresh();
  }

  void setNfo(NfoFilter v) {
    if (v == nfo) return;
    nfo = v;
    _refresh();
  }

  /// Everything back to "all, default order, nothing typed, any genre, any actor, no extra filter".
  void clear() {
    watch = WatchFilter.all;
    sort = LibrarySort.standard;
    genre = '';
    actor = '';
    query = '';
    director = '';
    studio = '';
    collection = '';
    mpaa = '';
    decade = 0;
    year = 0;
    minRating = 0;
    runtime = RuntimeBand.any;
    nfo = NfoFilter.any;
    clearEpoch++;
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
      _rankMovies = null;
      _rankShows = null;
      pending = false;
      notifyListeners();
      return;
    }
    pending = true;
    // With an answer already on screen (typing a longer search, say) the page stays as it is until the newer answer arrives.
    if (_match == null) notifyListeners();
    // 5000 is the most the server gives; a genre or an actor is never near that.
    final r = await Api.librarySearch(
      query.trim(),
      genre: genre,
      actor: actor,
      director: director,
      studio: studio,
      collection: collection,
      mpaa: mpaa,
      decade: decade,
      year: year,
      minRating: minRating,
      minRuntime: runtime.min,
      maxRuntime: runtime.max,
      nfo: nfo.server,
      sort: sort.server,
      limit: 5000,
      only: only,
    );
    if (ticket != _ticket) return; // a newer pick replaced this one
    pending = false;
    _movieKeys = null; // worked out again from this answer
    if (r == null) {
      failed = true;
      _match = (movies: <String>{}, shows: <String>{});
      _rankMovies = null;
      _rankShows = null;
    } else {
      _match = (movies: r.movies.toSet(), shows: {for (final t in r.shows) t.toLowerCase().trim()});
      _rankMovies = {for (var i = 0; i < r.movies.length; i++) r.movies[i]: i};
      _rankShows = {for (var i = 0; i < r.shows.length; i++) r.shows[i].toLowerCase().trim(): i};
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
