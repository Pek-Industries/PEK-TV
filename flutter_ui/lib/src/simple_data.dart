import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'detail.dart';
import 'plugin_ui.dart' show openPluginScreen;
import 'ratings.dart';
import 'recs.dart';
import 'store.dart';

/// Data behind the Simple layout (simple_shell.dart, simple_detail.dart): one type for "a movie or a show of the library", the
/// library lookups, what TMDb says about a title (trailer, wide picture, genres, recommendations) and the Play button's logic.

/// One movie or show: one of the library's, or a suggestion from TMDb that the library does not have ([rec]; its Play button opens
/// the TMDb Discover plugin's page for it).
class SimpleTitle {
  const SimpleTitle.movie(this.movie)
      : show = null,
        rec = null;
  const SimpleTitle.show(this.show)
      : movie = null,
        rec = null;
  const SimpleTitle.rec(this.rec)
      : movie = null,
        show = null;
  final Movie? movie;
  final Show? show;
  final RecItem? rec;

  bool get inLibrary => rec == null;
  bool get tv => rec != null ? rec!.tv : show != null;
  String get title => rec?.title ?? show?.title ?? movie!.title;
  int get year => rec?.year ?? movie?.year ?? 0;

  /// Same keys as the favorites use (`m:<file id>`, `s:<show title>`); a suggestion's is `r:` and its TMDb key.
  String get key => rec != null ? 'r:${rec!.key}' : (tv ? 's:${show!.title}' : 'm:${movie!.id}');
  Future<Details> get details => rec != null
      ? Future.value(Details(overview: rec!.overview, poster: rec!.poster.isEmpty ? '' : rec!.image))
      : (tv ? Api.showDetails(show!.title) : Api.movieDetails(movie!.id));
  String get subtitle => rec != null ? (rec!.year > 0 ? '${rec!.year}' : '') : (tv ? '${show!.episodeCount} episodes' : (movie!.year > 0 ? '${movie!.year}' : ''));

  /// "My List": a library title is a favorite, a suggestion is a TMDb Discover favorite (the same list, shown in Favorites).
  bool get favorite => rec != null ? Store.pluginFavoriteKeys().contains('${tv ? 'tv' : 'movie'}:${rec!.id}') : Store.isFavorite(key);

  /// Adds or removes it from My List. Adding also counts as "liked": the For You rows are built from it (first row).
  Future<void> toggleFavorite() async {
    final on = !favorite;
    final r = rec;
    if (r != null) {
      final type = r.tv ? 'tv' : 'movie';
      if (on) {
        await Store.addPluginFavorite(plugin: 'tmdb-discover', type: type, id: r.id, title: r.title, year: r.tv ? 0 : r.year, posterPath: r.poster);
      } else {
        await Store.removePluginFavorite('$type:${r.id}');
      }
    } else {
      await Store.toggleFavorite(tv ? Favorite.show(show!.title) : Favorite.movie(movie!.id, movie!.title, movie!.year));
    }
    await simpleSetLiked(this, on);
  }
}

/// Keeps the taste picker's list in step with My List: a liked title goes to the end of it (the For You home shows the newest like
/// as its first row), an un-liked one leaves it.
Future<void> simpleSetLiked(SimpleTitle t, bool on) async {
  var id = t.rec?.id ?? 0;
  if (on && id <= 0) id = (await SimpleMeta.of(t)).tmdbId;
  final norm = Store.normalize(t.title);
  final picks = [for (final p in Recs.picks) if (!(p.tv == t.tv && Store.normalize(p.title) == norm)) p];
  if (on && id > 0) picks.add(RecPick(id: id, tv: t.tv, title: t.title, year: t.year, poster: t.rec?.poster ?? ''));
  await Recs.setPicks(picks);
}

/// How far along the person is in each title, for the thin bar at the bottom of a card (Netflix's red line). Built from everything
/// with a resume point, whether it was watched from the library or started by a plugin (a stream carries the title it was
/// called). Movies are found by file id, then by name; a show by name (its episodes carry the show's title). null = not started.
class SimpleProgress {
  SimpleProgress._(this._byId, this._movieName, this._showName);
  factory SimpleProgress.empty() => SimpleProgress._({}, {}, {});

