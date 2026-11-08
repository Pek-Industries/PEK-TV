import 'dart:convert';

import 'package:flutter/material.dart';

// What a skin can rearrange, besides its colours. All of it is plain data (enums, numbers, short text and ids from a fixed list):
// no code, no callbacks, no files. A skin that sets nothing leaves the app exactly as it was.
//
// Every field is optional. `null` / empty means "leave the app's own choice", so any mix of fields is a valid skin and the
// fields never depend on each other: that is what makes the combinations free.
//
//     SkinLayout(
//       nav: NavSpec(position: NavPosition.right, show: NavShow.icons, shape: ButtonShape.pill, hide: ['duplicates']),
//       buttons: ButtonSpec(shape: ButtonShape.square, uppercase: true, weight: 800),
//       dashboard: DashSpec.of(['clock:m', 'weather', 'continue'], locked: true),
//       miniPlayer: MiniZone.top,
//     )
//
// The same thing as skin.json (`"layout": { "nav": { "position": "right" }, ... }`): see SKINS.md. Text that comes from a
// skin.json is never trusted: [SkinLayout.fromJson] drops what it does not know and clamps what is out of range, and the
// app never lets a skin hide the screens in [NavSpec.protectedIds].

/// Where the menu sits. Phones only use [top] and [bottom] (a side bar does not fit); a TV or a wide screen uses all four.
enum NavPosition { left, right, top, bottom }

/// What a menu button shows.
enum NavShow { both, icons, text }

/// Where the menu buttons sit along the bar when they do not fill it.
enum NavAlign { start, center, end }

/// The corner of a button: a pill (fully round), the skin's own corner size, or square.
enum ButtonShape { pill, rounded, square }

/// Where the mini player (the song that is playing) sits. [hidden] removes it; the full player still opens from the Music page.
enum MiniZone { top, bottom, hidden }

/// How a button's paint may move. [flow]: the gradient slides across the button and loops. [shimmer]: a soft highlight sweeps
/// across every few seconds. [breathe]: the fill gently brightens and dims.
enum ButtonAnim { none, flow, shimmer, breathe }

/// When a button's animation runs: all the time, or only while the button is focused (kinder to weak TV boxes).
enum AnimWhen { always, focus }

extension ButtonShapeRadius on ButtonShape {
  /// The corner radius in logical pixels. [skinRadius] is the skin's own `radius` token.
  double radius(double skinRadius) => switch (this) {
        ButtonShape.pill => 999,
        ButtonShape.rounded => skinRadius,
        ButtonShape.square => 0,
      };
}

T? _enumOf<T extends Enum>(List<T> values, Object? v) {
  if (v is! String) return null;
  for (final e in values) {
    if (e.name == v) return e;
  }
  return null;
}

double? _num(Object? v, double lo, double hi) => v is num ? v.toDouble().clamp(lo, hi).toDouble() : null;

String _clean(Object? v, int max) {
  final t = '${v ?? ''}'.replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ').trim();
  return t.length > max ? t.substring(0, max) : t;
}

/// The icons a skin may name (`"icons": { "movies": "fire" }`). A fixed list: a skin cannot point at a file or a URL.
class SkinIcons {
  static const map = <String, IconData>{
    'home': Icons.home_outlined,
    'movie': Icons.movie_outlined,
    'tv': Icons.tv_outlined,
    'music': Icons.music_note_outlined,
    'news': Icons.campaign_outlined,
    'search': Icons.search,
    'history': Icons.history,
    'favorite': Icons.favorite_border,
    'heart': Icons.favorite,
    'copy': Icons.content_copy,
    'help': Icons.help_outline,
    'plugin': Icons.extension_outlined,
    'settings': Icons.settings_outlined,
    'more': Icons.more_horiz,
    'star': Icons.star_border,
    'bolt': Icons.bolt,
    'fire': Icons.local_fire_department_outlined,
    'play': Icons.play_circle_outline,
    'live': Icons.live_tv_outlined,
    'folder': Icons.folder_outlined,
    'person': Icons.person_outline,
    'cloud': Icons.cloud_outlined,
    'bookmark': Icons.bookmark_border,
    'download': Icons.download_outlined,
    'game': Icons.sports_esports_outlined,
    'radio': Icons.radio,
    'podcast': Icons.podcasts,
    'explore': Icons.explore_outlined,
    'info': Icons.info_outline,
    'grid': Icons.grid_view,
    'list': Icons.view_list_outlined,
    'library': Icons.library_music_outlined,
    'camera': Icons.videocam_outlined,
    'rocket': Icons.rocket_launch_outlined,
    'palette': Icons.palette_outlined,
    'bell': Icons.notifications_none,
    'lock': Icons.lock_outline,
    'tune': Icons.tune,
    'sparkle': Icons.auto_awesome,
    'trophy': Icons.emoji_events_outlined,
  };

