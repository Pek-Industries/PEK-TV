import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'art_cache.dart';
import 'detail.dart';
import 'plugin_ui.dart' show PekTrailerView;
import 'ratings.dart';
import 'recs.dart' show Recs;
import 'simple_data.dart';
import 'simple_shell.dart' show SimpleShelf;
import 'store.dart';
import 'tokens.dart';
import 'watched.dart';
import 'widgets.dart';

/// A movie's or show's page in the Simple layout: its trailer plays on top (muted unless Settings > Mode > Layout says otherwise),
/// then the title, a line of facts, Play (Resume, or the show's next episode), My List and Mark as watched, the description, and
/// More Like This below. Wide screens put the text over the trailer, like the banner on the home screen.
///
/// More Like This is what TMDb recommends that is also in the library, topped up with library titles of the same genre.
class SimpleDetailScreen extends StatefulWidget {
  const SimpleDetailScreen({super.key, required this.title, this.lib});
  final SimpleTitle title;

  /// The library lookups when the caller has them; null = loaded here when the page needs them.
  final SimpleLib? lib;

  @override
  State<SimpleDetailScreen> createState() => _SimpleDetailScreenState();
}

class _SimpleDetailScreenState extends State<SimpleDetailScreen> {
  late final Future<SimpleMeta> _meta = SimpleMeta.of(widget.title);
  late final Future<List<SimpleTitle>> _related = _meta.then(_findRelated);
  SimpleLib? _lib;
  bool _covered = false; // the player (or another screen) is on top: pause the trailer

  @override
  void initState() {
    super.initState();
    _lib = widget.lib;
  }

