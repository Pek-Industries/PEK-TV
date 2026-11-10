import 'dart:async';

import 'package:flutter/material.dart';

import 'tokens.dart';
import 'voice.dart';
import 'voice_models.dart';
import 'voice_overlay.dart';
import 'widgets.dart' show PekFocusable;

/// The mic: a round icon button that sits beside the search box (like YouTube). Tap: the screen dims ([VoiceOverlay]), it listens, the words appear one by one, then it acts on them
/// through [onIntent]. The speech model is bundled, so there is no download and no wait. Says a short answer out loud when
/// [speakBack] is on and the optional spoken-reply voice has been downloaded.
///
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
  });
  final void Function(VoiceIntent intent) onIntent;
  final bool speakBack;
  final Set<VoiceKind> supports;

  /// Titles worth expecting (library names): the phone's recognizer hears them better. Optional.
  final List<String> bias;

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

  String _where(VoiceIntent i) =>
      [if (i.season > 0) 'season ${i.season}', if (i.episode > 0) 'episode ${i.episode}'].join(' ');

  String _describe(VoiceIntent i) => switch (i.kind) {
        VoiceKind.play => 'Searching for "${i.text}"${_where(i).isEmpty ? '' : ' (${_where(i)})'} \u2014 pick it to play',
        VoiceKind.search => 'Searching for "${i.text}"${_where(i).isEmpty ? '' : ' (${_where(i)})'}',
        VoiceKind.open => 'Open ${i.text}',
        VoiceKind.resume => 'Resume watching',
        VoiceKind.unknown => '',
      };

  Future<void> _tap() async {
    if (_working) return;
    _working = true;
    final ui = VoiceUi();
    final nav = Navigator.of(context, rootNavigator: true);
    _open = true;
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
      var live = false; // words already shown while speaking
      final heard = await Voice.instance.listen(
        bias: widget.bias,
        onLevel: (l) => ui.level.value = l,
        onPartial: (t) {
          if (!_open || t.trim().isEmpty) return;
          live = true;
          ui.words.value = t.trim().split(RegExp(r'\s+'));
        },
      );
      if (!_open) return; // dismissed
      ui.level.value = 0;
      if (heard.isEmpty) {
        ui.phase.value = VoicePhase.done;
        ui.status.value = "I didn't catch that \u2014 tap the mic and speak right away";
        if (widget.speakBack) await Voice.instance.speak("I didn't catch that.");
        await Future<void>.delayed(const Duration(milliseconds: 1600));
        return;
      }
      ui.phase.value = VoicePhase.thinking;
      final ws = heard.trim().split(RegExp(r'\s+'));
      if (live) {
        ui.words.value = ws; // the final wording, in place of the last live guess
      } else {
        for (var i = 1; i <= ws.length; i++) {
          if (!_open) return;
          ui.words.value = ws.sublist(0, i);
          await Future<void>.delayed(const Duration(milliseconds: 110));
        }
      }
      final intent = parseVoice(heard);
      ui.phase.value = VoicePhase.done;
      if (!widget.supports.contains(intent.kind)) {
        ui.status.value = "I understood that, but I can't ${intent.kind == VoiceKind.open ? 'open pages' : 'do that'} from here yet";
        await Future<void>.delayed(const Duration(milliseconds: 1800));
        return;
      }
      ui.status.value = _describe(intent);
      await Future<void>.delayed(const Duration(milliseconds: 700)); // let the words be read before the screen changes
      if (!_open) return;
      widget.onIntent(intent);
      if (widget.speakBack && intent.kind != VoiceKind.unknown) {
        unawaited(Voice.instance.speak(switch (intent.kind) {
          VoiceKind.play => 'Looking for ${intent.text}.',
          VoiceKind.search => 'Searching for ${intent.text}.',
          VoiceKind.open => 'Opening ${intent.text}.',
          VoiceKind.resume => 'Resuming.',
          VoiceKind.unknown => '',
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
    }
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
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