  static List<String> get names => map.keys.toList();

  /// The icon called [name], or null when there is none (or [name] is null).
  static IconData? byName(String? name) => name == null ? null : map[name];

  /// The icon a menu button has when the skin does not name one.
  static IconData forScreen(String id) => switch (id) {
        'dashboard' || 'mhome' => Icons.home_outlined,
        'movies' => Icons.movie_outlined,
        'shows' => Icons.tv_outlined,
        'music' => Icons.music_note_outlined,
        'updates' => Icons.campaign_outlined,
        'search' || 'msearch' => Icons.search,
        'history' => Icons.history,
        'favorites' => Icons.favorite_border,
        'duplicates' => Icons.content_copy,
        'unknown' => Icons.help_outline,
        'plugins' => Icons.extension_outlined,
        'settings' || 'msettings' => Icons.settings_outlined,
        'mlibrary' => Icons.library_music_outlined,
        'more' => Icons.more_horiz,
        _ => Icons.extension_outlined,
      };
}

/// The menu: where it sits, which buttons it has, in what order, what they are called and what they look like.
class NavSpec {
  const NavSpec({
    this.position,
    this.show,
    this.align,
    this.shape,
    this.width,
    this.gap,
    this.order = const [],
    this.hide = const [],
    this.labels = const {},
    this.icons = const {},
    this.brand,
    this.footer,
    this.paint = const ButtonPaint(),
    this.activePaint = const ButtonPaint(),
  });

  /// null = the app's own place (the left side, or the top with the Top bar layout; phones: the bottom).
  final NavPosition? position;

  /// null = a TV menu shows text, a phone tab bar shows an icon over a label.
  final NavShow? show;
  final NavAlign? align;

  /// The corner of the menu buttons. null = the app's own.
  final ButtonShape? shape;

  /// How wide a side menu is, as a multiple of the app's own width (0.7 to 1.6).
  final double? width;

  /// The space between menu buttons, as a multiple of the app's own (0 to 2).
  final double? gap;

  /// Screen ids in the order to show them. Ids you list come first, in your order; the ones you leave out follow in the app's order.
  /// Ids: dashboard, movies, shows, music, updates, search, history, favorites, duplicates, unknown, plugins, settings
  /// (music mode: mhome, msearch, mlibrary, msettings), `plugin:<folder>` for a pinned plugin screen.
  final List<String> order;

  /// Screen ids to leave out of the menu. [protectedIds] cannot be hidden.
  final List<String> hide;

  /// New names: `{'shows': 'Series'}`. At most [maxLabel] characters.
  final Map<String, String> labels;

  /// Icons by name from [SkinIcons]: `{'movies': 'fire'}`.
  final Map<String, String> icons;

  /// The name at the top of the menu. null = the app's own ("PEK TV"); '' = none.
  final String? brand;

  /// The line at the bottom of a side menu. null = the app's own ("System Online"); '' = none.
  final String? footer;

  /// Colours, gradient and animation of the menu buttons, and (on top of that) of the selected one. The same [ButtonPaint] the
  /// buttons use; empty = the app's own look.
  final ButtonPaint paint, activePaint;

  /// Screens that can never be hidden: without them the person could not reach the rest of the app.
  static const protectedIds = {'dashboard', 'settings', 'more', 'mhome', 'msettings'};

  static const maxLabel = 24, maxBrand = 24, maxFooter = 40, maxIds = 40;
  static const widthRange = (0.7, 1.6), gapRange = (0.0, 2.0);

  bool get isEmpty =>
      position == null && show == null && align == null && shape == null && width == null && gap == null && order.isEmpty && hide.isEmpty && labels.isEmpty && icons.isEmpty && brand == null && footer == null && paint.isEmpty && activePaint.isEmpty;

