import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'onboarding_flow.dart' show LayoutChoice, SignInStep;
import 'recs.dart';
import 'store.dart';
import 'tokens.dart';
import 'widgets.dart';

/// "Welcome to PEK TV": a short swipe-through tour, one feature per screen, shown once on the very first launch, right before the
/// taste picker (recs_onboarding.dart). Phones get the portrait stand-in pictures, TVs (and any wide screen) the landscape ones.
///
/// TO ADD A FEATURE: add a [WelcomeSlide] to [welcomeSlides] below. With a [WelcomeSlide.shot] it shows that picture
/// (put `<name>.jpg` and `<name>-portrait.jpg` in `assets/welcome/`); without one it shows an illustration. When a feature that is
/// marked `soon: true` ships, delete the `soon` flag (and swap in a real screenshot).
class Welcome {
  static const _k = 'pek_welcome_v1';

  /// Bumped when the tour was finished or skipped (main.dart rebuilds into the next screen).
  static final changed = ValueNotifier<int>(0);

  /// Shown once per device (not per profile), and only to someone about to see the first-launch picker, so people updating an
  /// older install are not greeted again.
  static bool get pending => Store.strGet(_k, scoped: false) != '1' && Recs.onboardingPending;

  static Future<void> markSeen() async {
    await Store.strSet(_k, '1', scoped: false);
    await LayoutChoice.arm(); // the last first-launch questions (onboarding_flow.dart) come after the taste picker
    await SignInStep.arm();
    changed.value++;
  }

  /// Replays the tour from anywhere (for example a "Welcome tour" row in Settings).
  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push<void>(MaterialPageRoute(fullscreenDialog: true, builder: (c) => WelcomeScreen(onDone: () => Navigator.of(c).pop())));
  }
}

class WelcomeSlide {
  const WelcomeSlide({required this.title, required this.body, this.shot, this.icon = Icons.movie_rounded, this.soon = false, this.noteTitle, this.noteText});
  final String title;

  /// Plain language, a sentence or two.
  final String body;

  /// File name (no extension) in assets/welcome/. null = an illustration is drawn instead.
  final String? shot;
  final IconData icon;

  /// Not released yet: the slide carries a "Coming soon" tag.
  final bool soon;

  /// An example card drawn in the illustration (for slides with no screenshot).
  final String? noteTitle;
  final String? noteText;
}

