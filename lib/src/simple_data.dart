import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'detail.dart';
import 'recs.dart';
import 'store.dart';

/// Data behind the Simple layout (simple_shell.dart, simple_detail.dart): one type for "a movie or a show of the library", the
/// library lookups, what TMDb says about a title (trailer, wide picture, genres, recommendations) and the Play button's logic.

/// One movie or one show of the library.
class SimpleTitle {
  const SimpleTitle.movie(this.movie) : show = null;
  const SimpleTitle.show(this.show) : movie = null;
  final Movie? movie;
  final Show? show;

  bool get tv => show != null;
  String get title => tv ? show!.title : movie!.title;
  int get year => tv ? 0 : movie!.year;

  /// Same keys as the favorites use (`m:<file id>`, `s:<show title>`).
  String get key => tv ? 's:${show!.title}' : 'm:${movie!.id}';
  Future<Details> get details => tv ? Api.showDetails(show!.title) : Api.movieDetails(movie!.id);
  String get subtitle => tv ? '${show!.episodeCount} episodes' : (movie!.year > 0 ? '${movie!.year}' : '');

  bool get favorite => Store.isFavorite(key);
  Future<void> toggleFavorite() => Store.toggleFavorite(tv ? Favorite.show(show!.title) : Favorite.movie(movie!.id, movie!.title, movie!.year));
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

  /// This profile's favorites that are in the library, newest first ("My List").
  List<SimpleTitle> get myList {
    final out = <SimpleTitle>[];
    for (final f in Store.favorites()) {
      if (f.kind == 'movie') {
        final m = _movieById[f.ref];
        if (m != null) out.add(SimpleTitle.movie(m));
      } else {
        final s = _showByTitle[f.ref];
        if (s != null) out.add(SimpleTitle.show(s));
      }
    }
    return out;
  }
}

/// What TMDb says about a library title, asked once through the app's TMDb proxy (the same one the recommendations use).
class SimpleMeta {
  const SimpleMeta({this.ok = false, this.trailer = '', this.backdrop = '', this.overview = '', this.genres = const [], this.vote = 0, this.runtime = 0, this.seasons = 0, this.related = const []});

  /// false = TMDb had no answer (offline, or no match): the banner just shows the library's own poster.
  final bool ok;

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
      final id = t.tv ? await RecFeed.tvIdByName(t.title) : await RecFeed.movieIdByName(t.title, year: t.year);
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
  if (!t.tv) return Store.progressFor(t.movie!.id) != null ? 'Resume' : 'Play';
  final tg = showPlayTarget(t.show!);
  if (tg == null) return 'Play';
  return '${tg.resume ? 'Resume' : 'Play'} ${_sxe(tg.ep)}';
}

/// Starts the movie (from where it stopped) or the show's next episode. Completes when the player is closed.
Future<void> simplePlay(BuildContext context, SimpleTitle t) async {
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