  factory SimpleProgress.now() {
    final byId = <String, double>{};
    final movieName = <String, double>{};
    final showName = <String, double>{};
    for (final r in Store.resumeItems()) {
      // newest first, so the first one seen for a name is the latest watch
      if (r.duration <= 0) continue;
      final f = (r.position / r.duration).clamp(0.0, 1.0).toDouble();
      byId.putIfAbsent(r.id, () => f);
      if (r.kind == 'episode') {
        showName.putIfAbsent(Store.normalize(r.showTitle.isNotEmpty ? r.showTitle : r.title), () => f);
      } else {
        movieName.putIfAbsent(Store.normalize(r.title), () => f);
      }
    }
    return SimpleProgress._(byId, movieName, showName);
  }

  final Map<String, double> _byId;
  final Map<String, double> _movieName;
  final Map<String, double> _showName;

  double? of(SimpleTitle t) {
    double? f;
    if (t.movie != null) f = _byId[t.movie!.id];
    f ??= (t.tv ? _showName : _movieName)[Store.normalize(t.title)];
    return f != null && f > 0 ? f : null;
  }
}

/// What the For You rows are built from, best first: the titles liked on the taste picker or added to My List here (newest first),
/// favorites, then 7+ ratings and what was watched.
List<RecSeed> simpleSeeds() {
  final out = <RecSeed>[];
  final seen = <String>{};
  void add(String title, bool tv, int year, double weight, bool liked) {
    if (title.isEmpty) return;
    if (seen.add('${tv ? 't' : 'm'}|${Store.normalize(title)}')) out.add(RecSeed(title: title, tv: tv, year: tv ? 0 : year, weight: weight, liked: liked));
  }

  for (final p in Recs.picks.reversed) {
    add(p.title, p.tv, p.year, 3, true);
  }
  for (final f in Store.favorites()) {
    add(f.title, f.kind != 'movie', f.year, 3, true);
  }
  for (final f in Store.pluginFavorites()) {
    add('${f['title'] ?? ''}', '${f['type']}' == 'tv', (f['year'] as num?)?.toInt() ?? 0, 3, true);
  }
  for (final s in RecFeed.seedsFrom(Store.history(), Ratings.all(), DateTime.now().millisecondsSinceEpoch, take: 8)) {
    add(s.title, s.tv, s.year, s.weight, s.liked);
  }
  return out;
}

/// The movies and shows the server knows, with the lookups the Simple layout needs.
class SimpleLib {
  SimpleLib(this.movies, this.shows)
      : _movieById = {for (final m in movies) m.id: m},
        _showByTitle = {for (final s in shows) s.title: s},
        _movieByName = {for (final m in movies) Store.normalize(m.title): m},
        _showByName = {for (final s in shows) Store.normalize(s.title): s};

  final List<Movie> movies;
  final List<Show> shows;
  final Map<String, Movie> _movieById;
  final Map<String, Show> _showByTitle;
  final Map<String, Movie> _movieByName;
  final Map<String, Show> _showByName;

  static Future<SimpleLib> load() async {
    final r = await Future.wait<dynamic>([Api.movies(), Api.shows()]);
    return SimpleLib(List<Movie>.from(r[0] as List), List<Show>.from(r[1] as List));
  }

  bool get isEmpty => movies.isEmpty && shows.isEmpty;

  Movie? movieById(String id) => _movieById[id];
  Show? showByTitle(String title) => _showByTitle[title];

  /// A library title called [name] (a TMDb recommendation, say), or null when the library has none.
  SimpleTitle? named(String name, {required bool tv}) {
    final k = Store.normalize(name);
    if (tv) {
      final s = _showByName[k];
      return s == null ? null : SimpleTitle.show(s);
    }
    final m = _movieByName[k];
    return m == null ? null : SimpleTitle.movie(m);
  }

  /// A TMDb suggestion as the library's own title when the library has it (so Play plays it), else as a suggestion.
  SimpleTitle fromRec(RecItem r) => named(r.title, tv: r.tv) ?? SimpleTitle.rec(r);

  /// The answer of `Api.librarySearch` (file ids and show titles) as titles.
  List<SimpleTitle> fromSearch(({List<String> movies, List<String> shows}) r) => [
        for (final id in r.movies)
          if (_movieById[id] != null) SimpleTitle.movie(_movieById[id]!),
        for (final t in r.shows)
          if (_showByTitle[t] != null) SimpleTitle.show(_showByTitle[t]!),
      ];

