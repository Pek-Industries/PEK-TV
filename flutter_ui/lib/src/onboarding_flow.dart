import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'account_pages.dart';
import 'cloud.dart';
import 'common.dart';
import 'link_login.dart';
import 'plan_ui.dart' show openSignUpPage;
import 'profiles.dart';
import 'recs.dart';
import 'recs_onboarding.dart';
import 'skins.dart';
import 'store.dart';
import 'tokens.dart';
import 'welcome.dart';
import 'widgets.dart';

/// First-launch question: Simple or Advanced layout (simple_shell.dart / the dashboard). Asked once per device, after the welcome tour
/// and taste picker. [Welcome.markSeen] arms it; an install that was updated from an older version never is.
class LayoutChoice {
  static const _k = 'pek_layout_v1'; // '0' = to be asked, '1' = answered

  static bool get pending => Store.strGet(_k, scoped: false) == '0';

  static Future<void> arm() async {
    if (Store.strGet(_k, scoped: false) == null) await Store.strSet(_k, '0', scoped: false);
  }

  /// Remembers the answer (Settings > Mode > Layout shows it and can change it) and lets main.dart move on into the app.
  static Future<void> choose(bool simple) async {
    await Store.strSet(_k, '1', scoped: false);
    await Store.setSimpleMode(simple);
    Welcome.changed.value++;
  }
}

/// The last first-launch page: sign in or sign up (or "Sign in later"). Asked once per device, after the layout question, and not at
/// all when the device is already signed in. Armed together with [LayoutChoice].
class SignInStep {
  static const _k = 'pek_signin_v1'; // '0' = to be asked, '1' = answered

  static bool get pending => Store.strGet(_k, scoped: false) == '0' && !Cloud.linked;

  static Future<void> arm() async {
    if (Store.strGet(_k, scoped: false) == null) await Store.strSet(_k, '0', scoped: false);
  }

  /// Signed in, or "Sign in later": main.dart moves on into the app.
  static Future<void> finish() async {
    await Store.strSet(_k, '1', scoped: false);
    Welcome.changed.value++;
  }
}

enum _Step { welcome, recs, layout, signIn }

/// First launch, start to finish: the welcome tour, the taste picker, the layout question, then sign in / sign up. Each screen slides in
/// from the right when the one before it is answered (or skipped); the last one (signing in, or "Sign in later") opens the app
/// (main.dart stops showing this).
/// Only the steps that are still needed are shown, so a new profile on an old install just gets the taste picker.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  late final List<_Step> _steps = [
    if (Welcome.pending) _Step.welcome,
    if (Recs.onboardingPending) _Step.recs,
    if (LayoutChoice.pending || Welcome.pending) _Step.layout,
    if (SignInStep.pending || Welcome.pending) _Step.signIn,
  ];
  int _i = 0;

  void _next() {
    if (!mounted || _i >= _steps.length - 1) return;
    setState(() => _i++);
  }

  Widget _screen(_Step s) {
    switch (s) {
      case _Step.welcome:
        return WelcomeScreen(key: const ValueKey(_Step.welcome), onDone: () async {
          await Welcome.markSeen();
          _next();
        });
      case _Step.recs:
        return RecsOnboardingScreen(key: ValueKey('recs-first-${Profiles.currentId}'), firstRun: true, onDone: _next);
      case _Step.layout:
        return LayoutChoiceScreen(key: const ValueKey(_Step.layout), onDone: _next);
      case _Step.signIn:
        return const SignInScreen(key: ValueKey(_Step.signIn));
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _screen(_steps[_i]);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) {
        // The new screen comes in from the right, the old one leaves to the left.
        final incoming = child.key == current.key;
        return SlideTransition(position: Tween(begin: Offset(incoming ? 1 : -1, 0), end: Offset.zero).animate(anim), child: child);
      },
      child: current,
    );
  }
}

/// "How do you want PEK TV to look?": two big cards. Tapping one (or pressing OK on it) saves it and slides on to the next page.
class LayoutChoiceScreen extends StatefulWidget {
  const LayoutChoiceScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<LayoutChoiceScreen> createState() => _LayoutChoiceScreenState();
}

class _LayoutChoiceScreenState extends State<LayoutChoiceScreen> {
  bool? _picked;

