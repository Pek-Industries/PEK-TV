import 'dart:async';

import 'package:flutter/material.dart';

import 'voice.dart';
import 'voice_models.dart';
import 'voice_overlay.dart';
import 'widgets.dart' show PekButton;

/// The mic button. Tap: the screen dims ([VoiceOverlay]), it listens, the words appear one by one, then it acts on them
/// through [onIntent]. The speech model is bundled, so there is no download and no wait. Says a short answer out loud when
/// [speakBack] is on and the optional spoken-reply voice has been downloaded.
///
/// The speech model (Moonshine) hears the whole sentence first, so the words are revealed smoothly right after you stop
/// talking, not while you are still speaking. Live words need a streaming model: [VoiceUi.words] already takes them one at a time.
///
/// [supports] lists what the screen can act on. Anything else it understood is reported instead of being dropped silently.
class VoiceMic extends StatefulWidget {
  const VoiceMic({
    super.key,
    required this.onIntent,
    this.speakBack = true,
    this.supports = const {VoiceKind.play, VoiceKind.search},
  });
  final void Function(VoiceIntent intent) onIntent;
  final bool speakBack;
  final Set<VoiceKind> supports;

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

  String _describe(VoiceIntent i) => switch (i.kind) {
        VoiceKind.play => 'Searching for "${i.text}" \u2014 pick it to play',
        VoiceKind.search => 'Searching for "${i.text}"',
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
      final heard = await Voice.instance.listen(onLevel: (l) => ui.level.value = (l * 8).clamp(0.0, 1.0));
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
      for (var i = 1; i <= ws.length; i++) {
        if (!_open) return;
        ui.words.value = ws.sublist(0, i);
        await Future<void>.delayed(const Duration(milliseconds: 110));
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
  Widget build(BuildContext context) => PekButton(compact: true, primary: false, label: '\uD83C\uDFA4 Voice search', onTap: _tap);
}