  List<SimpleTitle> get recentMovies => [for (final m in movies.reversed.take(24)) SimpleTitle.movie(m)];
  List<SimpleTitle> get recentShows => [for (final s in shows.reversed.take(24)) SimpleTitle.show(s)];

  /// Newest movies and shows taking turns ("New").
  List<SimpleTitle> get recentMixed {
    final a = recentMovies, b = recentShows;
    final out = <SimpleTitle>[];
    for (var i = 0; i < a.length || i < b.length; i++) {
      if (i < a.length) out.add(a[i]);
      if (i < b.length) out.add(b[i]);
    }
    return out;
  }

  /// This profile's favorites ("My List"): the library's own first, then the ones saved from TMDb Discover.
  List<SimpleTitle> get myList {
    final out = <SimpleTitle>[];
    final seen = <String>{};
    void add(SimpleTitle t) {
      if (seen.add(t.key)) out.add(t);
    }

    for (final f in Store.favorites()) {
      if (f.kind == 'movie') {
        final m = _movieById[f.ref];
        if (m != null) add(SimpleTitle.movie(m));
      } else {
        final s = _showByTitle[f.ref];
        if (s != null) add(SimpleTitle.show(s));
      }
    }
    for (final f in Store.pluginFavorites()) {
      final id = (f['id'] as num?)?.toInt() ?? 0;
      final title = '${f['title'] ?? ''}';
      if (id <= 0 || title.isEmpty) continue;
      final tv = '${f['type']}' == 'tv';
      add(named(title, tv: tv) ?? SimpleTitle.rec(RecItem(id: id, tv: tv, title: title, year: (f['year'] as num?)?.toInt() ?? 0, poster: '${f['posterPath'] ?? ''}')));
    }
    return out;
  }
}

/// What TMDb says about a library title, asked once through the app's TMDb proxy (the same one the recommendations use).
class SimpleMeta {
  const SimpleMeta({this.ok = false, this.tmdbId = 0, this.trailer = '', this.backdrop = '', this.overview = '', this.genres = const [], this.vote = 0, this.runtime = 0, this.seasons = 0, this.related = const []});

  /// false = TMDb had no answer (offline, or no match): the banner just shows the library's own poster.
  final bool ok;

  /// The title's TMDb id, 0 = unknown.
  final int tmdbId;

  /// 11-character YouTube id of the best trailer or teaser, '' = none.
  final String trailer;

  /// Wide picture address (TMDb w1280), '' = none.
  final String backdrop;
  final String overview;
  final List<String> genres;
  final double vote; // 0..10
  final int runtime; // minutes (movies)
  final int seasons; // shows
  final List<RecItem> related;

  static const none = SimpleMeta();
  static final _cache = <String, Future<SimpleMeta>>{};
  static final _goodPath = RegExp(r'^/[A-Za-z0-9_\-]+\.(jpg|jpeg|png|webp)$');

  /// An answer is kept for the session; "no answer" is not (so the next look asks again).
  static Future<SimpleMeta> of(SimpleTitle t) {
    final hit = _cache[t.key];
    if (hit != null) return hit;
    final f = _load(t);
    _cache[t.key] = f;
    unawaited(f.then((m) {
      if (!m.ok) _cache.remove(t.key);
    }));
    return f;
  }

  static Future<SimpleMeta> _load(SimpleTitle t) async {
    try {
      final id = t.rec?.id ?? (t.tv ? await RecFeed.tvIdByName(t.title) : await RecFeed.movieIdByName(t.title, year: t.year));
      if (id <= 0) return none;
      final j = await RecFeed.info(id, t.tv);
      if (j == null) return none;
      final bp = '${j['backdrop_path'] ?? ''}';
      final genres = <String>[
        for (final g in ((j['genres'] as List?) ?? const []).whereType<Map>())
          if ('${g['name'] ?? ''}'.isNotEmpty) '${g['name']}',
      ];
      return SimpleMeta(
        ok: true,
        tmdbId: id,
        trailer: pickTrailer(j),
        backdrop: _goodPath.hasMatch(bp) ? '${RecFeed.imageBase}/w1280$bp' : '',
        overview: '${j['overview'] ?? ''}',
        genres: genres,
        vote: (j['vote_average'] as num?)?.toDouble() ?? 0,
        runtime: (j['runtime'] as num?)?.toInt() ?? 0,
        seasons: (j['number_of_seasons'] as num?)?.toInt() ?? 0,
        related: RecFeed.parseResults(j['recommendations'], t.tv),
      );
    } catch (_) {
      return none;
    }
  }

