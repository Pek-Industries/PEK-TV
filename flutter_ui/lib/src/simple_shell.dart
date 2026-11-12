import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'api.dart';
import 'art_cache.dart';
import 'common.dart';
import 'detail.dart';
import 'library_pages.dart';
import 'music.dart' show MiniPlayer;
import 'news.dart';
import 'pages.dart';
import 'plugin_ui.dart' show PekTrailerView;
import 'ratings.dart';
import 'recs.dart';
import 'simple_data.dart';
import 'simple_detail.dart';
import 'store.dart';
import 'tokens.dart';
import 'tv_nav.dart';
import 'watched.dart';
import 'widgets.dart';

/// The Simple layout (Settings > Mode > Layout): a streaming-app home for people who just want to press Play.
///
///  * Phone / tablet: a header (PEK TV, Home, Updates, Settings), genre chips (Movies, Shows, New, Categories), a big banner, rows
///    of cards, and a bottom bar (Home, Search, My List, More).
///  * TV / wide screen: a top menu (Home, Shows, Movies, New, My List, Categories, Search, Updates, Settings) on a full-width banner
///    with the title, a short description and Play / More Info, and rows of cards under it. The banner follows the remote: rest on
///    a card for a moment and the banner becomes that title and its trailer starts (muted; Settings > Mode > Layout).
///
/// It runs inside [AppShell] (shell.dart), so sync, banners and the exit question keep working. Every other screen (Search,
/// Settings, Plugins, Watch History) is the Advanced layout's own page, opened on top; Back returns here.
class SimpleHome extends StatefulWidget {
  const SimpleHome({super.key});

  @override
  State<SimpleHome> createState() => _SimpleHomeState();
}

class _SimpleHomeState extends State<SimpleHome> with WidgetsBindingObserver {
  /// One banner pick per app run, so coming back to Home does not change it.
  static final int _seed = DateTime.now().millisecondsSinceEpoch;

  SimpleLib? _lib;
  bool _libError = false;
  SimpleTitle? _featured;
  List<String> _genres = const [];
  List<({String name, List<SimpleTitle> items})> _genreRows = const [];
  List<RecRow> _recRows = const []; // the For You rows (TMDb)
  bool _feedLoading = true;
  bool _ready = false;
  String _feedSig = '';
  int _feedGen = 0;
  String _choice = Store.simpleSource; // 'foryou' | 'library' | '' = by itself
  bool _covered = false; // another screen is on top
  bool _background = false; // the app is not in front
  bool _wideNow = false;
  SimpleProgress _pm = SimpleProgress.empty(); // how far along each title is, refreshed with every build of the rows
  int _gen = 0;
  Timer? _dwell;

  bool get _trailerOn => Store.simpleTrailers && !_covered && !_background;
  SimpleLib get _libOrEmpty => _lib ?? SimpleLib(const [], const []);

  /// Which home is showing: the For You rows (suggestions from TMDb) or this device's library. Until the person chooses with the
  /// switch it is the library when it has anything, else For You; '' while that is still unknown (the library is loading).
  String get _source {
    if (_choice == 'foryou' || _choice == 'library') return _choice;
    final lib = _lib;
    if (lib == null) return _libError ? 'foryou' : '';
    return lib.isEmpty ? 'foryou' : 'library';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Recs.changed.addListener(_recsChanged);
    _load();
    _loadFeed();
    _ready = true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Recs.changed.removeListener(_recsChanged);
    _dwell?.cancel();
    _gen++;
    _feedGen++;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bg = state != AppLifecycleState.resumed;
    if (bg != _background && mounted) setState(() => _background = bg);
  }

  void _recsChanged() {
    if (mounted) _loadFeed();
  }

  void _load() {
    final gen = ++_gen;
    _lib = null;
    _libError = false;
    _genres = const [];
    _genreRows = const [];
    unawaited(SimpleLib.load().then((lib) async {
      if (!mounted || gen != _gen) return;
      setState(() => _lib = lib);
      // Genres come from the .nfo files; a library without them simply has no genre rows and an empty Categories list.
      final facets = await Api.libraryFacets('');
      if (!mounted || gen != _gen) return;
      final names = [for (final g in facets?.genres ?? const <MapEntry<String, int>>[]) g.key];
      setState(() => _genres = names);
      for (final g in names.take(6)) {
        final r = await Api.librarySearch('', genre: g, limit: 30);
        if (!mounted || gen != _gen) return;
        if (r == null) continue;
        final items = lib.fromSearch(r);
        if (items.length < 3) continue;
        setState(() => _genreRows = [..._genreRows, (name: g, items: items)]);
      }
    }, onError: (Object _) {
      if (mounted && gen == _gen) setState(() => _libError = true);
    }));
  }

  /// Asks TMDb for the For You rows again when what they are built from changed (a like, a rating, a hidden title, a watch).
  void _loadFeed({bool force = false}) {
    final sig = '${RecFeed.signature(Recs.genres, Ratings.all().length, Recs.hidden.length, Recs.picks.length)}|${Store.favorites().length}|${Store.pluginFavorites().length}';
    if (!force && sig == _feedSig) return;
    _feedSig = sig;
    final gen = ++_feedGen;
    if (_ready) {
      setState(() => _feedLoading = true);
    } else {
      _feedLoading = true;
    }
    unawaited(RecFeed.simpleRows(seeds: simpleSeeds(), genres: Recs.genres, hidden: Recs.hidden).then((rows) {
      if (!mounted || gen != _feedGen) return;
      setState(() {
        _recRows = rows;
        _feedLoading = false;
        if (_source == 'foryou') _featured = null; // re-picked from the new rows
      });
    }, onError: (Object _) {
      if (mounted && gen == _feedGen) setState(() => _feedLoading = false);
    }));
  }

