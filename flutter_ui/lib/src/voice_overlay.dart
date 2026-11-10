import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import 'tokens.dart';

enum VoicePhase { listening, thinking, done }

/// What the voice screen shows. [VoiceMic] writes to it; [VoiceOverlay] only draws it.
/// [words] grows one word at a time: the same widget will show live words if a streaming speech model is plugged in later.
class VoiceUi {
  final phase = ValueNotifier<VoicePhase>(VoicePhase.listening);
  final level = ValueNotifier<double>(0); // 0..1, how loud the person is right now
  final words = ValueNotifier<List<String>>(const []);
  final status = ValueNotifier<String>('');

  Listenable get all => Listenable.merge([phase, level, words, status]);

  void dispose() {
    phase.dispose();
    level.dispose();
    words.dispose();
    status.dispose();
  }
}

/// Full-screen "assistant is listening" view: the app dims, a mic orb pulses with your voice, and each word fades in as it
/// arrives. OK / Enter / a tap on the orb finishes listening early; Back (or a tap outside the orb) cancels.
class VoiceOverlay extends StatelessWidget {
  const VoiceOverlay({super.key, required this.ui, required this.onFinish});
  final VoiceUi ui;
  final VoidCallback onFinish;

  static bool _isSelect(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter || k == LogicalKeyboardKey.gameButtonA;

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    return Focus(
      autofocus: true,
      onKeyEvent: (node, e) {
        if (e is KeyDownEvent && _isSelect(e.logicalKey)) {
          onFinish();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The dim: eases in so the screen "goes quiet" like Gemini on a TV.
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOut,
              builder: (_, v, __) => ColoredBox(color: Colors.black.withValues(alpha: 0.82 * v)),
            ),
            SafeArea(
              child: ListenableBuilder(
                listenable: ui.all,
                builder: (context, _) {
                  final words = ui.words.value;
                  final listening = ui.phase.value == VoicePhase.listening;
                  final level = ui.level.value;
                  final big = TextStyle(fontSize: 2.4 * rem, height: 1.25, fontWeight: FontWeight.w500, color: Colors.white);
                  return Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: 46 * rem),
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 1.5 * rem),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              height: 11 * rem,
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: words.isEmpty
                                    ? Text(listening ? 'Listening\u2026' : '', style: big.copyWith(color: Colors.white70), textAlign: TextAlign.center)
                                    : Wrap(
                                        alignment: WrapAlignment.center,
                                        children: [for (var i = 0; i < words.length; i++) _Word(key: ValueKey(i), word: words[i], style: big, rem: rem)],
                                      ),
                              ),
                            ),
                            SizedBox(height: 1.2 * rem),
                            SizedBox(
                              height: 2.2 * rem,
                              child: Text(ui.status.value, style: TextStyle(fontSize: 1.1 * rem, color: t.accent, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
                            ),
                            SizedBox(height: 1.5 * rem),
                            GestureDetector(
                              onTap: onFinish,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 90),
                                width: (4.2 + (listening ? level : 0) * 2.2) * rem,
                                height: (4.2 + (listening ? level : 0) * 2.2) * rem,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: t.accent.withValues(alpha: listening ? 0.9 : 0.35),
                                  boxShadow: [BoxShadow(color: t.accent.withValues(alpha: 0.55), blurRadius: (1 + level * 3) * rem, spreadRadius: level * rem)],
                                ),
                                child: Icon(Icons.mic, color: Colors.white, size: 2 * rem),
                              ),
                            ),
                            SizedBox(height: 0.8 * rem),
                            Text(listening ? 'OK to finish \u00B7 Back to cancel' : '', style: TextStyle(fontSize: 0.85 * rem, color: Colors.white38)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One word: fades in and rises a little the moment it appears (keyed by its position, so it only animates once).
class _Word extends StatelessWidget {
  const _Word({super.key, required this.word, required this.style, required this.rem});
  final String word;
  final TextStyle style;
  final double rem;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        builder: (_, v, child) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, (1 - v) * 0.6 * rem), child: child)),
        child: Text('$word ', style: style),
      );
}