  /// [defaults] with [order] and [hide] applied. Screens in [keep] stay even when listed in [hide]. Never empty when [defaults] is not.
  List<String> arrange(List<String> defaults, {Set<String> keep = const {}}) {
    final have = defaults.toSet();
    final out = <String>[];
    for (final id in order) {
      if (have.contains(id) && !out.contains(id)) out.add(id);
    }
    for (final id in defaults) {
      if (!out.contains(id)) out.add(id);
    }
    final gone = hide.toSet().difference(keep);
    return [for (final id in out) if (!gone.contains(id)) id];
  }

  NavSpec copyWith({
    NavPosition? position,
    NavShow? show,
    NavAlign? align,
    ButtonShape? shape,
    double? width,
    double? gap,
    List<String>? order,
    List<String>? hide,
    Map<String, String>? labels,
    Map<String, String>? icons,
    String? brand,
    String? footer,
    ButtonPaint? paint,
    ButtonPaint? activePaint,
  }) =>
      NavSpec(
        position: position ?? this.position,
        show: show ?? this.show,
        align: align ?? this.align,
        shape: shape ?? this.shape,
        width: width ?? this.width,
        gap: gap ?? this.gap,
        order: order ?? this.order,
        hide: hide ?? this.hide,
        labels: labels ?? this.labels,
        icons: icons ?? this.icons,
        brand: brand ?? this.brand,
        footer: footer ?? this.footer,
        paint: paint ?? this.paint,
        activePaint: activePaint ?? this.activePaint,
      );

  /// Plain-language problems with a skin written in code ([] = fine). A skin read from a file is cleaned instead ([fromJson]).
  List<String> problems() {
    final out = <String>[];
    void range(String name, double? v, (double, double) r) {
      if (v != null && (v < r.$1 || v > r.$2)) out.add('nav.$name must be between ${r.$1} and ${r.$2}');
    }

    range('width', width, widthRange);
    range('gap', gap, gapRange);
    for (final (name, ids) in [('order', order), ('hide', hide)]) {
      if (ids.length > maxIds) out.add('nav.$name has more than $maxIds entries');
      for (final id in ids) {
        if (!SkinLayout.validId(id)) out.add('nav.$name: \u201c$id\u201d is not a screen id');
      }
    }
    for (final id in hide) {
      if (protectedIds.contains(id)) out.add('nav.hide: \u201c$id\u201d cannot be hidden (the app would be unusable without it)');
    }
    for (final e in labels.entries) {
      if (!SkinLayout.validId(e.key)) out.add('nav.labels: \u201c${e.key}\u201d is not a screen id');
      if (e.value.trim().isEmpty || e.value.length > maxLabel) out.add('nav.labels.${e.key} must be 1 to $maxLabel characters');
    }
    for (final e in icons.entries) {
      if (!SkinLayout.validId(e.key)) out.add('nav.icons: \u201c${e.key}\u201d is not a screen id');
      if (!SkinIcons.map.containsKey(e.value)) out.add('nav.icons.${e.key}: \u201c${e.value}\u201d is not an icon name (see SkinIcons.names)');
    }
    if ((brand ?? '').length > maxBrand) out.add('nav.brand is longer than $maxBrand characters');
    if ((footer ?? '').length > maxFooter) out.add('nav.footer is longer than $maxFooter characters');
    out.addAll(paint.problems('nav.paint'));
    out.addAll(activePaint.problems('nav.activePaint'));
    return out;
  }

  Map<String, dynamic> toJson() => {
        if (position != null) 'position': position!.name,
        if (show != null) 'show': show!.name,
        if (align != null) 'align': align!.name,
        if (shape != null) 'shape': shape!.name,
        if (width != null) 'width': width,
        if (gap != null) 'gap': gap,
        if (order.isNotEmpty) 'order': order,
        if (hide.isNotEmpty) 'hide': hide,
        if (labels.isNotEmpty) 'labels': labels,
        if (icons.isNotEmpty) 'icons': icons,
        if (brand != null) 'brand': brand,
        if (footer != null) 'footer': footer,
        if (!paint.isEmpty) 'paint': paint.toJson(),
        if (!activePaint.isEmpty) 'activePaint': activePaint.toJson(),
      };