  SimpleTitle? _pickFeatured() {
    final lib = _libOrEmpty;
    if (_source == 'foryou') {
      final pool = [
        for (final r in _recRows)
          for (final i in r.items)
            if (i.backdrop.isNotEmpty) i,
      ];
      if (pool.isEmpty) return null;
      return lib.fromRec(pool[math.Random(_seed).nextInt(math.min(pool.length, 12))]);
    }
    final pool = lib.recentMixed.take(12).toList();
    if (pool.isEmpty) return null;
    return pool[math.Random(_seed).nextInt(pool.length)];
  }

  void _setSource(String s) {
    if (_source == s) return;
    unawaited(Store.setSimpleSource(s));
    setState(() {
      _choice = s;
      _featured = null;
    });
  }

  // ---------------------------------------------------------------- opening things

  /// Opens a screen on top; the banner's trailer is paused while it is open. What the rows are built from may have changed.
  Future<void> _push(Widget page) async {
    if (!mounted) return;
    setState(() => _covered = true);
    await Navigator.push<void>(context, MaterialPageRoute<void>(builder: (_) => page));
    if (!mounted) return;
    setState(() => _covered = false);
    _loadFeed();
  }

  Future<void> _cover(Future<void> Function() action) async {
    if (!mounted) return;
    setState(() => _covered = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _covered = false);
        _loadFeed();
      }
    }
  }

  void _openTitle(SimpleTitle t) => unawaited(_push(SimpleDetailScreen(title: t, lib: _lib)));
  void _playTitle(SimpleTitle t) => unawaited(_cover(() => simplePlay(context, t)));

  void _sub(String title, Widget Function(EdgeInsets pad) body) => unawaited(_push(SubScreen(title: title, body: Builder(builder: (c) => body(c.pek.pagePad)))));
  void _search() => _sub('Search', (pad) => SearchPage(padding: pad));
  void _settings() => _sub('Settings', (pad) => SettingsPage(padding: pad));
  void _updates() => _sub('Updates', (pad) => UpdatesPage(padding: pad, markSeen: true));
  void _history() => _sub('Watch History', (pad) => HistoryPage(padding: pad));
  void _plugins() => _sub('Plugins', (pad) => PluginsPage(padding: pad));

  void _grid(String title, Future<List<SimpleTitle>> Function() load, {bool live = false, String empty = 'Nothing here yet.'}) {
    unawaited(_push(SimpleGridPage(title: title, load: load, live: live, empty: empty)));
  }

  static const _offline = 'Could not load suggestions. Check your internet connection.';

  void _movies() {
    final lib = _libOrEmpty;
    if (_source == 'foryou') {
      _grid('Popular Movies', () async => [for (final i in await RecFeed.popularList(false)) lib.fromRec(i)], empty: _offline);
    } else {
      _grid('Movies', () async => [for (final m in lib.movies) SimpleTitle.movie(m)], empty: 'No movies yet. Add a folder in Settings.');
    }
  }

  void _shows() {
    final lib = _libOrEmpty;
    if (_source == 'foryou') {
      _grid('Popular Shows', () async => [for (final i in await RecFeed.popularList(true)) lib.fromRec(i)], empty: _offline);
    } else {
      _grid('TV Shows', () async => [for (final s in lib.shows) SimpleTitle.show(s)], empty: 'No shows yet. Add a folder in Settings.');
    }
  }

  void _new() {
    final lib = _libOrEmpty;
    if (_source == 'foryou') {
      _grid('Trending', () async => [for (final i in await RecFeed.trendingList()) lib.fromRec(i)], empty: _offline);
    } else {
      _grid('New', () async => lib.recentMixed, empty: 'Nothing new yet.');
    }
  }

  void _myList() {
    final lib = _libOrEmpty;
    _grid('My List', () async => lib.myList, live: true, empty: 'Your list is empty. Open a title and press My List to keep it here.');
  }

  Future<void> _categories() async {
    final lib = _libOrEmpty;
    final forYou = _source == 'foryou';
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final genres = forYou ? [for (final g in recGenres) g.name] : _genres;
    final pick = await showDialog<String>(
      context: context,
      barrierColor: t.overlay,
      builder: (c) => Dialog(
        backgroundColor: t.glassStrong,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radius), side: BorderSide(color: t.border)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 28 * rem, maxHeight: MediaQuery.sizeOf(c).height * 0.7),
          child: genres.isEmpty
              ? Padding(
                  padding: EdgeInsets.all(1.5 * rem),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Categories', style: TextStyle(fontSize: 1.25 * rem, fontWeight: FontWeight.w700)),
                    SizedBox(height: 0.75 * rem),
                    Text('No genres yet. Genres come from the .nfo files next to your movies and shows.', style: TextStyle(color: t.textMuted)),
                    SizedBox(height: 1.25 * rem),
                    PekButton(label: 'Close', autofocus: true, onTap: () => Navigator.pop(c)),
                  ]),
                )
              : ListView(shrinkWrap: true, padding: EdgeInsets.all(0.75 * rem), children: [
                  Padding(padding: EdgeInsets.fromLTRB(0.5 * rem, 0.5 * rem, 0.5 * rem, 0.75 * rem), child: Text('Categories', style: TextStyle(fontSize: 1.25 * rem, fontWeight: FontWeight.w700))),
                  for (var i = 0; i < genres.length; i++) ListRow(title: genres[i], autofocus: i == 0, onTap: () => Navigator.pop(c, genres[i])),
                ]),
        ),
      ),
    );
    if (pick == null || !mounted) return;
    if (forYou) {
      final g = recGenres.firstWhere((g) => g.name == pick);
      _grid(pick, () async => [for (final i in await RecFeed.genreList(g)) lib.fromRec(i)], empty: _offline);
    } else {
      _grid(pick, () async {
        final r = await Api.librarySearch('', genre: pick, limit: 500);
        return r == null ? <SimpleTitle>[] : lib.fromSearch(r);
      }, empty: 'Nothing in $pick yet.');
    }
  }

  Future<void> _moreSheet() async {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final pick = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: t.glassStrong,
      builder: (c) => SafeArea(
        child: Padding(
          padding: EdgeInsets.all(rem),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListRow(title: 'Watch History', leading: Icon(Icons.history, color: t.accent), onTap: () => Navigator.pop(c, 'history')),
            ListRow(title: 'Plugins', leading: Icon(Icons.extension_outlined, color: t.accent), onTap: () => Navigator.pop(c, 'plugins')),
            ListRow(title: 'Updates', leading: Icon(Icons.campaign_outlined, color: t.accent), onTap: () => Navigator.pop(c, 'updates')),
            ListRow(title: 'Settings', leading: Icon(Icons.settings_outlined, color: t.accent), onTap: () => Navigator.pop(c, 'settings')),
          ]),
        ),
      ),
    );
    if (!mounted) return;
    switch (pick) {
      case 'history':
        _history();
      case 'plugins':
        _plugins();
      case 'updates':
        _updates();
      case 'settings':
        _settings();
    }
  }

  /// A small menu of actions on a title (long press, or held OK on a remote). The first one has the focus.
  Future<void> _menu(String title, List<({IconData icon, String label, Future<void> Function() run})> items) async {
    final tk = context.pek.tokens;
    final i = await showDialog<int>(
      context: context,
      barrierColor: tk.overlay,
      builder: (c) => SimpleDialog(
        backgroundColor: tk.glassStrong,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        children: [for (var k = 0; k < items.length; k++) ListTile(autofocus: k == 0, onTap: () => Navigator.pop(c, k), leading: Icon(items[k].icon), title: Text(items[k].label))],
      ),
    );
    if (i == null || !mounted) return;
    await items[i].run();
    if (mounted) setState(() {});
  }

  /// A suggestion (not in the library): My List, or hide it from the suggestions.
  Future<void> _recMenu(SimpleTitle t) {
    final fav = t.favorite;
    return _menu(t.title, [
      (icon: Icons.play_arrow_rounded, label: simplePlayLabel(t), run: () async => _playTitle(t)),
      (icon: fav ? Icons.check : Icons.add, label: fav ? 'Remove from My List' : 'Add to My List', run: () => t.toggleFavorite()),
      (icon: Icons.visibility_off_outlined, label: 'Not interested', run: () => Recs.hide(t.rec!.key)), // Recs.changed loads the rows again without it
    ]);
  }

  /// A movie or show of the library: play it, open its page, My List, mark it watched.
  Future<void> _libMenu(SimpleTitle t) {
    final m = t.movie;
    final fav = t.favorite;
    final seen = m != null && movieWatched(m);
    return _menu(t.title, [
      (icon: Icons.play_arrow_rounded, label: simplePlayLabel(t), run: () async => _playTitle(t)),
      (icon: Icons.info_outline, label: 'Open page', run: () async => _openTitle(t)),
      (icon: fav ? Icons.check : Icons.add, label: fav ? 'Remove from My List' : 'Add to My List', run: () => t.toggleFavorite()),
      if (m != null) (icon: seen ? Icons.visibility_off_outlined : Icons.visibility_outlined, label: seen ? 'Mark as not watched' : 'Mark as watched', run: () => Watched.set([movieItem(m)], !seen)),
      if (t.show != null) (icon: Icons.list, label: 'Episodes', run: () async => unawaited(_push(ShowScreen(show: t.show!)))),
    ]);
  }

  /// A Continue Watching card (a movie or an episode, from the library or a plugin): continue, start over, its page, My List,
  /// mark it watched, or take it off the row.
  Future<void> _resumeMenu(Progress r) {
    final lib = _libOrEmpty;
    final show = r.kind == 'episode' ? lib.showByTitle(r.showTitle) : null;
    final movie = r.kind == 'episode' ? null : lib.movieById(r.id);
    final SimpleTitle? t = show != null ? SimpleTitle.show(show) : (movie != null ? SimpleTitle.movie(movie) : null);
    final fav = t?.favorite ?? false;
    return _menu(r.title, [
      (icon: Icons.play_arrow_rounded, label: 'Continue', run: () => _cover(() => playMedia(context, r, startSec: r.position))),
      (icon: Icons.replay, label: 'Start over', run: () => _cover(() => playMedia(context, r, startSec: 0.0))),
      if (t != null) (icon: Icons.info_outline, label: show != null ? 'Open show page' : 'Open page', run: () async => _openTitle(t)),
      if (t != null) (icon: fav ? Icons.check : Icons.add, label: fav ? 'Remove from My List' : 'Add to My List', run: () => t.toggleFavorite()),
      (icon: Icons.visibility_outlined, label: 'Mark as watched', run: () => Watched.set([r], true)),
      (icon: Icons.close, label: 'Remove from Continue Watching', run: () => Store.removeProgress(r.id)),
    ]);
  }

  // ---------------------------------------------------------------- banner follows the remote

  void _focused(SimpleTitle t) {
    if (!_wideNow) return;
    _dwell?.cancel();
    if (_featured?.key == t.key) return;
    _dwell = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _featured = t);
    });
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final size = MediaQuery.sizeOf(context);
    _wideNow = p.sidebar || size.width >= 900;
    _featured ??= _pickFeatured();
    return _wideNow ? _wide(context) : _phone(context);
  }

  Widget _note(BuildContext context, String title, String text, {List<Widget> buttons = const []}) {
    final p = context.pek;
    final rem = p.rem;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 2 * rem),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 1.3 * rem, fontWeight: FontWeight.w800)),
        SizedBox(height: 0.6 * rem),
        Text(text, textAlign: TextAlign.center, style: TextStyle(color: p.tokens.textMuted)),
        if (buttons.isNotEmpty) ...[SizedBox(height: rem), Wrap(alignment: WrapAlignment.center, spacing: 0.75 * rem, runSpacing: 0.5 * rem, children: buttons)],
      ]),
    );
  }

  /// The rows under the banner. Both homes start with Continue Watching and My List. Then: For You = the TMDb rows ("Because you
  /// liked ...", genres, trending / popular); My Library = Recently Added and a row per genre.
  List<Widget> _rows(BuildContext context, {required double cardW}) {
    final lib = _libOrEmpty;
    final src = _source;
    final p = context.pek;
    _pm = SimpleProgress.now();
    final resume = Store.resumeItems().take(12).toList();
    final mine = lib.myList.take(20).toList();
    final rows = <Widget>[
      if (src.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
      if (resume.isNotEmpty)
        SimpleShelf(
          title: 'Continue Watching',
          memoryKey: 'simple/continue',
          cardW: cardW,
          widthFactors: [for (final r in resume) resumeShowsStill(r) ? 1.7 : 1.0],
          cards: [
            for (final r in resume)
              PosterCard(
                onLongPress: () => unawaited(_resumeMenu(r)),
                holdSelect: true,
                title: r.title,
                subtitle: r.duration > 0 ? '${(100 * r.position / r.duration).round()}% watched' : formatTime(r.position),
                poster: resumeArtFor(r),
                aspectRatio: resumeShowsStill(r) ? 16 / 9 : 2 / 3,
                fallbackImage: r.image,
                inLibrary: r.kind == 'episode' ? lib.showByTitle(r.showTitle) != null : lib.movieById(r.id) != null,
                progress: r.duration > 0 ? r.position / r.duration : null,
                onTap: () => unawaited(_cover(() => playResumeOrStart(context, r))),
              ),
          ],
        ),
      if (mine.isNotEmpty) SimpleShelf(title: 'My List', memoryKey: 'simple/mylist', cardW: cardW, cards: [for (final t in mine) _card(t)]),
    ];
    if (src == 'foryou') {
      for (final r in _recRows) {
        rows.add(SimpleShelf(title: r.title, memoryKey: 'simple/rec/${r.title}', cardW: cardW, cards: [for (final i in r.items) _card(lib.fromRec(i))]));
      }
      if (_recRows.isEmpty) {
        rows.add(_feedLoading
            ? _note(context, 'Finding movies and shows for you', 'This takes a moment.')
            : _note(context, 'No suggestions yet', 'Check your internet connection and try again.', buttons: [PekButton(label: 'Try again', primary: true, shrink: true, onTap: () => _loadFeed(force: true))]));
      }
    } else if (src == 'library') {
      if (_libError) {
        rows.add(_note(context, 'Could not load your library', 'Check that PEK TV is running, then try again.', buttons: [PekButton(label: 'Try again', primary: true, shrink: true, onTap: () => setState(_load))]));
      } else if (lib.isEmpty) {
        rows.add(_note(context, 'Your library is empty', 'Add a folder with your movies and shows in Settings, or look at suggestions for you.', buttons: [
          PekButton(label: 'Open Settings', primary: true, shrink: true, onTap: _settings),
          PekButton(label: 'See For You', shrink: true, onTap: () => _setSource('foryou')),
        ]));
      } else {
        if (lib.movies.isNotEmpty) rows.add(SimpleShelf(title: 'Recently Added Movies', memoryKey: 'simple/movies', cardW: cardW, cards: [for (final t in lib.recentMovies) _card(t)]));
        if (lib.shows.isNotEmpty) rows.add(SimpleShelf(title: 'Recently Added Shows', memoryKey: 'simple/shows', cardW: cardW, cards: [for (final t in lib.recentShows) _card(t)]));
        for (final g in _genreRows) {
          rows.add(SimpleShelf(title: g.name, memoryKey: 'simple/genre/${g.name}', cardW: cardW, cards: [for (final t in g.items) _card(t)]));
        }
      }
    }
    rows.add(SizedBox(height: 2 * p.rem));
    return rows;
  }

  /// One title's card. Resting on it (remote) lets the banner follow; a suggestion also has a long-press menu.
  Widget _card(SimpleTitle t) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (f) {
          if (f) _focused(t);
        },
        child: PosterCard(
          title: t.title,
          subtitle: t.subtitle,
          poster: t.details,
          onTap: () => _openTitle(t),
          onLongPress: () => unawaited(t.inLibrary ? _libMenu(t) : _recMenu(t)),
          holdSelect: true,
          inLibrary: t.inLibrary,
          progress: _pm.of(t),
        ),
      );

  Widget _hero(BuildContext context, {required bool wide, required double height, required double sidePad}) {
    final t = _featured;
    if (t == null) return SizedBox(height: height);
    return _Hero(
      key: ValueKey('hero-${t.key}'),
      title: t,
      height: height,
      wide: wide,
      sidePad: sidePad,
      trailerOn: _trailerOn,
      onPlay: () => _playTitle(t),
      onInfo: () => _openTitle(t),
    );
  }

  // ---------------------------------------------------------------- phone / tablet

  Widget _phone(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final size = MediaQuery.sizeOf(context);
    final heroH = math.min(size.height * 0.5, size.width * 1.15);
    final hasHero = _featured != null;
    Widget chip(String label, VoidCallback onTap, {bool arrow = false}) => Padding(
          padding: EdgeInsets.only(right: 0.5 * rem),
          child: PekFocusable(
            radius: 40,
            background: t.surface,
            borderColor: t.border,
            padding: EdgeInsets.symmetric(horizontal: 1 * rem, vertical: 0.45 * rem),
            onTap: onTap,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: TextStyle(fontSize: 0.9 * rem, fontWeight: FontWeight.w600)),
              if (arrow) Icon(Icons.arrow_drop_down, size: 1.2 * rem),
            ]),
          ),
        );
    return SafeArea(
      bottom: false,
      child: Column(children: [
        Padding(
          padding: EdgeInsets.fromLTRB(rem, 0.25 * rem, 0.5 * rem, 0),
          child: Row(children: [
            Text('PEK', style: TextStyle(color: t.accent, fontSize: 1.5 * rem, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
            SizedBox(width: 0.6 * rem),
            Text('Home', style: TextStyle(fontSize: 1.5 * rem, fontWeight: FontWeight.w800)),
            const Spacer(),
            _UpdatesButton(onTap: _updates, rem: rem),
            _IconButton(icon: Icons.settings_outlined, label: 'Settings', onTap: _settings, rem: rem),
          ]),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(rem, 0.35 * rem, rem, 0.15 * rem),
          child: _SourceSwitch(value: _source, onChanged: _setSource, rem: rem),
        ),
        SizedBox(
          height: 3 * rem,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: rem, vertical: 0.35 * rem),
            children: [chip('Movies', _movies), chip('Shows', _shows), chip('New', _new), chip('Categories', _categories, arrow: true)],
          ),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            cacheExtent: 900,
            children: [
              if (hasHero) _hero(context, wide: false, height: heroH, sidePad: rem),
              SizedBox(height: 0.75 * rem),
              Padding(padding: EdgeInsets.symmetric(horizontal: rem), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: _rows(context, cardW: 7 * rem))),
            ],
          ),
        ),
        const MiniPlayer(),
        _bottomBar(context),
      ]),
    );
  }

  Widget _bottomBar(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final inset = MediaQuery.paddingOf(context).bottom;
    Widget item(IconData icon, String label, VoidCallback? onTap, {bool on = false}) => Expanded(
          child: PekFocusable(
            onTap: onTap,
            padding: EdgeInsets.symmetric(vertical: 0.5 * p.rem),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 1.5 * p.rem, color: on ? t.text : t.textMuted),
              SizedBox(height: 0.15 * p.rem),
              Text(label, style: TextStyle(fontSize: 0.7 * p.rem, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: on ? t.text : t.textMuted)),
            ]),
          ),
        );
    return Container(
      padding: EdgeInsets.only(bottom: inset),
      decoration: BoxDecoration(color: t.bgElevated, border: Border(top: BorderSide(color: t.border))),
      child: Row(children: [
        item(Icons.home_filled, 'Home', null, on: true),
        item(Icons.search, 'Search', _search),
        item(Icons.add_circle_outline, 'My List', _myList),
        item(Icons.more_horiz, 'More', () => unawaited(_moreSheet())),
      ]),
    );
  }

  // ---------------------------------------------------------------- TV / wide screen

  Widget _wide(BuildContext context) {
    final p = context.pek;
    final rem = p.rem;
    final size = MediaQuery.sizeOf(context);
    final hasHero = _featured != null;
    // No banner (the rows are still loading, or there is nothing to show): just the menu bar, the rows take the rest.
    final heroH = hasHero ? size.height * 0.56 : p.safeY + 5.5 * rem;
    final side = 2 * rem + p.safeX;
    return Column(children: [
      SizedBox(
        height: heroH,
        child: Stack(children: [
          if (hasHero) Positioned.fill(child: _hero(context, wide: true, height: heroH, sidePad: side)),
          Positioned(top: 0, left: 0, right: 0, child: _tvNav(context, side, light: hasHero)),
        ]),
      ),
      Expanded(
        child: ListView(
          padding: EdgeInsets.fromLTRB(side, 0.5 * rem, side, p.safeY),
          cacheExtent: 900,
          children: _rows(context, cardW: 6 * rem),
        ),
      ),
      const MiniPlayer(),
    ]);
  }

  /// The top menu. Light text (white, shadowed) on the banner picture; the page's own colors when there is no banner.
  Widget _tvNav(BuildContext context, double side, {required bool light}) {
    final p = context.pek;
    final rem = p.rem;
    final fg = light ? Colors.white : p.tokens.text;
    final shadows = light ? const [Shadow(blurRadius: 6, color: Colors.black87)] : const <Shadow>[];
    Widget item(String label, VoidCallback? onTap, {bool on = false, bool arrow = false}) => PekFocusable(
          radius: 8,
          padding: EdgeInsets.symmetric(horizontal: 0.8 * rem, vertical: 0.4 * rem),
          onTap: onTap,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: TextStyle(color: fg, fontSize: 0.95 * rem, fontWeight: on ? FontWeight.w800 : FontWeight.w500, shadows: shadows, decoration: on ? TextDecoration.underline : null, decorationColor: p.tokens.accent, decorationThickness: 2)),
            if (arrow) Icon(Icons.arrow_drop_down, color: fg, size: 1.3 * rem),
          ]),
        );
    final src = _source;
    return TvNav.region(
      memoryKey: 'simple/nav',
      child: Padding(
        padding: EdgeInsets.fromLTRB(side, p.safeY + 0.8 * rem, side, 0),
        child: Row(children: [
          Text('PEK TV', style: TextStyle(color: p.tokens.accent, fontSize: 1.5 * rem, fontWeight: FontWeight.w900, letterSpacing: -0.5, shadows: shadows)),
          SizedBox(width: 1.5 * rem),
          item('For You', () => _setSource('foryou'), on: src == 'foryou'),
          item('My Library', () => _setSource('library'), on: src == 'library'),
          SizedBox(width: 0.5 * rem),
          item('Shows', _shows),
          item('Movies', _movies),
          item('New', _new),
          item('My List', _myList),
          item('Categories', _categories, arrow: true),
          const Spacer(),
          _IconButton(icon: Icons.search, label: 'Search', onTap: _search, rem: rem, light: light),
          _UpdatesButton(onTap: _updates, rem: rem, light: light),
          _IconButton(icon: Icons.settings_outlined, label: 'Settings', onTap: _settings, rem: rem, light: light),
        ]),
      ),
    );
  }
}

