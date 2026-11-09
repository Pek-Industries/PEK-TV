import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'common.dart';
import 'mpv.dart';
import 'settings_extra.dart' show ToggleRow;
import 'tokens.dart';
import 'widgets.dart';

/// Sound settings for video and music (both play through the one shared mpv engine), like the sound menu of a TV: audio delay, volume boost, night mode, dialogue boost, bass / treble
/// (with presets) and a stereo downmix. They live in Kotlin (MpvController: saved, and applied to mpv at once), this is the
/// Dart side: the model, the shared controller, the controls (used by Settings and by the Sound panel in the player).
///
/// Audio sent untouched to a receiver (Settings > Audio output) is not decoded by the app, so these do not change it.
class AudioFx {
  const AudioFx({this.delayMs = 0, this.boost = 100, this.night = 0, this.dialogue = 0, this.bass = 0, this.treble = 0, this.downmix = false, this.eq = _flat});

  final int delayMs; // -3000..3000, positive = sound later
  final int boost; // 100..200 (%)
  final int night; // 0 off, 1 light, 2 strong
  final int dialogue; // 0 off, 1 low, 2 high
  final int bass; // -10..10 dB
  final int treble; // -10..10 dB
  final bool downmix; // surround folded down to stereo
  final List<int> eq; // ten equalizer bands, -12..12 dB, at [eqFreqs]

  static const _flat = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  static const eqLabels = ['31', '62', '125', '250', '500', '1k', '2k', '4k', '8k', '16k'];
  static const eqPresets = <(String, List<int>)>[
    ('Flat', _flat),
    ('Bass boost', [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
    ('Treble boost', [0, 0, 0, 0, 0, 0, 2, 4, 5, 6]),
    ('Rock', [5, 4, 3, 1, -1, -1, 1, 3, 4, 5]),
    ('Pop', [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2]),
    ('Jazz', [3, 2, 1, 2, -2, -2, 0, 1, 2, 3]),
    ('Classical', [4, 3, 2, 2, -1, -1, 0, 2, 3, 4]),
    ('Vocal', [-3, -2, -1, 1, 3, 3, 2, 1, 0, -1]),
    ('Electronic', [5, 4, 1, 0, -2, 2, 1, 1, 4, 5]),
  ];

  /// The equalizer preset the ten bands match right now, or null (shown as "Custom").
  String? get eqPreset {
    for (final p in eqPresets) {
      var same = true;
      for (var i = 0; i < 10; i++) {
        if (eq[i] != p.$2[i]) same = false;
      }
      if (same) return p.$1;
    }
    return null;
  }

  static int _i(dynamic v, int d) => v is num ? v.toInt() : d;

  factory AudioFx.fromJson(String json) {
    try {
      final m = jsonDecode(json);
      if (m is! Map) return const AudioFx();
      return AudioFx(
        delayMs: _i(m['delayMs'], 0).clamp(-3000, 3000),
        boost: _i(m['boost'], 100).clamp(100, 200),
        night: _i(m['night'], 0).clamp(0, 2),
        dialogue: _i(m['dialogue'], 0).clamp(0, 2),
        bass: _i(m['bass'], 0).clamp(-10, 10),
        treble: _i(m['treble'], 0).clamp(-10, 10),
        downmix: m['downmix'] == true,
        eq: m['eq'] is List && (m['eq'] as List).length == 10 ? [for (final v in m['eq'] as List) _i(v, 0).clamp(-12, 12)] : _flat,
      );
    } catch (_) {
      return const AudioFx();
    }
  }

  @override
  bool operator ==(Object other) => other is AudioFx && toJson() == other.toJson();
  @override
  int get hashCode => toJson().hashCode;

  String toJson() => jsonEncode({'delayMs': delayMs, 'boost': boost, 'night': night, 'dialogue': dialogue, 'bass': bass, 'treble': treble, 'downmix': downmix, 'eq': eq});

  AudioFx copyWith({int? delayMs, int? boost, int? night, int? dialogue, int? bass, int? treble, bool? downmix, List<int>? eq}) => AudioFx(
        delayMs: (delayMs ?? this.delayMs).clamp(-3000, 3000),
        boost: (boost ?? this.boost).clamp(100, 200),
        night: night ?? this.night,
        dialogue: dialogue ?? this.dialogue,
        bass: (bass ?? this.bass).clamp(-10, 10),
        treble: (treble ?? this.treble).clamp(-10, 10),
        downmix: downmix ?? this.downmix,
        eq: eq ?? this.eq,
      );

  /// A preset sets bass, treble and dialogue boost only; delay, boost, night mode and downmix stay as they are.
  static const presets = <(String, int, int, int)>[
    // name, bass, treble, dialogue
    ('Flat', 0, 0, 0),
    ('Movie', 3, 2, 0),
    ('Music', 4, 3, 0),
    ('Speech', -2, 3, 1),
  ];

  AudioFx withPreset(String name) {
    for (final p in presets) {
      if (p.$1 == name) return copyWith(bass: p.$2, treble: p.$3, dialogue: p.$4);
    }
    return this;
  }

  /// The preset the equalizer matches right now, or null (shown as "Custom").
  String? get preset {
    for (final p in presets) {
      if (bass == p.$2 && treble == p.$3 && dialogue == p.$4) return p.$1;
    }
    return null;
  }
}

class AudioFxController {
  AudioFxController._();
  static final AudioFxController instance = AudioFxController._();

  final ValueNotifier<AudioFx> value = ValueNotifier(const AudioFx());
  bool _loaded = false;
  Timer? _send;

  Future<void> load() async {
    if (_loaded) return;
    try {
      value.value = AudioFx.fromJson(await PekOutput.audioFxJson());
      _loaded = true;
    } catch (_) {
      // the player is not ready (or this host has none): the defaults stay, and the next load tries again
    }
  }

  /// Shows the change at once and sends it on a moment later, so holding + / - does not flood the player.
  void update(AudioFx fx) {
    value.value = fx;
    _send?.cancel();
    _send = Timer(const Duration(milliseconds: 150), () {
      unawaited(PekOutput.setAudioFx(fx.toJson()).catchError((_) {}));
    });
  }
}

// ====================================================================== the controls

class AudioFxControls extends StatefulWidget {
  const AudioFxControls({super.key});
  @override
  State<AudioFxControls> createState() => _AudioFxControlsState();
}

class _AudioFxControlsState extends State<AudioFxControls> {
  final _c = AudioFxController.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_c.load());
  }