  Future<void> _choose(bool simple) async {
    if (_picked != null) return;
    setState(() => _picked = simple);
    await Future<void>.delayed(const Duration(milliseconds: 350)); // long enough to see the card light up
    await LayoutChoice.choose(simple);
    if (mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final wide = p.isTv || p.size.width > p.size.height;
    final cards = [
      _LayoutCard(simple: true, picked: _picked == true, dimmed: _picked == false, autofocus: true, onTap: () => _choose(true)),
      _LayoutCard(simple: false, picked: _picked == false, dimmed: _picked == true, onTap: () => _choose(false)),
    ];
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: p.safeX),
          child: Padding(
            padding: EdgeInsets.all(rem),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('How do you want PEK TV to look?', style: TextStyle(fontSize: 1.7 * rem, fontWeight: FontWeight.w800, height: 1.15)).animate().fadeIn(duration: 350.ms).slideY(begin: 0.2, end: 0, duration: 450.ms, curve: Curves.easeOutCubic),
              SizedBox(height: 0.5 * rem),
              Text('Pick one. You can change it any time in Settings, under Mode.', style: TextStyle(color: t.textMuted, fontSize: rem, height: 1.4)),
              SizedBox(height: 1.25 * rem),
              Expanded(
                child: wide
                    ? Row(children: [Expanded(child: cards[0]), SizedBox(width: rem), Expanded(child: cards[1])])
                    : Column(children: [Expanded(child: cards[0]), SizedBox(height: 0.75 * rem), Expanded(child: cards[1])]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _LayoutCard extends StatelessWidget {
  const _LayoutCard({required this.simple, required this.picked, required this.dimmed, required this.onTap, this.autofocus = false});
  final bool simple;
  final bool picked;
  final bool dimmed;
  final bool autofocus;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final wide = p.isTv || p.size.width > p.size.height;
    final preview = Expanded(child: Padding(padding: EdgeInsets.all(0.25 * rem), child: _Preview(simple: simple)));
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(simple ? 'Simple' : 'Advanced', style: TextStyle(fontSize: 1.3 * rem, fontWeight: FontWeight.w800)),
      SizedBox(height: 0.25 * rem),
      Text(
        simple ? 'A big banner, rows of movie and show cards and trailers, like a streaming app. Pick one and press Play.' : 'The full PEK TV: dashboard, filters, plugins, music and every setting.',
        style: TextStyle(color: t.textMuted, fontSize: 0.9 * rem, height: 1.35),
      ),
    ]);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 250),
      opacity: dimmed ? 0.35 : 1,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 250),
        scale: picked ? 1.03 : 1,
        child: PekFocusable(
          autofocus: autofocus,
          onTap: onTap,
          radius: 18,
          background: picked ? t.accent.withAlpha(40) : t.surface,
          borderColor: picked ? t.accent : t.border,
          padding: EdgeInsets.all(rem),
          child: Column(children: [
            preview,
            SizedBox(height: 0.75 * rem),
            Align(alignment: Alignment.centerLeft, child: text),
          ]),
        ),
      ),
    ).animate().fadeIn(delay: (simple ? 150 : 300).ms, duration: 400.ms).slideX(begin: wide ? 0.15 : 0, end: 0, duration: 450.ms, curve: Curves.easeOutCubic);
  }
}

/// A tiny drawing of each layout, made of boxes (no screenshots to keep in step with the app).
class _Preview extends StatelessWidget {
  const _Preview({required this.simple});
  final bool simple;

  @override
  Widget build(BuildContext context) {
    final t = context.pek.tokens;
    Widget box(Color c, {double r = 4}) => DecoratedBox(decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(r)));
    final dim = t.border;
    final strong = t.accent.withAlpha(150);
    final Widget inner = simple
        ? Column(children: [
            Row(children: [SizedBox(width: 36, height: 8, child: box(strong)), const Spacer(), for (var i = 0; i < 3; i++) Padding(padding: const EdgeInsets.only(left: 6), child: SizedBox(width: 22, height: 8, child: box(dim)))]),
            const SizedBox(height: 8),
            Expanded(flex: 5, child: SizedBox.expand(child: box(t.accent.withAlpha(90), r: 8))),
            const SizedBox(height: 8),
            Expanded(flex: 3, child: Row(children: [for (var i = 0; i < 5; i++) Expanded(child: Padding(padding: const EdgeInsets.only(right: 6), child: box(dim)))])),
          ])
        : Row(children: [
            SizedBox(width: 34, child: Column(children: [for (var i = 0; i < 5; i++) Padding(padding: const EdgeInsets.only(bottom: 6), child: SizedBox(height: 14, child: box(i == 0 ? strong : dim)))])),
            const SizedBox(width: 10),
            Expanded(
              child: Column(children: [
                Expanded(child: Row(children: [for (var i = 0; i < 3; i++) Expanded(child: Padding(padding: const EdgeInsets.only(right: 6), child: box(dim)))])),
                const SizedBox(height: 6),
                Expanded(child: Row(children: [for (var i = 0; i < 3; i++) Expanded(child: Padding(padding: const EdgeInsets.only(right: 6), child: box(dim)))])),
                const SizedBox(height: 6),
                Expanded(child: Row(children: [for (var i = 0; i < 3; i++) Expanded(child: Padding(padding: const EdgeInsets.only(right: 6), child: box(i == 1 ? strong : dim)))])),
              ]),
            ),
          ]);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: t.bg, borderRadius: BorderRadius.circular(12), border: Border.all(color: t.border)),
      child: inner,
    );
  }
}

