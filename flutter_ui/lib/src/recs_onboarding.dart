import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_animate/flutter_animate.dart';

import 'art_cache.dart' show ArtImage;
import 'recs.dart';
import 'tokens.dart';
import 'widgets.dart';

/// The taste picker, laid out like Spotify's "choose your artists" screen: round bubbles that pop in one after the other, bounce and
/// ring when tapped, and a counter at the bottom. Step 1 is genres, step 2 is movies and shows (picking one adds similar titles next
/// to it). It runs once on the first launch of a new profile (skippable) and any time from the Recommended widget.
class RecsPicker {
  /// Opens the picker over the current screen (from the Recommended widget). Saves when the person finishes, nothing when they cancel.
  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (c) => RecsOnboardingScreen(firstRun: false, onDone: () => Navigator.of(c).pop()),
      ),
    );
  }
}

class RecsOnboardingScreen extends StatefulWidget {
  const RecsOnboardingScreen({super.key, required this.firstRun, required this.onDone});

  /// true: shown at launch ("Skip" leaves it for good). false: opened from the widget ("Cancel" changes nothing).
  final bool firstRun;
  final VoidCallback onDone;

  @override
  State<RecsOnboardingScreen> createState() => _RecsOnboardingScreenState();
}

class _RecsOnboardingScreenState extends State<RecsOnboardingScreen> {
  int _step = 0; // 0 genres, 1 movies and shows
  final _genres = <String>{...Recs.genres};
  final _picked = <String, RecPick>{}; // keeps the order they were picked in
  List<RecItem> _items = [];
  bool _loading = false;
  bool _failed = false;
  bool _loadedOnce = false;
  String _loadedFor = '';
  int _page = 1;
  final _similarDone = <String>{};

  @override
  void initState() {
    super.initState();
    for (final k in Recs.picks) {
      _picked[k.key] = k;
    }
  }

  List<String> get _genreIds => [for (final g in recGenres) if (_genres.contains(g.id)) g.id];

  // ------------------------------------------------------------------ steps

  void _next() {
    setState(() => _step = 1);
    final sig = _genreIds.join(',');
    if (!_loadedOnce || sig != _loadedFor) unawaited(_loadTitles());
  }