  Future<List<SimpleTitle>> _findRelated(SimpleMeta m) async {
    try {
      final lib = _lib ??= await SimpleLib.load();
      final out = <SimpleTitle>[];
      final seen = <String>{widget.title.key};
      // What TMDb recommends: the ones the library has first (they play), then the rest as suggestions (they open Discover).
      final hidden = Recs.hidden;
      for (final r in m.related) {
        final hit = lib.named(r.title, tv: r.tv);
        if (hit != null && seen.add(hit.key)) out.add(hit);
      }
      for (final r in m.related) {
        if (out.length >= 16) break;
        if (hidden.contains(r.key) || lib.named(r.title, tv: r.tv) != null) continue;
        final t = SimpleTitle.rec(r);
        if (seen.add(t.key)) out.add(t);
      }
      if (out.length < 6 && m.genres.isNotEmpty && widget.title.inLibrary) {
        final res = await Api.librarySearch('', genre: m.genres.first, limit: 40, only: widget.title.tv ? 'shows' : 'movies');
        if (res != null) {
          for (final t in lib.fromSearch(res)) {
            if (out.length >= 12) break;
            if (seen.add(t.key)) out.add(t);
          }
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _cover(Future<void> Function() action) async {
    if (!mounted) return;
    setState(() => _covered = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _covered = false);
    }
  }

  void _play() => unawaited(_cover(() => simplePlay(context, widget.title)));
  void _episodes() {
    final s = widget.title.show;
    if (s != null) unawaited(_cover(() => Navigator.push<void>(context, MaterialPageRoute<void>(builder: (_) => ShowScreen(show: s)))));
  }

  void _openRelated(SimpleTitle t) {
    Navigator.pushReplacement<void, void>(context, MaterialPageRoute<void>(builder: (_) => SimpleDetailScreen(title: t, lib: _lib)));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final size = MediaQuery.sizeOf(context);
    final wide = p.sidebar || size.width >= 900;
    final side = wide ? 2 * rem + p.safeX : rem;
    final mediaH = wide ? size.height * 0.62 : size.width * 9 / 16;
    return Scaffold(
      backgroundColor: t.bg,
      body: ValueListenableBuilder<int>(
        valueListenable: Store.changed, // a favorite or watched change repaints the buttons
        builder: (context, _, __) => FutureBuilder<SimpleMeta>(
          future: _meta,
          builder: (context, snap) {
            final m = snap.data ?? SimpleMeta.none;
            return Stack(children: [
              ListView(padding: EdgeInsets.zero, cacheExtent: 900, children: [
                SizedBox(height: mediaH, child: _media(context, m, mediaH, wide, side)),
                if (!wide) Padding(padding: EdgeInsets.fromLTRB(side, 0.75 * rem, side, 0), child: _phoneInfo(context, m)),
                Padding(padding: EdgeInsets.fromLTRB(side, 1.25 * rem, side, 2 * rem + p.safeY), child: _relatedRow(context)),
              ]),
              Positioned(
                left: 0.5 * rem + (wide ? p.safeX : 0),
                top: (wide ? p.safeY : MediaQuery.paddingOf(context).top) + 0.5 * rem,
                child: Semantics(
                  button: true,
                  label: 'Back',
                  child: PekFocusable(
                    radius: 40,
                    background: Colors.black.withAlpha(110),
                    padding: EdgeInsets.all(0.55 * rem),
                    onTap: () => Navigator.maybePop(context),
                    child: Icon(Icons.arrow_back, color: Colors.white, size: 1.5 * rem),
                  ),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }

  /// The picture and trailer (and, on a wide screen, the text over them).
  Widget _media(BuildContext context, SimpleMeta m, double height, bool wide, double side) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final title = widget.title;
    Widget poster() => FutureBuilder<Details>(
          future: title.details,
          builder: (_, s) {
            final url = s.data?.poster ?? '';
            return ColoredBox(
              color: t.surface,
              child: url.isEmpty ? const SizedBox.expand() : Align(alignment: Alignment.centerRight, child: SizedBox(height: height, child: AspectRatio(aspectRatio: 2 / 3, child: ArtImage(url, fit: BoxFit.cover, cacheWidth: 640)))),
            );
          },
        );
    return Stack(fit: StackFit.expand, children: [
      Positioned.fill(child: m.backdrop.isEmpty ? poster() : ArtImage(m.backdrop, fit: BoxFit.cover, cacheWidth: wide ? 1280 : 780, errorBuilder: (_, __, ___) => poster())),
      if (Store.simpleTrailers && m.trailer.isNotEmpty) Positioned.fill(child: PekTrailerView(videoId: m.trailer, muted: !Store.simpleSound, active: !_covered)),
      if (wide)
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight, colors: [Colors.black.withAlpha(215), Colors.black.withAlpha(0)], stops: const [0.0, 0.7]))),
          ),
        ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        height: height * (wide ? 0.14 : 0.2),
        child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [t.bg.withAlpha(0), t.bg])))),
      ),
      if (wide)
        Positioned(
          left: side,
          bottom: 1.6 * rem,
          width: MediaQuery.sizeOf(context).width * 0.5,
          child: _info(context, m, onImage: true),
        ),
    ]);
  }

  Widget _phoneInfo(BuildContext context, SimpleMeta m) => _info(context, m, onImage: false);

  /// Title, facts, buttons, description (and the person's rating). White text on the trailer when [onImage].
  Widget _info(BuildContext context, SimpleMeta m, {required bool onImage}) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final title = widget.title;
    final fg = onImage ? Colors.white : t.text;
    final soft = onImage ? Colors.white.withAlpha(215) : t.textMuted;
    final shadow = onImage ? const [Shadow(blurRadius: 10, color: Colors.black87)] : const <Shadow>[];
    final facts = m.ok ? m.facts(title) : title.subtitle;
    final fav = title.favorite;
    final seen = title.movie != null && movieWatched(title.movie!);
    final frac = SimpleProgress.now().of(title);

    Widget overview(String s) => onImage
        ? Text(s, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: soft, fontSize: 0.95 * rem, height: 1.35, shadows: shadow))
        : ExpandableText(s, maxLines: 4);

