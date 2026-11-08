import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'skin_layout.dart';
import 'skins.dart' show SkinJson;
import 'tokens.dart';

/// A skin colour ([SkinColor]: `#rrggbb`, `#rrggbbaa` or a palette name like `accent`) as a [Color]. What is not understood
/// becomes the palette's accent, so a bad value never makes a button invisible.
Color skinColor(String spec, PekTokens t) => switch (spec) {
      'bg' => t.bg,
      'bgElevated' => t.bgElevated,
      'surface' => t.surface,
      'surfaceFocused' => t.surfaceFocused,
      'border' => t.border,
      'borderFocus' => t.borderFocus,
      'text' => t.text,
      'textMuted' => t.textMuted,
      'accent' => t.accent,
      'accentGlow' => t.accentGlow,
      _ => SkinJson.parseColor(spec) ?? t.accent,
    };

/// Black or white text, whichever reads better on [colors] (a button the skin gave its own colours but no text colour).
Color readableOn(List<Color> colors) {
  var sum = 0.0;
  for (final c in colors) {
    // A see-through colour shows what is behind it, which is usually dark: weigh it down.
    sum += c.computeLuminance() * (0.35 + 0.65 * c.opacity);
  }
  return sum / colors.length > 0.45 ? const Color(0xFF111111) : Colors.white;
}

/// A [ButtonPaint] with its colours looked up in the palette: what a button draws. Built once per paint, per build.
class PaintLook {
  PaintLook(ButtonPaint p, PekTokens t)
      : gradient = p.hasGradient ? [for (final c in p.gradient) skinColor(c, t)] : const <Color>[],
        fill = p.hasGradient || p.fill == null ? null : skinColor(p.fill!, t),
        textColor = p.text == null ? null : skinColor(p.text!, t),
        border = p.border == null ? null : skinColor(p.border!, t),
        glow = p.glow == null ? null : skinColor(p.glow!, t),
        anim = p.anim ?? ButtonAnim.none,
        angle = p.angle ?? 0,
        seconds = p.speed ?? 4,
        always = (p.when ?? AnimWhen.always) == AnimWhen.always;

  /// Empty when the paint has no gradient.
  final List<Color> gradient;

  /// The plain colour (null when there is a gradient, or none).
  final Color? fill;
  final Color? textColor, border, glow;
  final ButtonAnim anim;
  final double angle, seconds;
  final bool always;

  /// The skin gave this button its own colours (so the app's own fill, text and focus colours step aside).
  bool get painted => gradient.isNotEmpty || fill != null;

  /// The colour has to be drawn by a [ButtonSurface] (a gradient, or a plain colour that animates) rather than as the box's fill.
  bool get surfaced => gradient.isNotEmpty || (fill != null && anim != ButtonAnim.none);

  /// The label colour: the skin's, else black / white for what the label sits on, else [fallback].
  Color label(Color fallback) => textColor ?? (painted ? readableOn(gradient.isNotEmpty ? gradient : [fill!]) : fallback);

  /// The box's own fill: nothing when a [ButtonSurface] paints it, else the skin's colour; [appFill] when the skin gave none.
  Color? boxFill(Color? appFill) => painted ? (surfaced ? Colors.transparent : fill) : appFill;

  /// The [ButtonSurface] for `PekFocusable.surface`, or null when the box's own fill is enough.
  Widget Function(bool focused)? get surface => surfaced
      ? ((focused) => ButtonSurface(colors: gradient, base: fill, angle: angle, anim: anim, seconds: seconds, always: always, focused: focused))
      : null;
}

/// The paint behind a skin's button: a gradient (that can slide and loop), a highlight that sweeps across, or a fill that gently
/// brightens and dims. Drawn by `PekFocusable.surface`, behind the button's text and inside its corners.
///
/// The animation stops when the device asks for less motion, and (like every ticker) while the screen is not showing.
class ButtonSurface extends StatefulWidget {
  const ButtonSurface({
    super.key,
    required this.colors,
    required this.anim,
    required this.focused,
    this.base,
    this.angle = 0,
    this.seconds = 4,
    this.always = true,
  });