  static const _night = ['Off', 'Light', 'Strong'];
  static const _dialogue = ['Off', 'Low', 'High'];

  String _db(int v) => v > 0 ? '+$v dB' : '$v dB';
  String _ms(int v) => v > 0 ? '+$v ms' : '$v ms';

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AudioFx>(
      valueListenable: _c.value,
      builder: (context, fx, _) {
        void set(AudioFx n) => _c.update(n);
        final preset = fx.preset;
        final presetNames = [for (final p in AudioFx.presets) p.$1];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListRow(
              title: 'Equalizer',
              subtitle: 'Ten bands from deep bass to treble, with presets',
              trailing: Text(fx.eqPreset ?? 'Custom', style: TextStyle(color: context.pek.tokens.accent, fontWeight: FontWeight.w600)),
              onTap: () => unawaited(showEqualizerPanel(context)),
            ),
            ListRow(
              title: 'Sound preset',
              subtitle: 'Bass, treble and dialogue together',
              trailing: Text(preset ?? 'Custom', style: TextStyle(color: context.pek.tokens.accent, fontWeight: FontWeight.w600)),
              onTap: () => set(fx.withPreset(presetNames[((preset == null ? -1 : presetNames.indexOf(preset)) + 1) % presetNames.length])),
            ),
            _StepRow(
              title: 'Volume boost',
              subtitle: 'Louder than 100% for quiet files. Very loud scenes may distort.',
              value: '${fx.boost}%',
              onMinus: fx.boost > 100 ? () => set(fx.copyWith(boost: fx.boost - 10)) : null,
              onPlus: fx.boost < 200 ? () => set(fx.copyWith(boost: fx.boost + 10)) : null,
              onReset: () => set(fx.copyWith(boost: 100)),
            ),
            ListRow(
              title: 'Night mode',
              subtitle: 'Evens out loud scenes and quiet dialogue',
              trailing: Text(_night[fx.night], style: TextStyle(color: context.pek.tokens.accent, fontWeight: FontWeight.w600)),
              onTap: () => set(fx.copyWith(night: (fx.night + 1) % 3)),
            ),
            ListRow(
              title: 'Dialogue boost',
              subtitle: 'Makes voices clearer',
              trailing: Text(_dialogue[fx.dialogue], style: TextStyle(color: context.pek.tokens.accent, fontWeight: FontWeight.w600)),
              onTap: () => set(fx.copyWith(dialogue: (fx.dialogue + 1) % 3)),
            ),
            _StepRow(
              title: 'Bass',
              value: _db(fx.bass),
              onMinus: fx.bass > -10 ? () => set(fx.copyWith(bass: fx.bass - 1)) : null,
              onPlus: fx.bass < 10 ? () => set(fx.copyWith(bass: fx.bass + 1)) : null,
              onReset: () => set(fx.copyWith(bass: 0)),
            ),
            _StepRow(
              title: 'Treble',
              value: _db(fx.treble),
              onMinus: fx.treble > -10 ? () => set(fx.copyWith(treble: fx.treble - 1)) : null,
              onPlus: fx.treble < 10 ? () => set(fx.copyWith(treble: fx.treble + 1)) : null,
              onReset: () => set(fx.copyWith(treble: 0)),
            ),
            _StepRow(
              title: 'Audio delay',
              subtitle: 'Plus = sound later (picture ahead of the voices), minus = sound earlier. Helps with Bluetooth lag.',
              value: _ms(fx.delayMs),
              onMinus: fx.delayMs > -3000 ? () => set(fx.copyWith(delayMs: fx.delayMs - 50)) : null,
              onPlus: fx.delayMs < 3000 ? () => set(fx.copyWith(delayMs: fx.delayMs + 50)) : null,
              onReset: () => set(fx.copyWith(delayMs: 0)),
            ),
            ToggleRow(
              title: 'Stereo downmix',
              subtitle: 'Folds 5.1 / 7.1 sound down to two speakers or headphones, keeping the voices audible',
              on: fx.downmix,
              onTap: () => set(fx.copyWith(downmix: !fx.downmix)),
            ),
            ListRow(
              title: 'Reset sound settings',
              onTap: fx == const AudioFx() ? null : () => set(const AudioFx()),
            ),
          ],
        );
      },
    );
  }
}