  /// From untrusted JSON: what is not understood is dropped, numbers are clamped, text is cut to length.
  static NavSpec fromJson(Map j) {
    List<String> ids(Object? v) {
      final out = <String>[];
      if (v is List) {
        for (final e in v) {
          if (e is String && SkinLayout.validId(e) && !out.contains(e) && out.length < maxIds) out.add(e);
        }
      }
      return out;
    }

    Map<String, String> pairs(Object? v, {required bool icon}) {
      final out = <String, String>{};
      if (v is Map) {
        for (final e in v.entries) {
          final k = e.key;
          if (k is! String || !SkinLayout.validId(k) || out.length >= maxIds) continue;
          if (icon) {
            if (e.value is String && SkinIcons.map.containsKey(e.value)) out[k] = e.value as String;
          } else {
            final t = _clean(e.value, maxLabel);
            if (t.isNotEmpty) out[k] = t;
          }
        }
      }
      return out;
    }

    return NavSpec(
      position: _enumOf(NavPosition.values, j['position']),
      show: _enumOf(NavShow.values, j['show']),
      align: _enumOf(NavAlign.values, j['align']),
      shape: _enumOf(ButtonShape.values, j['shape']),
      width: _num(j['width'], widthRange.$1, widthRange.$2),
      gap: _num(j['gap'], gapRange.$1, gapRange.$2),
      order: ids(j['order']),
      hide: ids(j['hide']),
      labels: pairs(j['labels'], icon: false),
      icons: pairs(j['icons'], icon: true),
      brand: j['brand'] is String ? _clean(j['brand'], maxBrand) : null,
      footer: j['footer'] is String ? _clean(j['footer'], maxFooter) : null,
      paint: j['paint'] is Map ? ButtonPaint.fromJson(j['paint'] as Map) : const ButtonPaint(),
      activePaint: j['activePaint'] is Map ? ButtonPaint.fromJson(j['activePaint'] as Map) : const ButtonPaint(),
    );
  }
}

/// A colour in a skin: `#rrggbb`, `#rrggbbaa` (CSS order, the last two digits are transparency), `#rgb`, or the name of a colour of
/// the skin's own palette (`accent`, `text`, `bg`, ...), which follows the palette when the person switches skins.
class SkinColor {
  static const tokenNames = <String>{'bg', 'bgElevated', 'surface', 'surfaceFocused', 'border', 'borderFocus', 'text', 'textMuted', 'accent', 'accentGlow'};
  static final _hex = RegExp(r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$');

  static bool valid(Object? v) => v is String && (tokenNames.contains(v) || _hex.hasMatch(v));

  /// [c] as text for a skin: `#rrggbb`, or `#rrggbbaa` when it is see-through. For code that has a [Color]:
  /// `ButtonPaint(fill: SkinColor.of(const Color(0xFFFF2BD6)))`.
  static String of(Color c) {
    String two(int v) => v.toRadixString(16).padLeft(2, '0');
    final base = '#${two(c.red)}${two(c.green)}${two(c.blue)}';
    return c.alpha == 255 ? base : '$base${two(c.alpha)}';
  }

  static String? clean(Object? v) => valid(v) ? v as String : null;
}

/// How one kind of button (primary or secondary) is coloured and animated. Colours are [SkinColor] text. Every field is optional.
class ButtonPaint {
  const ButtonPaint({this.fill, this.gradient = const [], this.angle, this.text, this.border, this.glow, this.anim, this.speed, this.when});

  /// The button's colour. Ignored when there is a [gradient].
  final String? fill;

  /// Two to six colours, blended across the button. With `anim: flow` the blend slides and loops.
  final List<String> gradient;

  /// The direction of the gradient in degrees: 0 = left to right (the default), 90 = top to bottom, 45 = corner to corner.
  final double? angle;

  /// The label colour. null = black or white, whichever reads better on the fill / gradient (or the app's own on the app's own fill).
  final String? text;

  /// The outline colour.
  final String? border;

  /// A soft coloured glow around the button, always on (the focus ring is separate).
  final String? glow;

  /// null / [ButtonAnim.none] = still.
  final ButtonAnim? anim;

  /// Seconds for one loop of the animation (0.5 to 20). null = 4.
  final double? speed;

  /// null = [AnimWhen.always].
  final AnimWhen? when;

  static const speedRange = (0.5, 20.0), angleRange = (-360.0, 360.0);
  static const maxGradient = 6;

  bool get hasGradient => gradient.length >= 2;
  bool get animated => anim != null && anim != ButtonAnim.none;

  bool get isEmpty => fill == null && gradient.isEmpty && angle == null && text == null && border == null && glow == null && anim == null && speed == null && when == null;

