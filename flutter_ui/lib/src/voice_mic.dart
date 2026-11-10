import 'package:flutter/material.dart';

import 'voice.dart';
import 'voice_models.dart';
import 'widgets.dart' show PekButton;

/// The mic button. Tap: listen -> understand -> [onIntent]. The speech model is bundled, so there is no download and no wait.
/// Says a short answer out loud when [speakBack] is on and the optional spoken-reply voice has been downloaded.
class VoiceMic extends StatefulWidget {
  const VoiceMic({super.key, required this.onIntent, this.speakBack = true});
  final void Function(VoiceIntent intent) onIntent;
  final bool speakBack;

  @override
  State<VoiceMic> createState() => _VoiceMicState();
}

class _VoiceMicState extends State<VoiceMic> {
  String _label = 'Voice search';
  bool _working = false;

  @override
  void initState() {
    super.initState();
    VoiceModels.ensureBundled(); // copies the bundled model out of the APK now (first run only), so the first tap does not wait
  }

  void _say(String s) {
    if (mounted) setState(() => _label = s);
  }

  Future<void> _tap() async {
    if (_working) {
      await Voice.instance.cancel();
      return;
    }
    setState(() => _working = true);
    try {
      _say('Listening\u2026');
      final heard = await Voice.instance.listen();
      if (heard.isEmpty) {
        _say('Voice search');
        if (widget.speakBack) await Voice.instance.speak("I didn't catch that.");
        return;
      }
      _say('Thinking\u2026');
      final intent = parseVoice(heard);
      widget.onIntent(intent);
      if (widget.speakBack && intent.kind != VoiceKind.unknown) {
        await Voice.instance.speak(switch (intent.kind) {
          VoiceKind.play => 'Looking for ${intent.text}.',
          VoiceKind.search => 'Searching for ${intent.text}.',
          VoiceKind.open => 'Opening ${intent.text}.',
          VoiceKind.resume => 'Resuming.',
          VoiceKind.unknown => '',
        });
      }
    } on VoiceException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Voice search is not working on this device.');
    } finally {
      _say('Voice search');
      if (mounted) setState(() => _working = false);
    }
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) => PekButton(compact: true, primary: false, label: '\uD83C\uDFA4 $_label', onTap: _tap);
}