/// A row with a value and - / + buttons. On a touch screen the two buttons are pressed. On a remote the whole row is one focus
/// stop (the small buttons at the far right used to be skipped by the D-pad, so Volume boost could not be reached): Left / Right
/// change the value (hold to keep going), OK steps it up and, at the top, back to [onReset]'s value. At either end of the range
/// a fresh Left / Right press leaves the row as usual, so focus is never trapped; a held key just stops at the end.
class _StepRow extends StatelessWidget {
  const _StepRow({required this.title, this.subtitle = '', required this.value, required this.onMinus, required this.onPlus, this.onReset});
  final String title, subtitle, value;
  final VoidCallback? onMinus, onPlus;

  /// What OK does when the value is already at its top (back to the normal setting).
  final VoidCallback? onReset;

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final left = k == LogicalKeyboardKey.arrowLeft;
    if (!left && k != LogicalKeyboardKey.arrowRight) return KeyEventResult.ignored;
    final step = left ? onMinus : onPlus;
    if (step == null) return e is KeyDownEvent ? KeyEventResult.ignored : KeyEventResult.handled;
    step();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final rem = p.rem;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _key,
      child: ListRow(
        title: title,
        subtitle: subtitle,
        onTap: onPlus ?? onReset,
        // The buttons are for touch; ExcludeFocus keeps them out of the D-pad's way (the row is the stop).
        trailing: ExcludeFocus(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _StepButton(icon: Icons.remove, onTap: onMinus),
            SizedBox(width: 5.2 * rem, child: Text(value, textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w600, fontSize: rem, fontFeatures: const [FontFeature.tabularFigures()]))),
            _StepButton(icon: Icons.add, onTap: onPlus),
          ]),
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.pek.tokens;
    return PekFocusable(
      enabled: onTap != null,
      onTap: onTap,
      radius: 20,
      padding: const EdgeInsets.all(9),
      child: Icon(icon, size: 22, color: onTap == null ? t.textMuted.withAlpha(90) : t.text),
    );
  }
}