  /// The best YouTube trailer in a TMDb answer that has `videos` appended: a Trailer beats a Teaser, an official one beats an
  /// unofficial one, English beats the rest (the same choice the TMDb Discover plugin makes). '' = none. Pure, so it can be tested.
  static String pickTrailer(dynamic info) {
    final videos = info is Map ? info['videos'] : null;
    final res = videos is Map ? videos['results'] : null;
    if (res is! List) return '';
    var best = '';
    var bestScore = -1;
    for (final e in res) {
      if (e is! Map) continue;
      final key = '${e['key'] ?? ''}';
      final type = '${e['type'] ?? ''}';
      if ('${e['site'] ?? ''}' != 'YouTube' || !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(key)) continue;
      if (type != 'Trailer' && type != 'Teaser') continue;
      final score = (type == 'Trailer' ? 4 : 2) + (e['official'] == true ? 2 : 0) + ('${e['iso_639_1'] ?? ''}' == 'en' ? 1 : 0);
      if (score > bestScore) {
        bestScore = score;
        best = key;
      }
    }
    return best;
  }

  /// "2021 \u00b7 Drama \u00b7 Thriller \u00b7 2h 3m" for the line under a title.
  String facts(SimpleTitle t) {
    final parts = <String>[
      if (t.year > 0) '${t.year}',
      ...genres.take(2),
      if (!t.tv && runtime > 0) '${runtime ~/ 60 > 0 ? '${runtime ~/ 60}h ' : ''}${runtime % 60}m',
      if (t.tv && seasons > 0) (seasons == 1 ? '1 season' : '$seasons seasons'),
    ];
    return parts.join(' \u00b7 ');
  }
}

String _sxe(Episode e) => 'S${e.season.toString().padLeft(2, '0')}E${e.episode.toString().padLeft(2, '0')}';

/// What the Play button of a show starts: the episode the person stopped partway (most recent), else the first episode after the
/// last one they finished, else the first episode. null = the show has no episodes.
({Episode ep, double start, bool resume})? showPlayTarget(Show s) {
  final eps = [for (final se in s.seasons) ...se.episodes]..sort((a, b) => a.season != b.season ? a.season.compareTo(b.season) : a.episode.compareTo(b.episode));
  if (eps.isEmpty) return null;
  Progress? best;
  Episode? bestEp;
  for (final e in eps) {
    final p = Store.progressFor(e.id);
    if (p != null && (best == null || p.updated > best.updated)) {
      best = p;
      bestEp = e;
    }
  }
  if (bestEp != null && best != null) return (ep: bestEp, start: best.position, resume: true);
  final last = eps.lastIndexWhere((e) => episodeWatched(s, e));
  for (var i = last + 1; i < eps.length; i++) {
    if (!episodeWatched(s, eps[i])) return (ep: eps[i], start: 0.0, resume: last >= 0);
  }
  return (ep: eps.first, start: 0.0, resume: false);
}

/// "Play", "Resume" or, for a show, "Play S01E01" / "Resume S01E03".
String simplePlayLabel(SimpleTitle t) {
  if (t.rec != null) return 'Watch';
  if (!t.tv) return Store.progressFor(t.movie!.id) != null ? 'Resume' : 'Play';
  final tg = showPlayTarget(t.show!);
  if (tg == null) return 'Play';
  return '${tg.resume ? 'Resume' : 'Play'} ${_sxe(tg.ep)}';
}

/// Starts the movie (from where it stopped) or the show's next episode. Completes when the player is closed.
Future<void> simplePlay(BuildContext context, SimpleTitle t) async {
  final r = t.rec;
  if (r != null) {
    // Not in the library: the TMDb Discover plugin's page for it (where the person finds a way to watch it).
    await openPluginScreen(context, pluginId: 'tmdb-discover', title: r.title, launch: {'type': r.tv ? 'tv' : 'movie', 'id': r.id, 'title': r.title, 'year': r.year});
    return;
  }
  if (!t.tv) {
    final m = t.movie!;
    final saved = Store.progressFor(m.id);
    await playMedia(context, movieItem(m), startSec: saved?.position ?? 0.0);
    return;
  }
  final tg = showPlayTarget(t.show!);
  if (tg == null) return;
  await playMedia(context, episodeItem(t.show!, tg.ep), startSec: tg.start);
}
