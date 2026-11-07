import 'dart:async';

import 'package:flutter/material.dart';

import 'activity.dart';
import 'api.dart';
import 'detail.dart';
import 'common.dart';
import 'pages.dart';
import 'store.dart';
import 'tokens.dart';
import 'library_sort.dart';
import 'watch_filter.dart';
import 'weather.dart' show WeatherBadge;
import 'widgets.dart';

/// The Movies / TV Shows tabs: `_renderHeader(title, showRefresh)` + `_renderLibrary(tab)` in app_library.js.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.tab, required this.title, required this.padding});
  final String tab; // 'movies' | 'shows'
  final String title;
  final EdgeInsets padding;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late Future<List<Object>> _data = _load();
  bool _refreshing = false;
  bool _scanning = false; // any scan on the server: startup, Refresh, or a source that was just added
  int _cooldown = 0;
  Timer? _timer;
  Timer? _watch;
  bool _polling = false;
  int _changeTicket = 0; // a newer _followChange() replaces an older one
  int _emptyRetries = 0; // how many times an empty list has been read again by itself

  /// The chosen watched state, sort, genre and actor are kept while the app runs, so leaving the tab and coming back does not reset them.
  static final Map<String, LibraryFilters> _remembered = {};
  late final LibraryFilters _f = _remembered.putIfAbsent(widget.tab, () => LibraryFilters(only: widget.tab, sorts: widget.tab == 'movies' ? LibrarySort.movies : LibrarySort.shows));

  @override
  void initState() {
    super.initState();
    _watch = Timer.periodic(const Duration(seconds: 3), (_) => _checkScan());
    _checkScan();
    Api.libraryRevision.addListener(_onSourcesChanged);
    Api.artRevision.addListener(_onArtChanged);
    unawaited(_f.loadFacets());
  }

  /// The server says some titles got a new poster / synopsis: read the lists again. Unchanged posters come from their saved
  /// copies; a changed one has a new address and is downloaded. A burst of changes is read once.
  Timer? _artTimer;
  void _onArtChanged() {
    _artTimer?.cancel();
    _artTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || _refreshing || _scanning) return;
      Api.forgetLibrary();
      setState(() => _data = _load());
    });
  }

  /// A source was added or removed (Settings > Media sources).
  void _onSourcesChanged() {
    _emptyRetries = 0;
    unawaited(_followChange());
  }

  /// Waits for the scan the server starts after a source change and then reads the library again. The scan status alone cannot
  /// be relied on for this: a small folder is scanned in about a second, which fits between two 3 s polls, so the page never
  /// saw "scanning" and never reloaded (the library showed up only after Refresh). Here the wait is by time as well: if no scan
  /// is seen running by the third check (about 2 s) the list is read anyway.
  Future<void> _followChange() async {
    final ticket = ++_changeTicket;
    var sawScan = false;
    for (var i = 0; i < 45; i++) {
      await Future<void>.delayed(Duration(milliseconds: i < 4 ? 700 : 1500));
      if (!mounted || ticket != _changeTicket || _refreshing) return;
      final busy = await Api.scanning();
      if (!mounted || ticket != _changeTicket || _refreshing) return;
      if (busy) {
        sawScan = true;
        continue;
      }
      if (sawScan || i >= 2) {
        Api.forgetLibrary();
        setState(() => _data = _load());
        return;
      }
    }
  }

  /// Asks the server whether it is scanning; when a scan has just finished the library is read again.
  Future<void> _checkScan() async {
    if (_polling) return;
    _polling = true;
    final now = await Api.scanning();
    _polling = false;
    if (!mounted) return;
    final was = _scanning;
    if (now != was) {
      setState(() => _scanning = now);
      if (now) {
        Activity.begin('scan', 'Scanning your media folders\u2026');
      } else {
        Activity.end('scan', 'Scan finished');
      }
      if (was && !now && !_refreshing) {
        Api.forgetLibrary();
        setState(() => _data = _load());
      }
    }
  }

  /// One read of the list. A failure is tried once more after a moment: the server can be busy right after it starts or
  /// while a scan is saving, and a second try usually gets through.
  Future<List<Object>> _load() => Activity.track<List<Object>>('lib:${widget.tab}', 'Loading your library\u2026', () async {
        Future<List<Object>> once() async => widget.tab == 'movies' ? await Api.movies() : await Api.shows();
        List<Object> list;
        try {
          list = await once();
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          list = await once();
        }
        // An empty list right after a source was added (the page was opened while the first scan was still running) is read
        // again by itself a few times, so the titles appear without tapping Refresh.
        if (list.isEmpty && mounted && !_refreshing && _emptyRetries < 3) {
          _emptyRetries++;
          unawaited(_followChange());
        }
        return list;
      });

  @override
  void dispose() {
    if (_scanning) Activity.end('scan');
    _timer?.cancel();
    _watch?.cancel();
    Api.libraryRevision.removeListener(_onSourcesChanged);
    Api.artRevision.removeListener(_onArtChanged);
    _artTimer?.cancel();
    super.dispose();
  }

  void _startCooldown(int seconds) {
    _timer?.cancel();
    setState(() => _cooldown = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _cooldown = _cooldown - 1);
      if (_cooldown <= 0) t.cancel();
    });
  }

  /// rescan() in app_sources.js: POST /api/rescan, poll /api/scan-status for up to a minute, then reload the library.
  Future<void> _rescan() async {
    if (_refreshing || _cooldown > 0) return;
    _emptyRetries = 0;
    _startCooldown(10);
    setState(() => _refreshing = true);
    Activity.begin('scan', 'Scanning your media folders\u2026');
    try {
      final wait = await Api.rescan();
      if (wait != null) {
        _startCooldown(wait);
      } else {
        for (var i = 0; i < 60; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          if (!await Api.scanning()) break;
        }
      }
    } catch (_) {}
    Activity.end('scan', 'Scan finished');
    // Refresh no longer wipes the saved posters. The server compares each title's files with what it stored and looks up only the
    // changed ones again (offline: it keeps the old poster and tries again later); the page hears about them through Api.artRevision.
    if (!mounted) return;
    Api.forgetLibrary();
    setState(() {
      _refreshing = false;
      _data = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;

    final blocked = _refreshing || _cooldown > 0;
    final label = _refreshing ? 'Scanning\u2026' : (_cooldown > 0 ? 'Refresh ($_cooldown' 's)' : 'Refresh');
    final refresh = PekButton(
      compact: true,
      label: label,
      onTap: blocked ? null : _rescan,
      leading: Spin(spinning: _refreshing, child: Text('\u21bb', style: TextStyle(fontSize: 1.1 * rem, height: 1, color: t.accent))),
    );

    final header = Padding(
      padding: EdgeInsets.only(bottom: (p.isTv ? 2 : 1.5) * rem),
      child: Row(
        children: [
          Expanded(child: Text(widget.title, style: TextStyle(fontSize: 2 * rem, fontWeight: FontWeight.w700))),
          SizedBox(width: rem),
          refresh,
          SizedBox(width: 0.75 * rem),
          const WeatherBadge(),
        ],
      ),
    );

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: widget.padding.copyWith(bottom: 0),
          sliver: SliverToBoxAdapter(child: header),
        ),
        if (_scanning || _refreshing)
          SliverPadding(
            padding: EdgeInsets.only(left: widget.padding.left, right: widget.padding.right),
            sliver: const SliverToBoxAdapter(child: ScanLine(label: 'Scanning your library\u2026')),
          ),
        FutureBuilder<List<Object>>(
          future: _data,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return SliverPadding(
                padding: widget.padding.copyWith(top: 0),
                sliver: SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(2 * rem), child: Text('Loading your library\u2026', style: TextStyle(color: t.textMuted)))),
              );
            }
            if (snap.hasError) {
              // The real reason is shown (it used to say "did not respond" for every kind of failure), with a way to retry.
              var why = '${snap.error}'.replaceFirst('Exception: ', '');
              if (why.length > 160) why = '${why.substring(0, 160)}\u2026';
              return SliverPadding(
                padding: widget.padding.copyWith(top: 0),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      PekCard(title: 'Could not load ${widget.tab == 'movies' ? 'movies' : 'shows'}', subtitle: why),
                      SizedBox(height: 1.25 * rem),
                      PekButton(label: 'Try again', primary: true, onTap: () => setState(() => _data = _load())),
                    ],
                  ),
                ),
              );
            }
            final items = snap.data ?? const <Object>[];
            if (items.isEmpty) return _empty(context);
            // Marking something watched, or finishing it, changes the list and the counts; a genre / actor / sort pick does too.
            return ListenableBuilder(
              listenable: _f,
              builder: (context, _) => ValueListenableBuilder<int>(
                valueListenable: Store.changed,
                builder: (context, _, __) {
                  final what = widget.tab == 'movies' ? 'movies' : 'shows';
                  final resuming = resumeIds();
                  // Genre and actor first, then the watched state (the numbers in the Show menu follow the genre and actor), then the order.
                  final inScope = [for (final it in items) if (it is Movie ? _f.allowsMovie(it) : _f.allowsShow(it as Show)) it];
                  final status = [for (final it in inScope) it is Movie ? movieStatus(it, resuming) : showStatus(it as Show, resuming)];
                  final counts = <WatchFilter, int>{WatchFilter.all: inScope.length, for (final f in WatchFilter.values) if (f != WatchFilter.all) f: 0};
                  for (final st in status) {
                    counts[st] = (counts[st] ?? 0) + 1;
                  }
                  final byState = _f.watch == WatchFilter.all
                      ? inScope
                      : [
                          for (var i = 0; i < inScope.length; i++)
                            if (status[i] == _f.watch) inScope[i],
                        ];
                  final shown = sortedBy<Object>(
                    byState,
                    _f.sort,
                    _f.seed,
                    title: (o) => o is Movie ? o.title : (o as Show).title,
                    year: (o) => o is Movie ? o.year : 0,
                  );
                  final bar = SliverPadding(
                    padding: EdgeInsets.only(left: widget.padding.left, right: widget.padding.right, bottom: (p.isTv ? 1.25 : 1) * rem),
                    sliver: SliverToBoxAdapter(child: LibraryFilterBar(filters: _f, counts: counts)),
                  );
                  if (_f.pending || _f.failed || shown.isEmpty) {
                    final PekCard card;
                    if (_f.pending) {
                      card = const PekCard(title: 'Filtering\u2026', subtitle: 'Asking your library.');
                    } else if (_f.failed) {
                      card = const PekCard(title: 'Could not reach your library', subtitle: 'Is the server running? Change the genre or actor above to try again.');
                    } else if (_f.active) {
                      card = PekCard(
                        title: _f.watch == WatchFilter.all ? 'No $what match' : 'No ${_f.watch.label.toLowerCase()} $what match',
                        subtitle: 'Change a filter above, or tap Clear filters to see all your $what.',
                      );
                    } else {
                      card = PekCard(title: 'No $what', subtitle: 'Nothing to show here yet.');
                    }
                    return SliverMainAxisGroup(slivers: [
                      bar,
                      SliverPadding(padding: widget.padding.copyWith(top: 0), sliver: SliverToBoxAdapter(child: card)),
                    ]);
                  }
                  return SliverMainAxisGroup(slivers: [
                    bar,
                    SliverPadding(
                      padding: widget.padding.copyWith(top: 0),
                      sliver: PekGridSliver(
                        count: shown.length,
                        // .sx-poster-grid: minmax(200px, 1fr), gap 1rem (1.25rem on TV); on small screens 110px and 0.6rem.
                        minWidth: p.compact ? 110 : 200,
                        gap: p.compact ? 0.6 * rem : (p.isTv ? 1.25 : 1) * rem,
                        builder: (context, i) => _cell(context, shown[i], i),
                      ),
                    ),
                  ]);
                },
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _cell(BuildContext context, Object item, int i) {
    if (item is Movie) {
      // A tick before the year once it is in Watch History (msub() in app_library.js).
      return ValueListenableBuilder<int>(
        valueListenable: Store.changed,
        builder: (context, _, __) => PosterCard(
          title: item.title,
          subtitle: ('${movieWatched(item) ? '\u2713 ' : ''}${item.year > 0 ? item.year : ''}').trim(),
          poster: Api.movieDetails(item.id),
          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => MovieScreen(movie: item))),
        ),
      );
    }
    final s = item as Show;
    return PosterCard(
      title: s.title,
      subtitle: '${s.episodeCount} episodes',
      poster: Api.showDetails(s.title),
      onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ShowScreen(show: s))),
    );
  }

  /// _renderEmptyLibrary(): "No movies yet" + the add-source button (Settings > Media sources).
  Widget _empty(BuildContext context) {
    final rem = context.pek.rem;
    final what = widget.tab == 'movies' ? 'movies' : 'shows';
    return SliverPadding(
      padding: widget.padding.copyWith(top: 0),
      sliver: SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PekCard(
              title: _scanning ? 'Scanning your library\u2026' : 'No $what yet',
              subtitle: _scanning ? 'Your $what appear here when the scan finishes.' : 'Add a media folder and PEK TV will scan it and sort your videos here.',
            ),
            SizedBox(height: 1.25 * rem),
            PekButton(
              label: 'Add a source',
              primary: true,
              onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (c) => SubScreen(title: 'Settings', body: SettingsPage(padding: c.pek.pagePad)))),
            ),
          ],
        ),
      ),
    );
  }
}