const welcomeSlides = <WelcomeSlide>[
  WelcomeSlide(
    title: 'Welcome to PEK TV',
    body: 'Your movies, shows and music in one place, on your phone and on your TV. Swipe to see what it can do.',
    shot: 'dashboard',
  ),
  WelcomeSlide(
    title: 'All your movies',
    body: 'Point PEK TV at the folders on your device or your home network and your movies appear with posters and details. Search by title, actor, director or year.',
    shot: 'movies',
  ),
  WelcomeSlide(
    title: 'TV shows, season by season',
    body: 'Your shows are sorted into seasons and episodes. PEK TV remembers what you watched and where you stopped, so you can carry on right where you left off.',
    shot: 'tv-shows',
  ),
  WelcomeSlide(
    title: 'Know when new episodes arrive',
    body: 'Follow a show and PEK TV tells you when a new episode or season comes out, so you never have to keep checking.',
    icon: Icons.notifications_active_rounded,
    soon: true,
    noteTitle: 'New episode out now',
    noteText: 'Your Show \u00b7 Season 2, Episode 4',
  ),
  WelcomeSlide(
    title: 'Stop paying for what you do not watch',
    body: 'Get a reminder before a streaming subscription renews, so you can cancel the ones you are not using and keep the ones you love.',
    icon: Icons.savings_rounded,
    soon: true,
    noteTitle: 'Streaming reminder',
    noteText: 'Your subscription renews in 3 days',
  ),
  WelcomeSlide(
    title: 'A player that stays out of the way',
    body: 'Subtitles turn on by themselves. Skip the intro or the recap with one tap, and the next episode is ready as soon as this one ends.',
    shot: 'episode-details',
  ),
  WelcomeSlide(
    title: 'Your music too',
    body: 'Play the music from your own folders: albums, artists, playlists and a queue. The song keeps playing while you do other things.',
    shot: 'music-now-playing',
  ),
  WelcomeSlide(
    title: 'Your phone is the remote',
    body: 'On your TV, pair your Android phone once with a 6-digit code. Then use it as the remote and the keyboard.',
    shot: 'phone-remote',
  ),
  WelcomeSlide(
    title: 'Make it yours',
    body: 'Everyone at home can have their own profile with their own history and favorites. Change the look with skins and arrange your home screen the way you like.',
    shot: 'settings',
  ),
];

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, required this.onDone});

  /// Called when the person reaches the end or taps Skip.
  final VoidCallback onDone;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _ctrl = PageController();
  int _i = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _go(int to) => _ctrl.animateToPage(to, duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);

  void _next() => _i >= welcomeSlides.length - 1 ? widget.onDone() : _go(_i + 1);

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final wide = p.isTv || p.size.width > p.size.height;
    final last = _i == welcomeSlides.length - 1;
    return PopScope(
      canPop: _i == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _go(_i - 1);
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
                  for (var i = 0; i < welcomeSlides.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutCubic,
                      margin: EdgeInsets.only(right: 0.35 * rem),
                      width: (i == _i ? 1.6 : 0.5) * rem,
                      height: 0.5 * rem,
                      decoration: BoxDecoration(color: i <= _i ? t.accent : t.border, borderRadius: BorderRadius.circular(99)),
                    ),
                  const Spacer(),
                  if (!last) PekButton(compact: true, shrink: true, label: 'Skip', onTap: widget.onDone),
                ]),
              ),
              Expanded(
                // Mouse drags scroll it too (a TV box with a mouse, an emulator); touch swipes always do.
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse, PointerDeviceKind.trackpad}),
                  child: PageView.builder(
                    controller: _ctrl,
                    itemCount: welcomeSlides.length,
                    onPageChanged: (i) => setState(() => _i = i),
                    itemBuilder: (c, i) => _page(c, i, wide),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(rem, 0.5 * rem, rem, 0.75 * rem),
                child: Row(children: [
                  if (_i > 0) PekButton(compact: true, shrink: true, label: 'Back', onTap: () => _go(_i - 1)),
                  const Spacer(),
                  PekButton(primary: true, shrink: true, autofocus: true, label: last ? 'Get started' : 'Next', onTap: _next),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _page(BuildContext context, int i, bool wide) {
    final p = context.pek;
    final rem = p.rem;
    final s = welcomeSlides[i];
    final media = _Media(slide: s, wide: wide);
    final copy = _Copy(slide: s);
    return AnimatedBuilder(
      animation: _ctrl,
      // The page next to the current one shrinks and fades a little as you swipe.
      builder: (context, child) {
        var page = _i.toDouble();
        if (_ctrl.hasClients && _ctrl.position.haveDimensions) page = _ctrl.page ?? page;
        final d = (page - i).abs().clamp(0.0, 1.0);
        return Opacity(opacity: 1 - 0.7 * d, child: Transform.scale(scale: 1 - 0.06 * d, child: child));
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(rem, rem, rem, 0),
        child: wide
            ? Row(children: [
                Expanded(flex: 5, child: Padding(padding: EdgeInsets.only(right: 2 * rem), child: Center(child: SingleChildScrollView(child: copy)))),
                Expanded(flex: 7, child: media),
              ])
            : Column(children: [
                Expanded(flex: 6, child: media),
                SizedBox(height: rem),
                Expanded(flex: 4, child: SingleChildScrollView(child: copy)),
              ]),
      ),
    );
  }
}

class _Copy extends StatelessWidget {
  const _Copy({required this.slide});
  final WelcomeSlide slide;

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (slide.soon)
        Container(
          margin: EdgeInsets.only(bottom: 0.6 * rem),
          padding: EdgeInsets.symmetric(horizontal: 0.7 * rem, vertical: 0.25 * rem),
          decoration: BoxDecoration(color: t.accent.withAlpha(36), borderRadius: BorderRadius.circular(99), border: Border.all(color: t.accent)),
          child: Text('Coming soon', style: TextStyle(fontSize: 0.8 * rem, fontWeight: FontWeight.w700, color: t.accent)),
        ).animate(onPlay: (c) => c.repeat(), delay: 600.ms).shimmer(duration: 1800.ms, color: Colors.white54),
      Text(slide.title, style: TextStyle(fontSize: 1.7 * rem, fontWeight: FontWeight.w800, height: 1.15)),
      SizedBox(height: 0.6 * rem),
      Text(slide.body, style: TextStyle(fontSize: 1.0 * rem, height: 1.45, color: t.textMuted)),
    ]);
  }
}

class _Media extends StatelessWidget {
  const _Media({required this.slide, required this.wide});
  final WelcomeSlide slide;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final shot = slide.shot;
    if (shot == null) return _Art(slide: slide);
    final path = 'assets/welcome/$shot${wide ? '' : '-portrait'}.jpg';
    return Center(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(p.compact ? 14 : 18),
          border: Border.all(color: t.border, width: 2),
          boxShadow: [BoxShadow(color: t.shadow, blurRadius: 24, offset: const Offset(0, 10))],
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.asset(path, fit: BoxFit.contain, errorBuilder: (_, __, ___) => SizedBox(width: 200, height: 200, child: _Art(slide: slide))),
      ),
    );
  }
}

/// The picture for a slide that has no screenshot: a soft panel with a floating example card (or a big icon).
class _Art extends StatelessWidget {
  const _Art({required this.slide});
  final WelcomeSlide slide;

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final Widget inner;
    if (slide.noteTitle != null) {
      inner = Container(
        constraints: BoxConstraints(maxWidth: 22 * rem),
        padding: EdgeInsets.all(1.0 * rem),
        decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: t.border), boxShadow: [BoxShadow(color: t.shadow, blurRadius: 18, offset: const Offset(0, 8))]),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 2.8 * rem,
            height: 2.8 * rem,
            decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle),
            child: Icon(slide.icon, color: t.bg, size: 1.5 * rem),
          ),
          SizedBox(width: 0.9 * rem),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(slide.noteTitle!, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 1.0 * rem)),
              SizedBox(height: 0.15 * rem),
              Text(slide.noteText ?? '', style: TextStyle(color: t.textMuted, fontSize: 0.85 * rem)),
            ]),
          ),
        ]),
      );
    } else {
      inner = Icon(slide.icon, size: 7 * rem, color: t.accent);
    }
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [t.accent.withAlpha(60), t.surface]),
        border: Border.all(color: t.border),
      ),
      alignment: Alignment.center,
      padding: EdgeInsets.all(rem),
      child: inner.animate(onPlay: (c) => c.repeat(reverse: true)).moveY(begin: -6, end: 6, duration: 1800.ms, curve: Curves.easeInOut),
    );
  }
}