  Future<void> _loadTitles({bool more = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final ids = _genreIds;
    final page = more ? _page + 1 : 1;
    final got = more ? await RecFeed.pickerTitles(ids, page: page) : [for (final l in await Future.wait([RecFeed.pickerTitles(ids), RecFeed.pickerTitles(ids, page: 2)])) ...l];
    if (!mounted) return;
    setState(() {
      _loading = false;
      _loadedOnce = true;
      if (!more) {
        _loadedFor = ids.join(',');
        _page = 2;
        // Titles picked before (editing from the widget) stay on screen, first.
        _items = [for (final k in _picked.values) RecItem(id: k.id, tv: k.tv, title: k.title, year: k.year, poster: k.poster)];
      } else if (got.isNotEmpty) {
        _page = page;
      }
      _failed = got.isEmpty && _items.isEmpty;
      for (final i in got) {
        if (!_items.any((e) => e.key == i.key)) _items.add(i);
      }
    });
  }

  void _toggleGenre(String id) {
    HapticFeedback.selectionClick();
    setState(() => _genres.contains(id) ? _genres.remove(id) : _genres.add(id));
  }

  void _toggleTitle(RecItem i) {
    HapticFeedback.selectionClick();
    final k = i.key;
    if (_picked.containsKey(k)) {
      setState(() => _picked.remove(k));
      return;
    }
    if (_picked.length >= Recs.maxPicks) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('That is plenty: ${Recs.maxPicks} picks is the most.')));
      return;
    }
    setState(() => _picked[k] = RecPick.fromItem(i));
    unawaited(_addSimilar(i));
  }

  /// Like Spotify's related artists: a few similar titles appear right after the one just picked.
  Future<void> _addSimilar(RecItem i) async {
    if (!_similarDone.add(i.key)) return;
    final sim = await RecFeed.similarTo(RecPick.fromItem(i));
    if (!mounted) return;
    final fresh = sim.where((s) => !_items.any((e) => e.key == s.key)).take(4).toList();
    if (fresh.isEmpty) return;
    setState(() {
      final at = _items.indexWhere((e) => e.key == i.key);
      _items.insertAll(at < 0 ? _items.length : at + 1, fresh);
    });
  }

  // ------------------------------------------------------------------ leaving

  Future<void> _finish() async {
    await Recs.finishOnboarding(_genreIds, _picked.values.toList());
    if (mounted) widget.onDone();
  }

  /// Step 1 "Skip": nothing is saved. Step 2 "Skip": the genres are kept, no titles.
  Future<void> _skip() async {
    if (_step == 1 && (_genres.isNotEmpty || _picked.isNotEmpty)) return _finish();
    if (widget.firstRun) await Recs.skipOnboarding();
    if (mounted) widget.onDone();
  }

  // ------------------------------------------------------------------ look

  double _bubble(PekScope p) {
    if (p.isTv) return 7.5 * p.rem;
    return ((p.size.width - 32 - 24) / 3).clamp(88.0, 130.0);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final count = _step == 0 ? _genres.length : _picked.length;
    return PopScope(
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step == 1) setState(() => _step = 0);
      },
      child: Scaffold(
        backgroundColor: t.bg,
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: p.safeX),
            child: Column(children: [
              Padding(
                padding: EdgeInsets.fromLTRB(rem, 0.75 * rem, rem, 0),
                child: Row(children: [
                  for (var i = 0; i < 2; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutCubic,
                      margin: EdgeInsets.only(right: 0.4 * rem),
                      width: (i == _step ? 1.6 : 0.5) * rem,
                      height: 0.5 * rem,
                      decoration: BoxDecoration(color: i <= _step ? t.accent : t.border, borderRadius: BorderRadius.circular(99)),
                    ),
                  const Spacer(),
                  PekButton(compact: true, shrink: true, label: _step == 0 && !widget.firstRun ? 'Cancel' : 'Skip', onTap: _skip),
                ]),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(rem, rem, rem, 0.5 * rem),
                child: Align(
                  alignment: Alignment.centerLeft,
                  // A new key replays the slide-in whenever the step changes (flutter_animate).
                  child: Column(key: ValueKey('head$_step'), crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_step == 0 ? 'What do you like to watch?' : 'Now pick some movies and shows', style: TextStyle(fontSize: 1.5 * rem, fontWeight: FontWeight.w800, height: 1.15)),
                    SizedBox(height: 0.35 * rem),
                    Text(
                      _step == 0 ? 'Pick a few genres. You can change this any time.' : 'Tap the ones you like and we will add more like them.',
                      style: TextStyle(color: t.textMuted, fontSize: 0.95 * rem),
                    ),
                  ]).animate(key: ValueKey('head-anim$_step')).fadeIn(duration: 350.ms).slideY(begin: 0.25, end: 0, duration: 450.ms, curve: Curves.easeOutCubic),
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  switchInCurve: Curves.easeOutCubic,
                  transitionBuilder: (c, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: const Offset(0.05, 0), end: Offset.zero).animate(a), child: c)),
                  child: _step == 0 ? _genreStep(context) : _titleStep(context),
                ),
              ),
              _bar(context, count),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _genreStep(BuildContext context) {
    final p = context.pek;
    final rem = p.rem;
    final size = _bubble(p);
    return SingleChildScrollView(
      key: const ValueKey('genres'),
      padding: EdgeInsets.fromLTRB(rem, rem, rem, 2 * rem),
      child: Center(
        child: Wrap(spacing: 12, runSpacing: rem, alignment: WrapAlignment.center, children: [
          for (var i = 0; i < recGenres.length; i++)
            _PopIn(
              key: ValueKey('g-${recGenres[i].id}'),
              delay: Duration(milliseconds: 45 * i),
              child: _PickBubble(
                size: size,
                label: recGenres[i].name,
                selected: _genres.contains(recGenres[i].id),
                autofocus: i == 0,
                onTap: () => _toggleGenre(recGenres[i].id),
                fill: _GenreFill(genre: recGenres[i], size: size),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _titleStep(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final size = _bubble(p);
    if (_items.isEmpty) {
      if (_loading || !_loadedOnce) {
        return SingleChildScrollView(
          key: const ValueKey('titles-loading'),
          padding: EdgeInsets.all(rem),
          child: Center(
            child: Wrap(spacing: 12, runSpacing: rem, alignment: WrapAlignment.center, children: [
              for (var i = 0; i < 12; i++)
                Container(width: size, height: size, decoration: BoxDecoration(shape: BoxShape.circle, color: t.surface))
                    .animate(onPlay: (c) => c.repeat(), delay: (60 * i).ms)
                    .shimmer(duration: 1200.ms, color: t.border),
            ]),
          ),
        );
      }
      return Center(
        key: const ValueKey('titles-failed'),
        child: Padding(
          padding: EdgeInsets.all(2 * rem),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Could not load movies and shows. Check your connection.', textAlign: TextAlign.center, style: TextStyle(color: t.textMuted)),
            SizedBox(height: rem),
            PekButton(label: 'Try again', primary: true, shrink: true, autofocus: true, onTap: _loadTitles),
          ]),
        ),
      );
    }
    return SingleChildScrollView(
      key: const ValueKey('titles'),
      padding: EdgeInsets.fromLTRB(rem, rem, rem, 2 * rem),
      child: Column(children: [
        Wrap(spacing: 12, runSpacing: rem, alignment: WrapAlignment.center, children: [
          for (var i = 0; i < _items.length; i++)
            _PopIn(
              key: ValueKey('t-${_items[i].key}'),
              delay: Duration(milliseconds: 35 * (i % 12)),
              child: _PickBubble(
                size: size,
                label: _items[i].title,
                selected: _picked.containsKey(_items[i].key),
                autofocus: i == 0,
                onTap: () => _toggleTitle(_items[i]),
                fill: _PosterFill(item: _items[i]),
              ),
            ),
        ]),
        SizedBox(height: 1.5 * rem),
        if (_loading)
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
        else
          PekButton(compact: true, shrink: true, label: 'Show more', onTap: () => _loadTitles(more: true)),
      ]),
    );
  }

  Widget _bar(BuildContext context, int count) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    return Container(
      padding: EdgeInsets.fromLTRB(rem, 0.75 * rem, rem, 0.75 * rem),
      decoration: BoxDecoration(color: t.bg, border: Border(top: BorderSide(color: t.border))),
      child: Row(children: [
        if (_step == 1) ...[
          PekButton(compact: true, shrink: true, label: 'Back', onTap: () => setState(() => _step = 0)),
          SizedBox(width: 0.75 * rem),
        ],
        // The number pops each time it changes.
        Text(count == 0 ? 'Nothing picked yet' : '$count picked', key: ValueKey('count$count'), style: TextStyle(fontWeight: FontWeight.w700, fontSize: 0.95 * rem, color: count == 0 ? t.textMuted : t.text))
            .animate(key: ValueKey('count-anim$count$_step'))
            .scaleXY(begin: count == 0 ? 1 : 1.25, end: 1, duration: 450.ms, curve: Curves.elasticOut),
        const Spacer(),
        PekButton(
          primary: true,
          shrink: true,
          label: count == 0 ? 'Pick a few' : (_step == 0 ? 'Next' : 'Done'),
          onTap: count == 0 ? null : (_step == 0 ? _next : _finish),
        ),
      ]),
    );
  }
}

// ====================================================================== bubbles

/// Pops its child in (scale with a bounce, plus a fade) a little after it is built. Runs once: a rebuild does not replay it.
class _PopIn extends StatefulWidget {
  const _PopIn({super.key, required this.child, this.delay = Duration.zero});
  final Widget child;
  final Duration delay;

  @override
  State<_PopIn> createState() => _PopInState();
}

class _PopInState extends State<_PopIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: _c, curve: const Interval(0, 0.4, curve: Curves.easeOut)),
      child: ScaleTransition(scale: Tween<double>(begin: 0.3, end: 1).animate(CurvedAnimation(parent: _c, curve: Curves.elasticOut)), child: widget.child),
    );
  }
}

