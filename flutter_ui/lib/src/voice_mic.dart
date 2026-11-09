import 'package:flutter/material.dart';

import 'voice.dart';
import 'voice_models.dart';
import 'widgets.dart' show PekButton;

/// The mic button. First tap: asks before downloading the voice models (from Cloudflare, not bundled). After that:
/// listen -> understand -> [onIntent]. Says a short answer out loud when [speakBack] is on.
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

  void _say(String s) {
    if (mounted) setState(() => _label = s);
  }

  Future<bool> _confirmDownload() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Download voice?'),
        content: const Text('Voice search and the spoken replies need a one-time download. It is stored on this device and can be deleted in Settings.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
          TextButton(autofocus: true, onPressed: () => Navigator.pop(c, true), child: const Text('Download')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _tap() async {
    if (_working) {
      await Voice.instance.cancel();
      return;
    }
    setState(() => _working = true);
    try {
      if (!await VoiceModels.ready()) {
        if (!await _confirmDownload()) return;
        _say('Downloading 0%');
        await VoiceModels.download(onProgress: (p) => _say('Downloading ${(p * 100).round()}%'));
      }
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
    } on VoiceDownloadException catch (e) {
      _toast(e.message);
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