  ButtonPaint copyWith({String? fill, List<String>? gradient, double? angle, String? text, String? border, String? glow, ButtonAnim? anim, double? speed, AnimWhen? when}) => ButtonPaint(
        fill: fill ?? this.fill,
        gradient: gradient ?? this.gradient,
        angle: angle ?? this.angle,
        text: text ?? this.text,
        border: border ?? this.border,
        glow: glow ?? this.glow,
        anim: anim ?? this.anim,
        speed: speed ?? this.speed,
        when: when ?? this.when,
      );

  /// [path] names this paint in the messages, e.g. `buttons.primary`.
  /// This paint on top of [base]: what this one sets wins, the rest comes from [base]. A colour set here (a fill or a gradient)
  /// replaces [base]'s colour, whichever kind it was.
  ButtonPaint over(ButtonPaint base) {
    final ownColour = gradient.isNotEmpty || fill != null;
    return ButtonPaint(
      fill: ownColour ? fill : base.fill,
      gradient: ownColour ? gradient : base.gradient,
      angle: angle ?? base.angle,
      text: text ?? base.text,
      border: border ?? base.border,
      glow: glow ?? base.glow,
      anim: anim ?? base.anim,
      speed: speed ?? base.speed,
      when: when ?? base.when,
    );
  }

  List<String> problems(String path) {
    final out = <String>[];
    void color(String field, String? v) {
      if (v != null && !SkinColor.valid(v)) out.add('$path.$field: \u201c$v\u201d is not a colour (use #rrggbb, #rrggbbaa or a palette name like accent)');
    }

    color('fill', fill);
    color('text', text);
    color('border', border);
    color('glow', glow);
    for (final c in gradient) {
      color('gradient', c);
    }
    if (gradient.length == 1 || gradient.length > maxGradient) out.add('$path.gradient needs 2 to $maxGradient colours');
    if (angle != null && (angle! < angleRange.$1 || angle! > angleRange.$2)) out.add('$path.angle must be between ${angleRange.$1} and ${angleRange.$2}');
    if (speed != null && (speed! < speedRange.$1 || speed! > speedRange.$2)) out.add('$path.speed must be between ${speedRange.$1} and ${speedRange.$2} seconds');
    if (anim == ButtonAnim.flow && !hasGradient) out.add('$path: anim flow needs a gradient of 2 or more colours');
    return out;
  }

  Map<String, dynamic> toJson() => {
        if (fill != null) 'fill': fill,
        if (gradient.isNotEmpty) 'gradient': gradient,
        if (angle != null) 'angle': angle,
        if (text != null) 'text': text,
        if (border != null) 'border': border,
        if (glow != null) 'glow': glow,
        if (anim != null) 'anim': anim!.name,
        if (speed != null) 'speed': speed,
        if (when != null) 'when': when!.name,
      };

  static ButtonPaint fromJson(Map j) {
    final g = <String>[];
    if (j['gradient'] is List) {
      for (final e in j['gradient'] as List) {
        final c = SkinColor.clean(e);
        if (c != null && g.length < maxGradient) g.add(c);
      }
    }
    return ButtonPaint(
      fill: SkinColor.clean(j['fill']),
      gradient: g.length >= 2 ? g : const [], // one colour is not a gradient: use fill
      angle: _num(j['angle'], angleRange.$1, angleRange.$2),
      text: SkinColor.clean(j['text']),
      border: SkinColor.clean(j['border']),
      glow: SkinColor.clean(j['glow']),
      anim: _enumOf(ButtonAnim.values, j['anim']),
      speed: _num(j['speed'], speedRange.$1, speedRange.$2),
      when: _enumOf(AnimWhen.values, j['when']),
    );
  }
}

/// How buttons look (the PEK buttons: Refresh, Add widget, Install and the like): shape, size, colours and animation.
class ButtonSpec {
  const ButtonSpec({
    this.shape,
    this.radius,
    this.size,
    this.padding,
    this.borderWidth,
    this.uppercase,
    this.weight,
    this.outline,
    this.focusScale,
    this.primary = const ButtonPaint(),
    this.secondary = const ButtonPaint(),
  });

  /// null = pill. Ignored when [radius] is set.
  final ButtonShape? shape;

  /// An exact corner radius in logical pixels (0 to 999; 999 is a pill). Wins over [shape].
  final double? radius;