/// The two-way switch under the phone header: For You (suggestions) / My Library (this device's own movies and shows).
class _SourceSwitch extends StatelessWidget {
  const _SourceSwitch({required this.value, required this.onChanged, required this.rem});
  final String value;
  final ValueChanged<String> onChanged;
  final double rem;

  @override
  Widget build(BuildContext context) {
    final t = context.pek.tokens;
    Widget seg(String id, String label, IconData icon) {
      final on = value == id;
      return Expanded(
        child: PekFocusable(
          radius: 40,
          background: on ? t.accent : Colors.transparent,
          focusBackground: on ? t.accent : t.surfaceFocused,
          padding: EdgeInsets.symmetric(vertical: 0.5 * rem),
          onTap: () => onChanged(id),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 1.1 * rem, color: on ? Colors.white : t.textMuted),
            SizedBox(width: 0.4 * rem),
            Text(label, style: TextStyle(fontSize: 0.9 * rem, fontWeight: FontWeight.w700, color: on ? Colors.white : t.textMuted)),
          ]),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(40), border: Border.all(color: t.border)),
      child: Row(children: [seg('foryou', 'For You', Icons.auto_awesome), seg('library', 'My Library', Icons.video_library_outlined)]),
    );
  }
}

// -------------------------------------------------------------------- pieces

