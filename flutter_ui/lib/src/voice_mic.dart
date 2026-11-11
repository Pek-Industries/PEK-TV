import 'dart:async';

import 'package:flutter/material.dart';

import 'tokens.dart';
import 'voice.dart';
import 'voice_match.dart';
import 'voice_models.dart';
import 'voice_overlay.dart';
import 'widgets.dart' show PekFocusable;

/// The mic: a round icon button that sits beside the search box (like YouTube). Tap: the screen dims ([VoiceOverlay]), it
/// listens, the words appear, then it acts on them through [onIntent]. If something is missing ("play season 1 episode 2":
/// which series?) it asks out loud and on screen, listens again, and puts the answer together with the first request.
/// Where the phone has its own speech recognizer (the one behind the Google keyboard's mic) the words appear live as you speak.
/// Otherwise the bundled model (Moonshine) hears the whole sentence first, and the words are revealed right after you stop.
///
/// [supports] lists what the screen can act on. Anything else it understood is reported instead of being dropped silently.
class VoiceMic extends StatefulWidget {
  const VoiceMic({
    super.key,
    required this.onIntent,
    this.speakBack = true,
    this.supports = const {VoiceKind.play, VoiceKind.search},
    this.bias = const [],
    this.titles,
    this.inPlayer = false,
    this.button,
    this.onStart,
    this.onEnd,
  });
  final void Function(VoiceIntent intent) onIntent;
  final bool speakBack;
  final Set<VoiceKind> supports;

  /// Titles worth expecting (library names): the phone's recognizer hears them better. Optional.
  final List<String> bias;

  /// The titles in the library tab this mic belongs to (read when the mic is tapped). What was heard is matched against them
  /// ("the beer" -> "The Bear"), and they are given to the phone's recognizer as words to expect.
  final List<String> Function()? titles;

  /// The mic sits in the player: a bare "play" / "resume" means unpause there.
  final bool inPlayer;

  /// Draws the button instead of the round one; it gets the function to call when pressed (the player uses its own button style).
  final Widget Function(VoidCallback onTap)? button;

  /// Listening has started / the whole thing is over (the player pauses the film meanwhile, so the mic does not hear it).
  final VoidCallback? onStart, onEnd;

  @override
  State<VoiceMic> createState() => _VoiceMicState();
}

class _VoiceMicState extends State<VoiceMic> {
  bool _working = false;
  bool _open = false; // the overlay is on screen

  @override
  void initState() {
    super.initState();
    VoiceModels.ensureBundled(); // copies the bundled model out of the APK now (first run only), so the first tap does not wait
  }

  String _where(VoiceIntent i) => [if (i.season > 0) 'season ${i.season}', if (i.episode > 0) 'episode ${i.episode}'].join(' ');

  String _describe(VoiceIntent i) {
    final w = _where(i).isEmpty ? '' : ' (${_where(i)})';
    final from = i.secs > 0 ? ' from ${voiceTime(i.secs)}' : '';
    return switch (i.kind) {
      VoiceKind.play => i.episode > 0 ? 'Playing "${i.text}"$w$from' : 'Searching for "${i.text}"$w \u2014 pick it to play',
      VoiceKind.search => 'Searching for "${i.text}"$w',
      VoiceKind.open => 'Open ${i.text}',
      VoiceKind.resume => widget.inPlayer ? 'Playing' : 'Resume watching',
      VoiceKind.seek => 'Skipping to ${voiceTime(i.secs)}',
      VoiceKind.skip => '${i.secs < 0 ? 'Back' : 'Forward'} ${voiceSpan(i.secs)}',
      VoiceKind.pause => 'Paused',
      VoiceKind.scene => 'Finding the scene ${i.scene}',
      VoiceKind.unknown => '',
    };
  }

  /// What to say when a scene was asked for: finding it needs the online assistant. (When that is built, only the online
  /// branch changes.)
  Future<String> _sceneNote() async => await Voice.online() ? "Finding a scene isn't available yet" : 'Finding a scene needs an internet connection';

  String _question(VoiceIntent i) {
    if (i.season > 0 || i.episode > 0) return 'What series are you referring to?';
    return i.kind == VoiceKind.play ? 'What would you like to watch?' : 'What should I search for?';
  }

  /// The library's own spelling of a title that was heard a little wrong; the intent is returned unchanged when nothing fits well.
  VoiceIntent _fit(VoiceIntent i) {
    final get = widget.titles;
    if (get == null || i.text.isEmpty) return i;
    final lib = get();
    if (lib.isEmpty) return i;
    final a = bestTitle(i.text, lib);
    final b = i.full != i.text ? bestTitle(i.full, lib) : null; // a movie called "Star Wars Episode 1" is matched as said
    final m = (b != null && (a == null || b.score > a.score)) ? b : a;
    if (m == null) return i;
    return i.copyWith(text: m.title, full: m.title);
  }

  List<String> _bias() {
    if (widget.bias.isNotEmpty) return widget.bias;
    final get = widget.titles;
    if (get == null) return const [];
    final all = get();
    return all.length > 200 ? all.sublist(0, 200) : all;
  }