  /// A multiple of the app's own size, text and padding together (0.8 to 1.5).
  final double? size;

  /// A multiple of the side padding only (0.5 to 2), to make buttons slimmer or roomier without changing the text size.
  final double? padding;

  /// The outline's thickness in logical pixels (0 to 6). null = 1.
  final double? borderWidth;
  final bool? uppercase;

  /// Text weight: 400, 500, 600, 700, 800 or 900 (anything else is rounded to one of them).
  final int? weight;

  /// Draw buttons as an outline with no fill (unless a paint below gives them one).
  final bool? outline;

  /// How much a button grows when it is focused (1.0 to 1.2). null = the app's own (a small lift on a TV, none on a phone).
  final double? focusScale;

  /// The coloured, animated look of the main (accent) buttons and of the plain ones.
  final ButtonPaint primary, secondary;

  static const sizeRange = (0.8, 1.5), focusRange = (1.0, 1.2), paddingRange = (0.5, 2.0), radiusRange = (0.0, 999.0), borderRange = (0.0, 6.0);

  bool get isEmpty =>
      shape == null &&
      radius == null &&
      size == null &&
      padding == null &&
      borderWidth == null &&
      uppercase == null &&
      weight == null &&
      outline == null &&
      focusScale == null &&
      primary.isEmpty &&
      secondary.isEmpty;

  /// [weight] as a text weight, rounded to the nearest of 400 to 900.
  FontWeight? get fontWeight {
    final w = weight;
    if (w == null) return null;
    final i = ((w.clamp(400, 900) / 100).round() - 1).clamp(3, 8).toInt();
    return FontWeight.values[i];
  }

  ButtonSpec copyWith({
    ButtonShape? shape,
    double? radius,
    double? size,
    double? padding,
    double? borderWidth,
    bool? uppercase,
    int? weight,
    bool? outline,
    double? focusScale,
    ButtonPaint? primary,
    ButtonPaint? secondary,
  }) =>
      ButtonSpec(
        shape: shape ?? this.shape,
        radius: radius ?? this.radius,
        size: size ?? this.size,
        padding: padding ?? this.padding,
        borderWidth: borderWidth ?? this.borderWidth,
        uppercase: uppercase ?? this.uppercase,
        weight: weight ?? this.weight,
        outline: outline ?? this.outline,
        focusScale: focusScale ?? this.focusScale,
        primary: primary ?? this.primary,
        secondary: secondary ?? this.secondary,
      );

  List<String> problems() {
    final out = <String>[];
    void range(String name, double? v, (double, double) r) {
      if (v != null && (v < r.$1 || v > r.$2)) out.add('buttons.$name must be between ${r.$1} and ${r.$2}');
    }

    range('size', size, sizeRange);
    range('focusScale', focusScale, focusRange);
    range('padding', padding, paddingRange);
    range('radius', radius, radiusRange);
    range('borderWidth', borderWidth, borderRange);
    if (weight != null && (weight! < 400 || weight! > 900)) out.add('buttons.weight must be between 400 and 900');
    out.addAll(primary.problems('buttons.primary'));
    out.addAll(secondary.problems('buttons.secondary'));
    return out;
  }

  Map<String, dynamic> toJson() => {
        if (shape != null) 'shape': shape!.name,
        if (radius != null) 'radius': radius,
        if (size != null) 'size': size,
        if (padding != null) 'padding': padding,
        if (borderWidth != null) 'borderWidth': borderWidth,
        if (uppercase != null) 'uppercase': uppercase,
        if (weight != null) 'weight': weight,
        if (outline != null) 'outline': outline,
        if (focusScale != null) 'focusScale': focusScale,
        if (!primary.isEmpty) 'primary': primary.toJson(),
        if (!secondary.isEmpty) 'secondary': secondary.toJson(),
      };