/// The last page: the PEK logo card on the standard PEK Ember look, and Sign in / Sign up / Sign in later.
///  * Sign in: a phone or tablet asks for email and password; a TV shows the 6-digit code and QR code (no typing).
///  * Sign up: a phone opens the website's sign-up page in the browser; a TV shows that page's QR code and address instead.
///  * Sign in later: straight into the app (Settings > Account has the same buttons any time).
/// Signing in hands over to "Who's watching?" (main.dart) and then the app.
class SignInScreen extends StatelessWidget {
  const SignInScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    const t = Skins.ember; // always the standard look here, whatever skin the device later uses
    final rem = p.rem;
    final tv = p.tvDevice;
    void push(Widget page) => Navigator.push<void>(context, MaterialPageRoute<void>(builder: (_) => page));
    return Scaffold(
      backgroundColor: t.bg,
      body: Container(
        decoration: BoxDecoration(gradient: RadialGradient(center: const Alignment(0, -0.6), radius: 1.1, colors: [t.accent.withAlpha(45), t.bg])),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(horizontal: rem + p.safeX, vertical: rem),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 26 * rem),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: (tv ? 24 : 20) * rem),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Image.asset('assets/brand/pek_logo.png', fit: BoxFit.cover, errorBuilder: (_, __, ___) => SizedBox(height: 6 * rem, child: Center(child: Text('PEK TV', style: TextStyle(color: t.accent, fontSize: 2.5 * rem, fontWeight: FontWeight.w900))))),
                      ),
                    ),
                  ).animate().fadeIn(duration: 450.ms).scale(begin: const Offset(0.94, 0.94), end: const Offset(1, 1), duration: 500.ms, curve: Curves.easeOutCubic),
                  SizedBox(height: 1.25 * rem),
                  Text('Sign in to PEK TV', textAlign: TextAlign.center, style: TextStyle(color: t.text, fontSize: 1.7 * rem, fontWeight: FontWeight.w800)),
                  SizedBox(height: 0.5 * rem),
                  Text(
                    'Keep your watch history and resume points on every device, and give everyone at home their own profile.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.textMuted, fontSize: rem, height: 1.4),
                  ),
                  SizedBox(height: 1.5 * rem),
                  PekButton(label: tv ? 'Sign in with your phone' : 'Sign in', primary: true, autofocus: true, onTap: () => push(tv ? const LinkScreen() : const AccountScreen(mode: AccountMode.signIn))),
                  SizedBox(height: 0.6 * rem),
                  PekButton(label: 'Sign up', onTap: () {
                    if (tv) {
                      push(const SignUpQrScreen());
                    } else {
                      openSignUpPage(context);
                    }
                  }),
                  SizedBox(height: 0.9 * rem),
                  Center(child: PekButton(compact: true, shrink: true, label: 'Sign in later', onTap: SignInStep.finish)),
                ]).animate().fadeIn(delay: 150.ms, duration: 400.ms).slideY(begin: 0.08, end: 0, duration: 450.ms, curve: Curves.easeOutCubic),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// TV: "Sign up" cannot open a browser, so the website's sign-up page is shown as a QR code and an address to type.
class SignUpQrScreen extends StatelessWidget {
  const SignUpQrScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final site = Cloud.siteUrl.replaceFirst('https://', '');
    final steps = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('1. Scan the QR code with your phone, or open', style: TextStyle(color: t.textMuted, fontSize: rem)),
      Text(site, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 1.05 * rem)),
      SizedBox(height: 0.5 * rem),
      Text('2. Create your account on that page.', style: TextStyle(color: t.textMuted, fontSize: rem)),
      SizedBox(height: 0.5 * rem),
      Text('3. Come back here and sign in with your phone.', style: TextStyle(color: t.textMuted, fontSize: rem)),
    ]);
    return SubScreen(
      title: 'Create your account',
      body: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 46 * rem;
        final room = box.maxWidth - 2 * rem;
        final qrSize = (wide ? 15.0 * rem : 13.0 * rem) < room ? (wide ? 15.0 * rem : 13.0 * rem) : room;
        final qr = QrImageView(data: Cloud.signUpPage, size: qrSize, backgroundColor: Colors.white, padding: EdgeInsets.all(0.7 * rem));
        return ListView(padding: p.pagePad, children: [
          if (wide)
            Row(crossAxisAlignment: CrossAxisAlignment.center, children: [qr, SizedBox(width: 2.5 * rem), Expanded(child: steps)])
          else ...[
            Center(child: qr),
            SizedBox(height: 1.2 * rem),
            steps,
          ],
          SizedBox(height: 1.2 * rem),
          Wrap(spacing: 8, runSpacing: 8, children: [
            PekButton(label: 'I have an account', primary: true, autofocus: true, onTap: () => Navigator.pushReplacement<void, void>(context, MaterialPageRoute<void>(builder: (_) => const LinkScreen()))),
            PekButton(label: 'Back', onTap: () => Navigator.maybePop(context)),
          ]),
        ]);
      }),
    );
  }
}