  /// One round of listening: shows the words as they come, returns what was said (null = nothing heard, or dismissed).
  Future<String?> _hear(VoiceUi ui) async {
    var live = false; // words already shown while speaking
    final heard = await Voice.instance.listen(
      bias: _bias(),
      onLevel: (l) => ui.level.value = l,
      onPartial: (t) {
        if (!_open || t.trim().isEmpty) return;
        live = true;
        ui.words.value = t.trim().split(RegExp(r'\s+'));
      },
    );
    if (!_open) return null; // dismissed
    ui.level.value = 0;
    if (heard.isEmpty) {
      ui.phase.value = VoicePhase.done;
      ui.status.value = "I didn't catch that \u2014 tap the mic and speak right away";
      if (widget.speakBack) await Voice.instance.speak("I didn't catch that.");
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      return null;
    }
    ui.phase.value = VoicePhase.thinking;
    final ws = heard.trim().split(RegExp(r'\s+'));
    if (live) {
      ui.words.value = ws; // the final wording, in place of the last live guess
    } else {
      for (var i = 1; i <= ws.length; i++) {
        if (!_open) return null;
        ui.words.value = ws.sublist(0, i);
        await Future<void>.delayed(const Duration(milliseconds: 110));
      }
    }
    return heard;
  }

  Future<void> _tap() async {
    if (_working) return;
    _working = true;
    final ui = VoiceUi();
    final nav = Navigator.of(context, rootNavigator: true);
    _open = true;
    widget.onStart?.call();
    // The overlay is dismissed with Back or a tap outside: that cancels the recording.
    unawaited(showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Voice search',
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => VoiceOverlay(ui: ui, onFinish: Voice.instance.finish),
    ).then((_) {
      if (_open) {
        _open = false;
        Voice.instance.cancel();
      }
    }));
    try {
      final heard = await _hear(ui);
      if (heard == null) return;
      var intent = parseVoice(heard, player: widget.inPlayer);

      // Something is missing ("play season 1 episode 2"): ask, listen again, put the two together.
      if (intent.missingTitle) {
        final q = _question(intent);
        ui.words.value = const [];
        ui.status.value = '';
        ui.prompt.value = q;
        ui.phase.value = VoicePhase.listening;
        if (widget.speakBack) await Voice.instance.speak(q); // waits until it has finished talking, so it does not hear itself
        if (!_open) return;
        final answer = await _hear(ui);
        if (answer == null) return;
        if (RegExp(r"^(never ?mind|cancel|stop|forget it)\b").hasMatch(answer.toLowerCase())) return;
        final a = splitSeasonEpisode(titleFromAnswer(answer));
        if (a.title.isEmpty) {
          ui.phase.value = VoicePhase.done;
          ui.status.value = "I still don't know the title \u2014 try again";
          await Future<void>.delayed(const Duration(milliseconds: 1800));
          return;
        }
        intent = intent.copyWith(text: a.title, season: intent.season > 0 ? intent.season : a.season, episode: intent.episode > 0 ? intent.episode : a.episode, full: answer);
        ui.prompt.value = '';
      }

      intent = _fit(intent); // "the beer" -> "The Bear"
      ui.phase.value = VoicePhase.done;
      // A scene ("skip to where the guy gets slapped") needs the online assistant: say so instead of guessing.
      String? sceneNote;
      if (intent.needsOnline) sceneNote = await _sceneNote();
      if (!_open) return;
      if (intent.kind == VoiceKind.scene) {
        ui.status.value = sceneNote ?? '';
        await Future<void>.delayed(const Duration(milliseconds: 2200));
        return;
      }
      if (!widget.supports.contains(intent.kind)) {
        ui.status.value = "I understood that, but I can't ${intent.kind == VoiceKind.open ? 'open pages' : 'do that'} from here yet";
        await Future<void>.delayed(const Duration(milliseconds: 1800));
        return;
      }
      ui.status.value = _describe(intent) + (sceneNote == null ? '' : ' \u2014 ${sceneNote.toLowerCase()}');
      await Future<void>.delayed(Duration(milliseconds: sceneNote == null ? 700 : 2000)); // let the words be read before the screen changes
      if (!_open) return;
      // Close the overlay first: the action may open a screen of its own (the player), and the pop below must not take that one.
      _open = false;
      if (nav.mounted) nav.pop();
      widget.onIntent(intent);
      if (widget.speakBack && intent.kind != VoiceKind.unknown) {
        final w = _where(intent).isEmpty ? '' : ', ${_where(intent)}';
        unawaited(Voice.instance.speak(switch (intent.kind) {
          VoiceKind.play => 'Looking for ${intent.text}$w.',
          VoiceKind.search => 'Searching for ${intent.text}$w.',
          VoiceKind.open => 'Opening ${intent.text}.',
          VoiceKind.resume => 'Resuming.',
          VoiceKind.seek || VoiceKind.skip || VoiceKind.pause || VoiceKind.scene || VoiceKind.unknown => '',
        }));
      }
    } on VoiceException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Voice search is not working on this device.');
    } finally {
      if (_open) {
        _open = false;
        if (nav.mounted) nav.pop();
      }
      _working = false;
      ui.dispose();
      widget.onEnd?.call();
    }
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final custom = widget.button;
    if (custom != null) return custom(_tap);
    final p = context.pek;
    final t = p.tokens;
    final size = 2.75 * p.rem; // the height of the search box next to it
    return Semantics(
      button: true,
      label: 'Voice search',
      child: PekFocusable(
        onTap: _tap,
        radius: 999,
        background: t.surface,
        borderColor: t.border,
        focusScale: p.isTv ? 1.05 : 1.0,
        minHeight: size,
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: 0.7 * p.rem),
        child: Icon(Icons.mic, color: t.text, size: 1.35 * p.rem),
      ),
    );
  }
}
