import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_update.dart';
import 'store.dart';
import 'tokens.dart';
import 'widgets.dart';

/// What changed in one release, in the words the person reads.
class ReleaseNotes {
  const ReleaseNotes(this.version, this.title, this.items);

  /// The release's version without a leading "v" (the tag you push, e.g. "2.2.0").
  final String version;
  final String title;
  final List<String> items;
}

/// The "What's new" screen that comes up once after the app was updated.
///
/// HOW TO USE (every release): add a [ReleaseNotes] at the TOP of [releases] with the same version as the tag you push,
/// then push the tag. Nothing else is needed. A person who updates sees the notes once, on the first start of the new
/// version; the version they have seen is remembered on the device (not per profile). Someone who skips versions sees every
/// release in between, newest first. A release with no entry here shows nothing.
///
/// Rules the app follows:
///  * Which notes are due: every entry newer than the last version the person saw and not newer than the running app.
///    The very first time (nothing remembered yet) only the newest entry is shown, not the whole history.
///  * "-debug" / "-dev.N" suffixes are ignored, so a dev build of 2.2.0 shows the 2.2.0 notes (handy for checking the text).
///  * The version is remembered when the person presses Continue, so closing the app on the screen shows it again.
class WhatsNew {
  static const _kSeen = 'pek_whatsnew_seen';

  /// Newest first.
  static const releases = <ReleaseNotes>[
    ReleaseNotes('2.2.4', 'Phone remote, DVD support, audio controls and smarter filters', [
      'Phone remote: your Android phone can now control PEK TV on your TV. Open More > Remote on the phone for arrows, OK, Back, Home, Menu, play / pause, skip 10 seconds and volume.',
      'Typing: when a text box is open on the TV, a keyboard box appears on your phone, so searching and signing in no longer need the on-screen keyboard.',
      'Pairing: on the TV open More > Remote > Pair a phone and enter the 6-digit code on your phone. You only do this once per phone, and you can remove a phone from the same screen.',
      'Private by design: a phone that has not paired can do nothing, and the remote can be turned off on the TV at any time.',
      'DVDs: DVD images (.iso files) and ripped DVD folders now play from your library as a single movie. Physical discs are not supported yet.',
      'Multi-part movies: films split across several files now appear as a single title.',
      'Filters: Movies and TV Shows have new drop-downs to sort randomly, pick by genre or actor, and mix them with watched and unwatched.',
      'Equalizer: new audio settings let you shape the sound of your music.',
      'Video audio: the video player has its own new audio options.',
      'Playback errors: fixed a cause of the libmpv playback error, so videos that failed to start now play.',
      'Skin backups: skins are now saved to your account properly.',
    ]),
  ];

  /// The version without "-debug", "-dev.N" or "+build", for comparing.
  static String core(String v) => v.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first.split('-').first;

  /// The notes due for [installed] when the person last saw [seen] ('' = never): newest first. Pure, so it can be tested.
  static List<ReleaseNotes> select(List<ReleaseNotes> all, String installed, String seen) {
    final now = core(installed);
    final last = core(seen);
    final due = [
      for (final r in all)
        if (AppUpdate.compare(r.version, now) <= 0 && (last.isEmpty || AppUpdate.compare(r.version, last) > 0)) r,
    ]..sort((a, b) => AppUpdate.compare(b.version, a.version));
    return last.isEmpty && due.length > 1 ? [due.first] : due;
  }

  static String _installed = '';

  /// The notes to show at this start (empty = go straight on). When there is nothing to show the running version is
  /// remembered right away, so the next update compares against it.
  static Future<List<ReleaseNotes>> pending() async {
    try {
      final v = await AppUpdate.installedVersion();
      if (v == null || v.isEmpty) return const [];
      _installed = core(v);
      final seen = Store.strGet(_kSeen, scoped: false) ?? '';
      final due = select(releases, _installed, seen);
      if (due.isEmpty && seen != _installed) await markSeen();
      return due;
    } catch (_) {
      return const []; // never hold the app back
    }
  }

  /// Remembers that the person has seen the notes of the running version.
  static Future<void> markSeen() async {
    if (_installed.isEmpty) return;
    await Store.strSet(_kSeen, _installed, scoped: false);
  }
}

/// Full-screen list of what changed. One button, focused at once, so a remote's OK is enough.
class WhatsNewScreen extends StatefulWidget {
  const WhatsNewScreen({super.key, required this.notes, required this.onDone});
  final List<ReleaseNotes> notes;
  final VoidCallback onDone;

  @override
  State<WhatsNewScreen> createState() => _WhatsNewScreenState();
}

class _WhatsNewScreenState extends State<WhatsNewScreen> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Up / down on a remote scroll the list while the button keeps the focus.
  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent || !_scroll.hasClients) return KeyEventResult.ignored;
    final up = e.logicalKey == LogicalKeyboardKey.arrowUp;
    if (!up && e.logicalKey != LogicalKeyboardKey.arrowDown) return KeyEventResult.ignored;
    final to = (_scroll.offset + (up ? -120 : 120)).clamp(0.0, _scroll.position.maxScrollExtent).toDouble();
    _scroll.animateTo(to, duration: const Duration(milliseconds: 120), curve: Curves.easeOut);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final single = widget.notes.length == 1;
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: Focus(
          canRequestFocus: false,
          onKeyEvent: _key,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 34 * rem),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 1.5 * rem, vertical: rem),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.auto_awesome, size: 2.6 * rem, color: t.accent),
                    SizedBox(height: 0.8 * rem),
                    Text(
                      single ? 'What\u2019s new in PEK TV ${widget.notes.first.version}' : 'What\u2019s new in PEK TV',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 1.5 * rem, fontWeight: FontWeight.w700, color: t.text),
                    ),
                    SizedBox(height: rem),
                    Expanded(
                      child: Scrollbar(
                        controller: _scroll,
                        child: SingleChildScrollView(
                          controller: _scroll,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final r in widget.notes) ...[
                                Text(single ? r.title : '${r.version} \u00b7 ${r.title}', style: TextStyle(fontSize: 1.05 * rem, fontWeight: FontWeight.w700, color: t.accent)),
                                SizedBox(height: 0.5 * rem),
                                for (final line in r.items)
                                  Padding(
                                    padding: EdgeInsets.only(bottom: 0.5 * rem),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('\u2022  ', style: TextStyle(fontSize: 0.95 * rem, color: t.textMuted, height: 1.35)),
                                        Expanded(child: Text(line, style: TextStyle(fontSize: 0.95 * rem, color: t.text, height: 1.35))),
                                      ],
                                    ),
                                  ),
                                SizedBox(height: 0.8 * rem),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: rem),
                    PekButton(label: 'Continue', primary: true, autofocus: true, onTap: widget.onDone),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