    final buttons = <Widget>[
      _DButton(icon: Icons.play_arrow_rounded, label: simplePlayLabel(title), primary: true, autofocus: p.isTv || onImage, rem: rem, onTap: _play),
      _DButton(icon: fav ? Icons.check : Icons.add, label: 'My List', rem: rem, onImage: onImage, onTap: () => unawaited(title.toggleFavorite())),
      if (title.movie != null) _DButton(icon: seen ? Icons.visibility : Icons.visibility_outlined, label: seen ? 'Watched' : 'Mark watched', rem: rem, onImage: onImage, onTap: () => unawaited(Watched.set([movieItem(title.movie!)], !seen))),
      if (title.show != null) _DButton(icon: Icons.list, label: 'Episodes', rem: rem, onImage: onImage, onTap: _episodes),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(title.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg, fontSize: (onImage ? 2.4 : 1.7) * rem, fontWeight: FontWeight.w900, height: 1.08, shadows: shadow)),
      SizedBox(height: 0.45 * rem),
      Row(children: [
        if (m.vote > 0) ...[
          Icon(Icons.star_rounded, color: const Color(0xFFFFC83D), size: 1.1 * rem),
          SizedBox(width: 0.2 * rem),
          Text(m.vote.toStringAsFixed(1), style: TextStyle(color: fg, fontSize: 0.9 * rem, fontWeight: FontWeight.w700, shadows: shadow)),
          SizedBox(width: 0.6 * rem),
        ],
        Flexible(child: Text(facts, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: soft, fontSize: 0.9 * rem, shadows: shadow))),
      ]),
      SizedBox(height: 0.9 * rem),
      // Phone: Play across the whole width, the rest side by side under it. Wide: all in one line.
      if (onImage) Wrap(spacing: 0.7 * rem, runSpacing: 0.7 * rem, children: buttons) else ...[
        buttons.first,
        SizedBox(height: 0.6 * rem),
        Wrap(spacing: 0.6 * rem, runSpacing: 0.6 * rem, children: buttons.skip(1).toList()),
      ],
      if (frac != null) ...[
        SizedBox(height: 0.7 * rem),
        // Netflix-style: how far along they are, under the buttons (from the library or a plugin).
        SizedBox(
          width: onImage ? 14 * rem : double.infinity,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: frac, minHeight: 4, color: t.accent, backgroundColor: onImage ? Colors.white24 : t.border)),
            SizedBox(height: 0.25 * rem),
            Text('${(frac * 100).round()}% watched', style: TextStyle(color: soft, fontSize: 0.75 * rem, shadows: shadow)),
          ]),
        ),
      ],
      SizedBox(height: 0.9 * rem),
      if (m.overview.isNotEmpty)
        overview(m.overview)
      else
        FutureBuilder<Details>(future: title.details, builder: (_, s) => (s.data?.overview ?? '').isEmpty ? const SizedBox.shrink() : overview(s.data!.overview)),
      if (!onImage) ...[
        SizedBox(height: rem),
        title.tv ? RatingPanel(title: title.title, kind: 'show') : RatingPanel(title: title.title, year: title.year),
      ],
    ]);
  }

  Widget _relatedRow(BuildContext context) {
    final p = context.pek;
    final rem = p.rem;
    return FutureBuilder<List<SimpleTitle>>(
      future: _related,
      builder: (context, snap) {
        final items = snap.data ?? const <SimpleTitle>[];
        if (items.isEmpty) return const SizedBox.shrink();
        final pm = SimpleProgress.now();
        return SimpleShelf(
          title: 'More Like This',
          memoryKey: 'simple/related',
          cardW: p.sidebar ? 6 * rem : 7 * rem,
          cards: [for (final it in items) PosterCard(title: it.title, subtitle: it.subtitle, poster: it.details, inLibrary: it.inLibrary, progress: pm.of(it), onTap: () => _openRelated(it))],
        );
      },
    );
  }
}

/// A button on the title page: Play (white, filled), the others grey glass on the trailer or a plain pill on the page.
class _DButton extends StatelessWidget {
  const _DButton({required this.icon, required this.label, required this.rem, required this.onTap, this.primary = false, this.onImage = false, this.autofocus = false});
  final IconData icon;
  final String label;
  final double rem;
  final bool primary;
  final bool onImage;
  final bool autofocus;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.pek.tokens;
    final Color fg = primary ? Colors.black : (onImage ? Colors.white : t.text);
    final Color bg = primary ? Colors.white : (onImage ? Colors.white.withAlpha(70) : t.surface);
    final Color focusBg = primary ? const Color(0xFFE6E6E6) : (onImage ? Colors.white.withAlpha(120) : t.surfaceFocused);
    final btn = PekFocusable(
      autofocus: autofocus,
      onTap: onTap,
      radius: 6,
      background: bg,
      focusBackground: focusBg,
      borderColor: primary || onImage ? null : t.border,
      padding: EdgeInsets.symmetric(horizontal: 1.1 * rem, vertical: 0.6 * rem),
      child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: fg, size: 1.4 * rem),
        SizedBox(width: 0.4 * rem),
        Text(label, style: TextStyle(color: fg, fontSize: 0.95 * rem, fontWeight: FontWeight.w700)),
      ]),
    );
    // The phone's Play button stretches across the column; the others keep their size.
    return primary && !onImage ? SizedBox(width: double.infinity, child: btn) : btn;
  }
}