class _IconButton extends StatelessWidget {
  const _IconButton({required this.icon, required this.label, required this.onTap, required this.rem, this.light = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double rem;
  final bool light;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: PekFocusable(
        radius: 40,
        padding: EdgeInsets.all(0.55 * rem),
        onTap: onTap,
        child: Icon(icon, size: 1.5 * rem, color: light ? Colors.white : context.pek.tokens.text),
      ),
    );
  }
}

/// The bell: opens Updates, with a dot while there is something new.
class _UpdatesButton extends StatelessWidget {
  const _UpdatesButton({required this.onTap, required this.rem, this.light = false});
  final VoidCallback onTap;
  final double rem;
  final bool light;

  @override
  Widget build(BuildContext context) {
    final t = context.pek.tokens;
    return ValueListenableBuilder<int>(
      valueListenable: News.unread,
      builder: (context, n, _) => Stack(clipBehavior: Clip.none, children: [
        _IconButton(icon: Icons.notifications_none, label: 'Updates', onTap: onTap, rem: rem, light: light),
        if (n > 0) Positioned(right: 0.45 * rem, top: 0.45 * rem, child: IgnorePointer(child: Container(width: 0.6 * rem, height: 0.6 * rem, decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle)))),
      ]),
    );
  }
}

/// A titled line of cards. [widthFactors] widens single cards (Continue Watching shows an episode's own wide picture).
class SimpleShelf extends StatelessWidget {
  const SimpleShelf({super.key, required this.title, required this.memoryKey, required this.cardW, required this.cards, this.widthFactors});
  final String title;
  final String memoryKey;
  final double cardW;
  final List<Widget> cards;
  final List<double>? widthFactors;

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final rem = p.rem;
    // Room under the poster for the title / subtitle line, growing with the phone's text size (same as the Advanced dashboard).
    final textRoom = (0.4 + 2.7 * MediaQuery.textScalerOf(context).scale(1.0)) * rem;
    return Padding(
      padding: EdgeInsets.only(bottom: 1.25 * rem),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: 1.2 * rem, fontWeight: FontWeight.w700)),
        SizedBox(height: 0.6 * rem),
        TvNav.region(
          memoryKey: memoryKey,
          rowEndStops: true,
          child: SizedBox(
            height: cardW * 1.5 + textRoom,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              cacheExtent: 1200,
              itemCount: cards.length,
              separatorBuilder: (_, __) => SizedBox(width: 0.6 * rem),
              itemBuilder: (_, i) => SizedBox(width: cardW * (widthFactors != null && i < widthFactors!.length ? widthFactors![i] : 1.0), child: Align(alignment: Alignment.topCenter, child: cards[i])),
            ),
          ),
        ),
      ]),
    );
  }
}