  /// The gradient's colours (two or more), or empty for a plain [base].
  final List<Color> colors;

  /// The plain fill, used when there is no gradient.
  final Color? base;

  /// The gradient's direction in degrees: 0 = left to right, 90 = top to bottom.
  final double angle;
  final ButtonAnim anim;

  /// One loop of the animation.
  final double seconds;

  /// false = the animation only runs while the button is focused.
  final bool always;
  final bool focused;

  @override
  State<ButtonSurface> createState() => _ButtonSurfaceState();
}

class _ButtonSurfaceState extends State<ButtonSurface> with SingleTickerProviderStateMixin {
  AnimationController? _c;

  Duration get _loop => Duration(milliseconds: (widget.seconds * 1000).round().clamp(500, 20000).toInt());

  bool get _wanted => widget.anim != ButtonAnim.none && (widget.always || widget.focused) && !MediaQuery.of(context).disableAnimations;

  void _sync() {
    if (_wanted) {
      final c = _c ??= AnimationController(vsync: this, duration: _loop);
      c.duration = _loop;
      if (!c.isAnimating) c.repeat();
    } else {
      _c?.stop(); // keeps its place: a button you look away from stops where it was
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ButtonSurface old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  /// A gradient along [widget.angle] that runs corner to corner at 45 degrees and edge to edge at 0 / 90. With [shift] (0 to 1)
  /// it is moved along its own length by that fraction; at 1 it has moved exactly one repeat, so a looping gradient is seamless.
  LinearGradient _gradient(double shift, {required bool loop}) {
    final rad = widget.angle * math.pi / 180;
    final dx = math.cos(rad), dy = math.sin(rad);
    final k = 1 / math.max(dx.abs(), dy.abs());
    final ax = dx * k, ay = dy * k;
    return LinearGradient(
      begin: Alignment(-ax + 2 * ax * shift, -ay + 2 * ay * shift),
      end: Alignment(ax + 2 * ax * shift, ay + 2 * ay * shift),
      colors: loop ? [...widget.colors, widget.colors.first] : widget.colors,
      tileMode: loop ? TileMode.repeated : TileMode.clamp,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return AnimatedBuilder(
      animation: c ?? const AlwaysStoppedAnimation<double>(0),
      builder: (context, _) {
        final t = c?.value ?? 0.0;
        final hasGradient = widget.colors.length >= 2;
        final flow = widget.anim == ButtonAnim.flow && hasGradient;
        final layers = <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              color: hasGradient ? null : widget.base,
              gradient: hasGradient ? _gradient(flow ? t : 0, loop: flow) : null,
            ),
          ),
        ];
        if (widget.anim == ButtonAnim.shimmer) {
          // A soft diagonal band crosses the button in the first 45% of each loop, then rests.
          final s = (t / 0.45).clamp(0.0, 1.0).toDouble();
          final cx = -1.6 + 3.2 * s;
          layers.add(DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(cx - 0.5, -0.4),
                end: Alignment(cx + 0.5, 0.4),
                colors: const [Color(0x00FFFFFF), Color(0x59FFFFFF), Color(0x00FFFFFF)],
              ),
            ),
          ));
        } else if (widget.anim == ButtonAnim.breathe) {
          final a = 0.5 - 0.5 * math.cos(2 * math.pi * t);
          layers.add(DecoratedBox(decoration: BoxDecoration(color: Color.fromARGB((a * 70).round(), 255, 255, 255))));
        }
        // A focused button is a little brighter, whatever its colours (the focus ring is drawn by the button itself).
        if (widget.focused) layers.add(const DecoratedBox(decoration: BoxDecoration(color: Color(0x24FFFFFF))));
        return Stack(fit: StackFit.expand, children: layers);
      },
    );
  }
}