// ====================================================================== Settings > Playback > Sound

class AudioFxSection extends StatelessWidget {
  const AudioFxSection({super.key});
  @override
  Widget build(BuildContext context) {
    return const Section(
      title: 'Sound',
      hint: 'Like the sound menu of a TV, for videos and music. The same controls are in the players (the speaker button) so you can change them while something plays. '
          'They do not change audio sent untouched to a receiver (Settings > Audio output).',
      children: [AudioFxControls()],
    );
  }
}

// ====================================================================== the Sound panel in the player

/// Opens the controls over the bottom of the screen without dimming the picture, so the change can be seen and heard as it is made.
/// The video keeps playing underneath.
Future<void> showAudioFxPanel(BuildContext context) {
  final p = context.pek;
  final t = p.tokens;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    barrierColor: Colors.transparent,
    backgroundColor: Colors.transparent,
    builder: (c) {
      final h = MediaQuery.sizeOf(c).height;
      return SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 560, maxHeight: h * 0.66),
            child: Material(
              color: t.bgElevated.withAlpha(240),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
              clipBehavior: Clip.antiAlias,
              child: DefaultTextStyle.merge(
                style: TextStyle(color: t.text),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(1.2 * p.rem, 0.9 * p.rem, 0.6 * p.rem, 0.2 * p.rem),
                      child: Row(children: [
                        Expanded(child: Text('Sound', style: TextStyle(fontSize: 1.15 * p.rem, fontWeight: FontWeight.w700))),
                        PekButton(label: 'Done', compact: true, autofocus: true, onTap: () => Navigator.pop(c)),
                      ]),
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(0.7 * p.rem, 0, 0.7 * p.rem, 1 * p.rem),
                        child: const AudioFxControls(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

// ====================================================================== the equalizer

/// One band: a vertical slider. Touch: drag it. Remote / keyboard: OK picks it up (the ring turns solid), Up / Down change the gain,
/// OK or Back puts it down again; while it is not picked up, Up / Down move around the screen as usual and Left / Right go to the next band.
class _EqBand extends StatefulWidget {
  const _EqBand({required this.label, required this.value, required this.height, required this.onChanged});
  final String label;
  final int value;
  final double height;
  final ValueChanged<int> onChanged;

  @override
  State<_EqBand> createState() => _EqBandState();
}

class _EqBandState extends State<_EqBand> {
  final _node = FocusNode();
  bool _focused = false;
  bool _editing = false;

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode n, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final ok = k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter || k == LogicalKeyboardKey.gameButtonA;
    if (ok) {
      if (e is KeyDownEvent) setState(() => _editing = !_editing);
      return KeyEventResult.handled;
    }
    if (_editing) {
      if (k == LogicalKeyboardKey.arrowUp) {
        widget.onChanged(widget.value + 1);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowDown) {
        widget.onChanged(widget.value - 1);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape) {
        if (e is KeyDownEvent) setState(() => _editing = false);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _drag(double dy) {
    const thumb = 22.0;
    final track = widget.height - thumb;
    final f = ((dy - thumb / 2) / track).clamp(0.0, 1.0);
    widget.onChanged((12 - f * 24).round());
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    const thumb = 22.0;
    final h = widget.height;
    final v = widget.value.clamp(-12, 12);
    final track = h - thumb;
    final thumbTop = (12 - v) / 24 * track;
    final mid = h / 2;
    final thumbMid = thumbTop + thumb / 2;
    return Focus(
      focusNode: _node,
      onKeyEvent: _key,
      onFocusChange: (f) => setState(() {
        _focused = f;
        if (!f) _editing = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _node.requestFocus(),
        onVerticalDragStart: (d) => _drag(d.localPosition.dy),
        onVerticalDragUpdate: (d) => _drag(d.localPosition.dy),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: _focused ? t.surfaceFocused : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _editing ? t.accent : (_focused ? t.borderFocus : Colors.transparent), width: _editing ? 2.5 : 1.5),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(v > 0 ? '+$v' : '$v', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: v == 0 ? t.textMuted : t.accent, fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(height: 4),
            SizedBox(
              height: h,
              width: 34,
              child: Stack(clipBehavior: Clip.none, children: [
                Positioned(left: 16, top: 0, bottom: 0, width: 2, child: ColoredBox(color: t.border)),
                Positioned(left: 16, top: v >= 0 ? thumbMid : mid, height: (thumbMid - mid).abs(), width: 2, child: ColoredBox(color: t.accent)),
                Positioned(left: 6, right: 6, top: mid - 0.5, height: 1, child: ColoredBox(color: t.textMuted.withAlpha(120))),
                Positioned(left: 6, top: thumbTop, width: thumb, height: thumb, child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: _focused ? t.accent : t.text, boxShadow: [BoxShadow(color: t.shadow, blurRadius: 4)]))),
              ]),
            ),
            const SizedBox(height: 4),
            Text(widget.label, style: TextStyle(fontSize: 11.5, color: _focused ? t.text : t.textMuted)),
          ]),
        ),
      ),
    );
  }
}

class _EqualizerBody extends StatelessWidget {
  const _EqualizerBody();

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final c = AudioFxController.instance;
    final bandH = (MediaQuery.sizeOf(context).height * 0.28).clamp(110.0, 220.0);
    return ValueListenableBuilder<AudioFx>(
      valueListenable: c.value,
      builder: (context, fx, _) {
        final names = [for (final e in AudioFx.eqPresets) e.$1];
        final cur = fx.eqPreset;
        final next = names[((cur == null ? -1 : names.indexOf(cur)) + 1) % names.length];
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListRow(
            title: 'Preset',
            subtitle: 'OK for the next one',
            trailing: Text(cur ?? 'Custom', style: TextStyle(color: t.accent, fontWeight: FontWeight.w600)),
            onTap: () => c.update(fx.copyWith(eq: [for (final e in AudioFx.eqPresets) if (e.$1 == next) ...e.$2])),
          ),
          Padding(
            padding: EdgeInsets.symmetric(vertical: 0.4 * p.rem),
            child: Row(children: [
              for (var i = 0; i < 10; i++)
                Expanded(
                  child: _EqBand(
                    label: AudioFx.eqLabels[i],
                    value: fx.eq[i],
                    height: bandH,
                    onChanged: (g) {
                      final eq = List<int>.from(fx.eq);
                      eq[i] = g.clamp(-12, 12);
                      c.update(fx.copyWith(eq: eq));
                    },
                  ),
                ),
            ]),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 0.5 * p.rem),
            child: Text(
              'Drag a band, or on a remote: OK to pick a band up, Up / Down to change it, OK again to put it down. Boosted bands lower the overall level a little to avoid distortion; Volume boost gets it back.',
              style: TextStyle(color: t.textMuted, fontSize: 0.8 * p.rem),
            ),
          ),
          ListRow(title: 'Flatten equalizer', onTap: fx.eqPreset == 'Flat' ? null : () => c.update(fx.copyWith(eq: AudioFx._flat))),
        ]);
      },
    );
  }
}

/// The ten-band equalizer, over the bottom of the screen without dimming the picture / cover: what is playing carries on underneath.
Future<void> showEqualizerPanel(BuildContext context) {
  unawaited(AudioFxController.instance.load());
  final p = context.pek;
  final t = p.tokens;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    barrierColor: Colors.transparent,
    backgroundColor: Colors.transparent,
    builder: (c) {
      final h = MediaQuery.sizeOf(c).height;
      return SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 680, maxHeight: h * 0.85),
            child: Material(
              color: t.bgElevated.withAlpha(245),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
              clipBehavior: Clip.antiAlias,
              child: DefaultTextStyle.merge(
                style: TextStyle(color: t.text),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(1.2 * p.rem, 0.9 * p.rem, 0.6 * p.rem, 0.2 * p.rem),
                    child: Row(children: [
                      Expanded(child: Text('Equalizer', style: TextStyle(fontSize: 1.15 * p.rem, fontWeight: FontWeight.w700))),
                      PekButton(label: 'Done', compact: true, autofocus: true, onTap: () => Navigator.pop(c)),
                    ]),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(0.5 * p.rem, 0, 0.5 * p.rem, 1 * p.rem),
                      child: const _EqualizerBody(),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
    },
  );
}