  static ButtonSpec fromJson(Map j) => ButtonSpec(
        shape: _enumOf(ButtonShape.values, j['shape']),
        radius: _num(j['radius'], radiusRange.$1, radiusRange.$2),
        size: _num(j['size'], sizeRange.$1, sizeRange.$2),
        padding: _num(j['padding'], paddingRange.$1, paddingRange.$2),
        borderWidth: _num(j['borderWidth'], borderRange.$1, borderRange.$2),
        uppercase: j['uppercase'] is bool ? j['uppercase'] as bool : null,
        weight: j['weight'] is num ? ((j['weight'] as num).toDouble().clamp(400, 900) / 100).round() * 100 : null,
        outline: j['outline'] is bool ? j['outline'] as bool : null,
        focusScale: _num(j['focusScale'], focusRange.$1, focusRange.$2),
        primary: j['primary'] is Map ? ButtonPaint.fromJson(j['primary'] as Map) : const ButtonPaint(),
        secondary: j['secondary'] is Map ? ButtonPaint.fromJson(j['secondary'] as Map) : const ButtonPaint(),
      );
}

/// One widget in a skin's dashboard arrangement: the same `{type, size, folder}` the dashboard saves.
class DashPick {
  const DashPick(this.type, {this.size = 's', this.folder = ''});

  /// clock, weather, continue, recent, favorites, plugin, nowplaying, albums, playlists, shows, pinned, stats, surprise, upnext,
  /// watched, recommend (the types the dashboard knows; others are dropped).
  final String type;

  /// 's' (small) or 'm' (wide; only the tile widgets: clock, plugin, stats, surprise).
  final String size;

  /// For `plugin`: the plugin's folder name.
  final String folder;

  Map<String, dynamic> toJson() => {'type': type, if (size == 'm') 'size': 'm', if (folder.isNotEmpty) 'folder': folder};

  static final _typeRe = RegExp(r'^[a-z]{1,24}$');
  static final _folderRe = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

  /// A pick from untrusted JSON, or null when it is not one.
  static DashPick? fromJson(Object? j) {
    if (j is! Map) return null;
    final type = j['type'];
    if (type is! String || !_typeRe.hasMatch(type)) return null;
    final folder = '${j['folder'] ?? ''}';
    if (type == 'plugin' && !_folderRe.hasMatch(folder)) return null;
    return DashPick(type, size: j['size'] == 'm' ? 'm' : 's', folder: type == 'plugin' ? folder : '');
  }

  List<String> problems() {
    final out = <String>[];
    if (!_typeRe.hasMatch(type)) out.add('dashboard: \u201c$type\u201d is not a widget type');
    if (size != 's' && size != 'm') out.add('dashboard: the size of $type must be s or m');
    if (type == 'plugin' && !_folderRe.hasMatch(folder)) out.add('dashboard: a plugin widget needs a folder name');
    return out;
  }
}

/// The dashboard: which widgets, in what order and how wide.
class DashSpec {
  const DashSpec({this.items = const [], this.locked = false});

  /// Picks from short text: `'weather'`, `'clock:m'` (wide), `'plugin:my-folder'`, `'plugin:my-folder:m'`.
  factory DashSpec.of(List<String> specs, {bool locked = false}) {
    final items = <DashPick>[];
    for (final s in specs) {
      final parts = s.split(':');
      if (parts.first == 'plugin') {
        items.add(DashPick('plugin', folder: parts.length > 1 ? parts[1] : '', size: parts.length > 2 ? parts[2] : 's'));
      } else {
        items.add(DashPick(parts.first, size: parts.length > 1 ? parts[1] : 's'));
      }
    }
    return DashSpec(items: items, locked: locked);
  }

  /// The arrangement. Empty = the skin has none and the app's own dashboard is used.
  final List<DashPick> items;

  /// false: this is the starting arrangement, used until the person arranges their own (then theirs wins).
  /// true: always this arrangement; the person cannot move, add or remove widgets while the skin is in use.
  final bool locked;

  static const maxItems = 40;

  bool get isEmpty => items.isEmpty;

  /// The skin sets an arrangement.
  bool get active => items.isNotEmpty;

  DashSpec copyWith({List<DashPick>? items, bool? locked}) => DashSpec(items: items ?? this.items, locked: locked ?? this.locked);

  List<String> problems() {
    final out = <String>[];
    if (items.length > maxItems) out.add('dashboard has more than $maxItems widgets');
    for (final i in items) {
      out.addAll(i.problems());
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
        if (items.isNotEmpty) 'items': [for (final i in items) i.toJson()],
        if (locked && items.isNotEmpty) 'locked': true,
      };

  static DashSpec fromJson(Map j) {
    final out = <DashPick>[];
    final raw = j['items'];
    if (raw is List) {
      for (final e in raw) {
        final p = DashPick.fromJson(e);
        if (p != null && out.length < maxItems) out.add(p);
      }
    }
    return DashSpec(items: out, locked: j['locked'] == true && out.isNotEmpty);
  }
}

/// Everything a skin can rearrange. See the file header.
class SkinLayout {
  const SkinLayout({this.nav = const NavSpec(), this.buttons = const ButtonSpec(), this.dashboard = const DashSpec(), this.miniPlayer, this.poster});