/// One round choice with its name underneath. Tapping squeezes it, then it springs bigger with an accent ring, a ring that bursts
/// outward and a check badge that bounces in. Works with touch and with a TV remote (it is a [PekFocusable]).
class _PickBubble extends StatefulWidget {
  const _PickBubble({required this.size, required this.label, required this.selected, required this.onTap, required this.fill, this.autofocus = false});
  final double size;
  final String label;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;
  final Widget fill;

  @override
  State<_PickBubble> createState() => _PickBubbleState();
}

class _PickBubbleState extends State<_PickBubble> with SingleTickerProviderStateMixin {
  late final AnimationController _burst = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
  bool _down = false;

  @override
  void didUpdateWidget(_PickBubble old) {
    super.didUpdateWidget(old);
    if (widget.selected && !old.selected) _burst.forward(from: 0);
  }

  @override
  void dispose() {
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final size = widget.size;
    final sel = widget.selected;
    return SizedBox(
      width: size,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Listener(
          onPointerDown: (_) => setState(() => _down = true),
          onPointerUp: (_) => setState(() => _down = false),
          onPointerCancel: (_) => setState(() => _down = false),
          child: AnimatedScale(
            scale: _down ? 0.92 : (sel ? 1.06 : 1.0),
            duration: Duration(milliseconds: _down ? 90 : 520),
            curve: _down ? Curves.easeOut : Curves.elasticOut,
            child: SizedBox(
              width: size,
              height: size,
              child: Stack(clipBehavior: Clip.none, children: [
                // The ring that bursts outward when something is picked.
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _burst,
                      builder: (_, __) {
                        final v = _burst.value;
                        if (v == 0) return const SizedBox.shrink();
                        return Opacity(
                          opacity: ((1 - v) * 0.7).clamp(0.0, 1.0),
                          child: Transform.scale(
                            scale: 1 + 0.5 * Curves.easeOut.transform(v),
                            child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: t.accent, width: 3))),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                Positioned.fill(
                  child: PekFocusable(
                    autofocus: widget.autofocus,
                    onTap: widget.onTap,
                    radius: 999,
                    focusScale: p.isTv ? 1.08 : 1.0,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: sel ? t.accent : Colors.transparent, width: 3.5)),
                      padding: const EdgeInsets.all(2),
                      child: ClipOval(
                        child: Stack(fit: StackFit.expand, children: [
                          widget.fill,
                          AnimatedOpacity(duration: const Duration(milliseconds: 200), opacity: sel ? 1 : 0, child: const ColoredBox(color: Color(0x40000000))),
                        ]),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: size * 0.02,
                  top: size * 0.02,
                  child: IgnorePointer(
                    child: AnimatedScale(
                      scale: sel ? 1 : 0,
                      duration: const Duration(milliseconds: 450),
                      curve: Curves.elasticOut,
                      child: Container(
                        width: size * 0.26,
                        height: size * 0.26,
                        decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle, border: Border.all(color: t.bg, width: 2)),
                        child: Icon(Icons.check_rounded, size: size * 0.17, color: t.bg),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
        SizedBox(height: 0.45 * rem),
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: TextStyle(fontSize: 0.8 * rem, height: 1.2, fontWeight: sel ? FontWeight.w700 : FontWeight.w500, color: sel ? t.text : t.textMuted),
          child: Text(widget.label, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
        ),
      ]),
    );
  }
}

class _GenreLook {
  const _GenreLook(this.icon, this.a, this.b);
  final IconData icon;
  final Color a;
  final Color b;
}

const _genreLooks = <String, _GenreLook>{
  'action': _GenreLook(Icons.local_fire_department_rounded, Color(0xFFFF6B3D), Color(0xFFD7263D)),
  'adventure': _GenreLook(Icons.explore_rounded, Color(0xFF1FA67A), Color(0xFF0B6E4F)),
  'animation': _GenreLook(Icons.animation_rounded, Color(0xFFFFB347), Color(0xFFFF5E78)),
  'comedy': _GenreLook(Icons.sentiment_very_satisfied_rounded, Color(0xFFFFD23F), Color(0xFFF59E0B)),
  'crime': _GenreLook(Icons.fingerprint_rounded, Color(0xFF4B5563), Color(0xFF111827)),
  'documentary': _GenreLook(Icons.videocam_rounded, Color(0xFF3B82F6), Color(0xFF1E3A8A)),
  'drama': _GenreLook(Icons.theater_comedy_rounded, Color(0xFFB45309), Color(0xFF7C2D12)),
  'family': _GenreLook(Icons.family_restroom_rounded, Color(0xFF34D399), Color(0xFF0E9F6E)),
  'fantasy': _GenreLook(Icons.auto_awesome_rounded, Color(0xFFA855F7), Color(0xFF6D28D9)),
  'history': _GenreLook(Icons.account_balance_rounded, Color(0xFFA16207), Color(0xFF713F12)),
  'horror': _GenreLook(Icons.nightlight_round, Color(0xFF7F1D1D), Color(0xFF1C1917)),
  'mystery': _GenreLook(Icons.search_rounded, Color(0xFF6366F1), Color(0xFF312E81)),
  'reality': _GenreLook(Icons.live_tv_rounded, Color(0xFFEC4899), Color(0xFFBE185D)),
  'romance': _GenreLook(Icons.favorite_rounded, Color(0xFFFB7185), Color(0xFFE11D48)),
  'scifi': _GenreLook(Icons.rocket_launch_rounded, Color(0xFF22D3EE), Color(0xFF0E7490)),
  'thriller': _GenreLook(Icons.bolt_rounded, Color(0xFFEF4444), Color(0xFF7F1D1D)),
  'war': _GenreLook(Icons.shield_rounded, Color(0xFF65A30D), Color(0xFF365314)),
  'western': _GenreLook(Icons.landscape_rounded, Color(0xFFD97706), Color(0xFF92400E)),
};

class _GenreFill extends StatelessWidget {
  const _GenreFill({required this.genre, required this.size});
  final RecGenre genre;
  final double size;

  @override
  Widget build(BuildContext context) {
    final look = _genreLooks[genre.id] ?? const _GenreLook(Icons.movie_rounded, Color(0xFF6B7280), Color(0xFF374151));
    return DecoratedBox(
      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [look.a, look.b])),
      child: Center(child: Icon(look.icon, size: size * 0.42, color: Colors.white.withAlpha(235))),
    );
  }
}

class _PosterFill extends StatelessWidget {
  const _PosterFill({required this.item});
  final RecItem item;

  @override
  Widget build(BuildContext context) {
    final t = context.pek.tokens;
    if (item.poster.isEmpty) return _plain(t);
    return ArtImage(
      item.image,
      fit: BoxFit.cover,
      cacheWidth: 300,
      placeholder: (_) => ColoredBox(color: t.surface),
      errorBuilder: (_, __, ___) => _plain(t),
    );
  }

  Widget _plain(PekTokens t) => Container(
        color: t.surface,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(8),
        child: Text(item.title, textAlign: TextAlign.center, maxLines: 4, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.text, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}