/// The big banner: the title's wide picture (its poster when TMDb has none), the trailer fading in over it a moment later, and the
/// title, a line of facts, a short description and Play / More Info at the bottom left, like a streaming app.
class _Hero extends StatefulWidget {
  const _Hero({super.key, required this.title, required this.height, required this.wide, required this.sidePad, required this.trailerOn, required this.onPlay, required this.onInfo});
  final SimpleTitle title;
  final double height;
  final bool wide;
  final double sidePad;
  final bool trailerOn;
  final VoidCallback onPlay;
  final VoidCallback onInfo;

  @override
  State<_Hero> createState() => _HeroState();
}

class _HeroState extends State<_Hero> {
  late final Future<SimpleMeta> _meta = SimpleMeta.of(widget.title);

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final wide = widget.wide;
    final title = widget.title;
    return SizedBox(
      height: widget.height,
      child: FutureBuilder<SimpleMeta>(
        future: _meta,
        builder: (context, snap) {
          final m = snap.data ?? SimpleMeta.none;
          final facts = m.ok ? m.facts(title) : title.subtitle;
          Widget picture() {
            Widget poster() => FutureBuilder<Details>(
                  future: title.details,
                  builder: (_, s) {
                    final url = s.data?.poster ?? '';
                    return ColoredBox(
                      color: t.surface,
                      child: url.isEmpty
                          ? const SizedBox.expand()
                          : Align(alignment: Alignment.centerRight, child: SizedBox(height: widget.height, child: AspectRatio(aspectRatio: 2 / 3, child: ArtImage(url, fit: BoxFit.cover, cacheWidth: 640)))),
                    );
                  },
                );
            if (m.backdrop.isEmpty) return poster();
            return ArtImage(m.backdrop, fit: BoxFit.cover, cacheWidth: wide ? 1280 : 780, errorBuilder: (_, __, ___) => poster());
          }

          return Stack(fit: StackFit.expand, children: [
            Positioned.fill(child: picture()),
            if (widget.trailerOn && m.trailer.isNotEmpty) Positioned.fill(child: _DelayedTrailer(key: ValueKey('trailer-${m.trailer}'), videoId: m.trailer, muted: !Store.simpleSound)),
            // Dark on the left (wide) or at the bottom (phone) so the text reads on any picture; fades into the page at the bottom edge.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: wide ? Alignment.centerLeft : Alignment.bottomCenter,
                      end: wide ? Alignment.centerRight : Alignment.topCenter,
                      colors: [Colors.black.withAlpha(wide ? 215 : 235), Colors.black.withAlpha(0)],
                      stops: [0.0, wide ? 0.7 : 0.75],
                    ),
                  ),
                ),
              ),
            ),
            if (wide)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: widget.height * 0.3,
                child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black.withAlpha(150), Colors.black.withAlpha(0)])))),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: widget.height * 0.14,
              child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [t.bg.withAlpha(0), t.bg])))),
            ),
            Positioned(
              left: widget.sidePad,
              bottom: wide ? 1.6 * rem : 1.1 * rem,
              width: wide ? MediaQuery.sizeOf(context).width * 0.45 : MediaQuery.sizeOf(context).width - 2 * widget.sidePad,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(title.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontSize: (wide ? 2.6 : 1.9) * rem, fontWeight: FontWeight.w900, height: 1.05, shadows: const [Shadow(blurRadius: 12, color: Colors.black87)])),
                SizedBox(height: 0.5 * rem),
                Row(children: [
                  if (m.vote > 0) ...[
                    Icon(Icons.star_rounded, color: const Color(0xFFFFC83D), size: 1.1 * rem),
                    SizedBox(width: 0.2 * rem),
                    Text(m.vote.toStringAsFixed(1), style: TextStyle(color: Colors.white, fontSize: 0.9 * rem, fontWeight: FontWeight.w700)),
                    SizedBox(width: 0.6 * rem),
                  ],
                  Flexible(child: Text(facts, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withAlpha(215), fontSize: 0.9 * rem))),
                ]),
                _overview(m, rem, wide),
                SizedBox(height: 0.9 * rem),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  _HeroButton(icon: Icons.play_arrow_rounded, label: simplePlayLabel(title), primary: true, autofocus: p.sidebar, onTap: widget.onPlay, rem: rem),
                  SizedBox(width: 0.75 * rem),
                  _HeroButton(icon: Icons.info_outline, label: 'More Info', primary: false, onTap: widget.onInfo, rem: rem),
                ]),
              ]),
            ),
          ]);
        },
      ),
    );
  }

  /// The description: TMDb's when it has one, else the library's own (an .nfo plot).
  Widget _overview(SimpleMeta m, double rem, bool wide) {
    Widget text(String s) => Padding(
          padding: EdgeInsets.only(top: 0.5 * rem),
          child: Text(s, maxLines: wide ? 3 : 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withAlpha(230), fontSize: 0.9 * rem, height: 1.35, shadows: const [Shadow(blurRadius: 8, color: Colors.black87)])),
        );
    if (m.overview.isNotEmpty) return text(m.overview);
    return FutureBuilder<Details>(
      future: widget.title.details,
      builder: (_, s) => (s.data?.overview ?? '').isEmpty ? const SizedBox.shrink() : text(s.data!.overview),
    );
  }
}