  /// A skin that changes nothing.
  static const none = SkinLayout();

  final NavSpec nav;
  final ButtonSpec buttons;
  final DashSpec dashboard;

  /// null = the bottom, as the app has it.
  final MiniZone? miniPlayer;

  /// The poster size the skin starts with: 's', 'm' or 'l'. Used when the person's poster size is Auto (their own choice wins).
  final String? poster;

  static const posterSizes = ['s', 'm', 'l'];

  /// What a screen id looks like: a plain lower-case name, or `plugin:<folder>`.
  static final _idRe = RegExp(r'^(plugin:[A-Za-z0-9_-]{1,80}|[a-z][a-z0-9]{0,23})$');
  static bool validId(String id) => _idRe.hasMatch(id);

  bool get isEmpty => nav.isEmpty && buttons.isEmpty && dashboard.isEmpty && miniPlayer == null && poster == null;

  SkinLayout copyWith({NavSpec? nav, ButtonSpec? buttons, DashSpec? dashboard, MiniZone? miniPlayer, String? poster}) => SkinLayout(
        nav: nav ?? this.nav,
        buttons: buttons ?? this.buttons,
        dashboard: dashboard ?? this.dashboard,
        miniPlayer: miniPlayer ?? this.miniPlayer,
        poster: poster ?? this.poster,
      );

  /// Plain-language problems with a skin written in code ([] = fine).
  List<String> problems() => [
        ...nav.problems(),
        ...buttons.problems(),
        ...dashboard.problems(),
        if (poster != null && !posterSizes.contains(poster)) 'poster must be s, m or l',
      ];

  /// A few short phrases for the install screen: what this skin rearranges.
  List<String> get summary {
    final out = <String>[];
    final pos = nav.position;
    if (pos != null) {
      const where = {NavPosition.left: 'on the left', NavPosition.right: 'on the right', NavPosition.top: 'at the top', NavPosition.bottom: 'at the bottom'};
      out.add('menu ${where[pos]}');
    }
    if (nav.order.isNotEmpty || nav.hide.isNotEmpty) out.add('menu buttons reordered or removed');
    if (nav.labels.isNotEmpty || nav.icons.isNotEmpty || nav.show != null || nav.shape != null || nav.brand != null || nav.footer != null || !nav.paint.isEmpty || !nav.activePaint.isEmpty) {
      out.add('menu names and look');
    }
    if (!buttons.isEmpty) out.add('button look');
    if (dashboard.active) out.add(dashboard.locked ? 'a fixed dashboard' : 'a starting dashboard');
    final mini = miniPlayer;
    if (mini != null) out.add(mini == MiniZone.hidden ? 'mini player hidden' : 'mini player at the ${mini.name}');
    if (poster != null) out.add('poster size');
    return out;
  }

  Map<String, dynamic> toJson() => {
        if (!nav.isEmpty) 'nav': nav.toJson(),
        if (!buttons.isEmpty) 'buttons': buttons.toJson(),
        if (!dashboard.isEmpty) 'dashboard': dashboard.toJson(),
        if (miniPlayer != null) 'miniPlayer': miniPlayer!.name,
        if (poster != null) 'poster': poster,
      };

  /// From untrusted JSON (a skin.json, or what this device stored). null when [j] is not an object; otherwise a cleaned layout.
  static SkinLayout? fromJson(Object? j) {
    if (j is! Map) return null;
    final p = j['poster'];
    return SkinLayout(
      nav: j['nav'] is Map ? NavSpec.fromJson(j['nav'] as Map) : const NavSpec(),
      buttons: j['buttons'] is Map ? ButtonSpec.fromJson(j['buttons'] as Map) : const ButtonSpec(),
      dashboard: j['dashboard'] is Map ? DashSpec.fromJson(j['dashboard'] as Map) : const DashSpec(),
      miniPlayer: _enumOf(MiniZone.values, j['miniPlayer']),
      poster: p is String && posterSizes.contains(p) ? p : null,
    );
  }

  @override
  bool operator ==(Object other) => other is SkinLayout && jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}