/// Starts the trailer a moment after the banner shows (a streaming app does not start it the instant the page opens).
class _DelayedTrailer extends StatefulWidget {
  const _DelayedTrailer({super.key, required this.videoId, required this.muted});
  final String videoId;
  final bool muted;

  @override
  State<_DelayedTrailer> createState() => _DelayedTrailerState();
}

class _DelayedTrailerState extends State<_DelayedTrailer> {
  bool _go = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _go = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _go ? PekTrailerView(videoId: widget.videoId, muted: widget.muted) : const SizedBox.shrink();
}

/// Play (white) and More Info (grey glass), the pair under the banner's title.
class _HeroButton extends StatelessWidget {
  const _HeroButton({required this.icon, required this.label, required this.primary, required this.onTap, required this.rem, this.autofocus = false});
  final IconData icon;
  final String label;
  final bool primary;
  final bool autofocus;
  final VoidCallback onTap;
  final double rem;

  @override
  Widget build(BuildContext context) {
    final fg = primary ? Colors.black : Colors.white;
    return PekFocusable(
      autofocus: autofocus,
      onTap: onTap,
      radius: 6,
      background: primary ? Colors.white : Colors.white.withAlpha(70),
      focusBackground: primary ? const Color(0xFFE6E6E6) : Colors.white.withAlpha(120),
      padding: EdgeInsets.symmetric(horizontal: 1.1 * rem, vertical: 0.55 * rem),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: fg, size: 1.4 * rem),
        SizedBox(width: 0.35 * rem),
        Text(label, style: TextStyle(color: fg, fontSize: 0.95 * rem, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

// -------------------------------------------------------------------- a grid of cards

/// Movies, TV Shows, New, My List and a genre: every card of the list in a grid, like a streaming app's "browse" page.
/// [live]: the list is asked again when a favorite changes (My List).
class SimpleGridPage extends StatefulWidget {
  const SimpleGridPage({super.key, required this.title, required this.load, this.live = false, this.empty = 'Nothing here yet.'});
  final String title;
  final Future<List<SimpleTitle>> Function() load;
  final bool live;
  final String empty;

  @override
  State<SimpleGridPage> createState() => _SimpleGridPageState();
}

class _SimpleGridPageState extends State<SimpleGridPage> {
  late Future<List<SimpleTitle>> _items = widget.load();

  @override
  void initState() {
    super.initState();
    if (widget.live) Store.changed.addListener(_again);
  }

  @override
  void dispose() {
    if (widget.live) Store.changed.removeListener(_again);
    super.dispose();
  }

  void _again() {
    if (mounted) setState(() => _items = widget.load());
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    return SubScreen(
      title: widget.title,
      body: FutureBuilder<List<SimpleTitle>>(
        future: _items,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          final items = snap.data ?? const <SimpleTitle>[];
          if (items.isEmpty) return Center(child: Padding(padding: EdgeInsets.all(2 * rem), child: Text(snap.hasError ? 'Could not load this list.' : widget.empty, textAlign: TextAlign.center, style: TextStyle(color: t.textMuted))));
          final w = p.sidebar ? 6 * rem : 7.5 * rem;
          final pm = SimpleProgress.now();
          return TvNav.region(
            memoryKey: 'simple/grid/${widget.title}',
            child: GridView.builder(
              padding: EdgeInsets.fromLTRB(rem + p.safeX, 0.5 * rem, rem + p.safeX, 2 * rem + p.safeY),
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: w, mainAxisSpacing: 0.9 * rem, crossAxisSpacing: 0.7 * rem, childAspectRatio: 2 / 3.35),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final it = items[i];
                // Align loosens the grid cell, so the card keeps its own 2:3 shape (the rows do the same).
                return Align(
                  alignment: Alignment.topCenter,
                  child: PosterCard(
                    autofocus: i == 0 && p.isTv,
                    title: it.title,
                    subtitle: it.subtitle,
                    poster: it.details,
                    inLibrary: it.inLibrary,
                    progress: pm.of(it),
                    onTap: () => Navigator.push<void>(context, MaterialPageRoute<void>(builder: (_) => SimpleDetailScreen(title: it, lib: null))),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
