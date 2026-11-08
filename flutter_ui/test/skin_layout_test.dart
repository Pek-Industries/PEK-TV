import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/plugin_store.dart' show PluginFile, StoreException;
import 'package:pek_tv_ui/src/skin_builder.dart';
import 'package:pek_tv_ui/src/skin_button.dart';
import 'package:pek_tv_ui/src/skin_install.dart';
import 'package:pek_tv_ui/src/skin_layout.dart';
import 'package:pek_tv_ui/src/skins.dart';

import 'skin_zip_writer.dart';

PluginFile f(String path, String text) => PluginFile(path, Uint8List.fromList(utf8.encode(text)));

void main() {
  const defaults = ['dashboard', 'movies', 'shows', 'music', 'updates', 'settings'];

  group('menu order and removed buttons', () {
    test('a skin that says nothing leaves the menu alone', () {
      expect(const NavSpec().arrange(defaults), defaults);
    });

    test('listed screens come first in your order, the rest follow in the app\'s order', () {
      final out = const NavSpec(order: ['music', 'movies']).arrange(defaults);
      expect(out, ['music', 'movies', 'dashboard', 'shows', 'updates', 'settings']);
    });

    test('screens that do not exist and repeats are ignored', () {
      final out = const NavSpec(order: ['nope', 'shows', 'shows']).arrange(defaults);
      expect(out.first, 'shows');
      expect(out.length, defaults.length);
    });

    test('hidden screens go, but the ones that must stay cannot be hidden', () {
      final out = const NavSpec(hide: ['updates', 'settings', 'dashboard']).arrange(defaults, keep: NavSpec.protectedIds);
      expect(out, ['dashboard', 'movies', 'shows', 'music', 'settings']);
    });
  });

  group('reading a layout from a skin.json (untrusted)', () {
    test('not an object is not a layout; an empty object is an empty one', () {
      expect(SkinLayout.fromJson('x'), isNull);
      expect(SkinLayout.fromJson(null), isNull);
      expect(SkinLayout.fromJson(<String, dynamic>{})!.isEmpty, isTrue);
    });

    test('numbers are clamped into range', () {
      final l = SkinLayout.fromJson({
        'nav': {'width': 99, 'gap': -3},
        'buttons': {'size': 9, 'weight': 840, 'focusScale': 5, 'radius': -4, 'padding': 9, 'borderWidth': 50},
      })!;
      expect(l.nav.width, 1.6);
      expect(l.nav.gap, 0.0);
      expect(l.buttons.size, 1.5);
      expect(l.buttons.weight, 800);
      expect(l.buttons.focusScale, 1.2);
      expect(l.buttons.radius, 0.0);
      expect(l.buttons.padding, 2.0);
      expect(l.buttons.borderWidth, 6.0);
    });

    test('what is not understood is dropped, never trusted', () {
      final l = SkinLayout.fromJson({
        'nav': {
          'position': 'diagonal',
          'show': 5,
          'order': ['movies', '../x', 'Bad Id', 'plugin:ok-1', 'plugin:../x'],
          'hide': 'movies',
          'labels': {'shows': 'Series', 'bad id': 'x', 'music': '   '},
          'icons': {'movies': 'fire', 'shows': 'http://evil/x.png', 'music': 'not-an-icon'},
        },
        'miniPlayer': 'sideways',
        'poster': 'xl',
      })!;
      expect(l.nav.position, isNull);
      expect(l.nav.show, isNull);
      expect(l.nav.order, ['movies', 'plugin:ok-1']);
      expect(l.nav.hide, isEmpty);
      expect(l.nav.labels, {'shows': 'Series'});
      expect(l.nav.icons, {'movies': 'fire'});
      expect(l.miniPlayer, isNull);
      expect(l.poster, isNull);
    });

    test('names are cut to length and have no control characters', () {
      final l = SkinLayout.fromJson({
        'nav': {
          'labels': {'shows': 'A very long name that does not fit in a menu button'},
          'brand': 'PEK\nTV',
          'footer': '',
        },
      })!;
      expect(l.nav.labels['shows']!.length, NavSpec.maxLabel);
      expect(l.nav.brand, 'PEK TV');
      expect(l.nav.footer, ''); // an empty footer is a choice (no footer), not a missing value
    });

    test('button colours: hex and palette names are kept, anything else is dropped', () {
      final l = SkinLayout.fromJson({
        'buttons': {
          'primary': {
            'fill': 'url(https://evil/x.png)',
            'text': 'accent',
            'border': '#ff2bd6',
            'glow': '#ff2bd680',
            'gradient': ['#fff', 'red', 'bg'],
            'angle': 900,
            'speed': 0,
            'anim': 'explode',
            'when': 'focus',
          },
        },
      })!;
      final p = l.buttons.primary;
      expect(p.fill, isNull);
      expect(p.text, 'accent');
      expect(p.border, '#ff2bd6');
      expect(p.glow, '#ff2bd680');
      expect(p.gradient, ['#fff', 'bg']); // 'red' is not a colour here
      expect(p.angle, 360.0);
      expect(p.speed, 0.5);
      expect(p.anim, isNull);
      expect(p.when, AnimWhen.focus);
    });

    test('one colour is not a gradient, and a gradient has at most six', () {
      final one = SkinLayout.fromJson({'buttons': {'primary': {'gradient': ['#ff0000']}}})!;
      expect(one.buttons.primary.gradient, isEmpty);
      final many = SkinLayout.fromJson({'buttons': {'primary': {'gradient': List.filled(12, '#00ff00')}}})!;
      expect(many.buttons.primary.gradient.length, ButtonPaint.maxGradient);
    });

    test('dashboard picks: plugins need a folder, unknown shapes are dropped, locked needs widgets', () {
      final l = SkinLayout.fromJson({
        'dashboard': {
          'items': [
            {'type': 'clock', 'size': 'm'},
            {'type': 'plugin'},
            {'type': 'plugin', 'folder': 'my-plugin'},
            {'type': '../etc'},
            'weather',
            {'type': 'weather', 'size': 'huge'},
          ],
          'locked': true,
        },
      })!;
      expect(l.dashboard.items.map((e) => e.type), ['clock', 'plugin', 'weather']);
      expect(l.dashboard.items[0].size, 'm');
      expect(l.dashboard.items[1].folder, 'my-plugin');
      expect(l.dashboard.items[2].size, 's');
      expect(l.dashboard.locked, isTrue);
      expect(SkinLayout.fromJson({'dashboard': {'locked': true}})!.dashboard.locked, isFalse);
    });

    test('a layout survives writing and reading again', () {
      final l = SkinLayout(
        nav: const NavSpec(
          position: NavPosition.right,
          show: NavShow.icons,
          align: NavAlign.center,
          shape: ButtonShape.square,
          width: 0.9,
          order: ['music'],
          hide: ['duplicates'],
          labels: {'shows': 'Series'},
          icons: {'movies': 'fire'},
          brand: 'ARCADE',
          footer: '',
          paint: ButtonPaint(fill: 'surface', border: 'accent'),
          activePaint: ButtonPaint(gradient: ['#ff2bd6', '#00d4ff'], anim: ButtonAnim.flow, speed: 3),
        ),
        buttons: const ButtonSpec(
          radius: 8,
          size: 1.1,
          uppercase: true,
          weight: 800,
          primary: ButtonPaint(gradient: ['#ff2bd6', '#7a5cff'], angle: 45, anim: ButtonAnim.shimmer, glow: '#ff2bd680', when: AnimWhen.focus),
        ),
        dashboard: DashSpec.of(['clock:m', 'weather', 'plugin:abc'], locked: true),
        miniPlayer: MiniZone.top,
        poster: 'l',
      );
      final back = SkinLayout.fromJson(jsonDecode(jsonEncode(l.toJson())))!;
      expect(back, l);
      expect(jsonEncode(back.toJson()), jsonEncode(l.toJson()));
    });

    test('a layout says in words what it rearranges', () {
      expect(SkinLayout.none.summary, isEmpty);
      final s = const SkinLayout(nav: NavSpec(position: NavPosition.top), miniPlayer: MiniZone.hidden, buttons: ButtonSpec(size: 1.2)).summary;
      expect(s, containsAll(['menu at the top', 'mini player hidden', 'button look']));
    });
  });

  group('checking a layout written in code', () {
    test('a good one has no problems', () {
      expect(const SkinLayout(nav: NavSpec(position: NavPosition.left, hide: ['updates'], icons: {'movies': 'fire'}), buttons: ButtonSpec(size: 1.2)).problems(), isEmpty);
    });

    test('says what is wrong, in plain words', () {
      expect(const NavSpec(hide: ['dashboard']).problems().single, contains('cannot be hidden'));
      expect(const NavSpec(icons: {'movies': 'pizza'}).problems().single, contains('not an icon name'));
      expect(const NavSpec(width: 5).problems().single, contains('between'));
      expect(const NavSpec(order: ['Not An Id']).problems().single, contains('not a screen id'));
      expect(const ButtonSpec(size: 3).problems().single, contains('buttons.size'));
      expect(const ButtonSpec(primary: ButtonPaint(fill: 'blue')).problems().single, contains('not a colour'));
      expect(const ButtonSpec(primary: ButtonPaint(gradient: ['#fff'])).problems().single, contains('2 to 6'));
      expect(const ButtonSpec(primary: ButtonPaint(anim: ButtonAnim.flow)).problems().single, contains('needs a gradient'));
      expect(const NavSpec(paint: ButtonPaint(speed: 99)).problems().single, contains('nav.paint.speed'));
      expect(const SkinLayout(poster: 'huge').problems().single, contains('poster'));
    });
  });

  group('colours and paint', () {
    test('what counts as a colour', () {
      for (final ok in ['#fff', '#ff8800', '#ff880080', 'accent', 'bg', 'textMuted']) {
        expect(SkinColor.valid(ok), isTrue, reason: ok);
      }
      for (final bad in ['red', 'ff8800', '#ff88', 'rgb(1,2,3)', 'url(x)', '', 'Accent']) {
        expect(SkinColor.valid(bad), isFalse, reason: bad);
      }
      expect(SkinColor.valid(5), isFalse);
      expect(SkinColor.valid(null), isFalse);
    });

    test('a Color becomes skin text, with transparency only when there is some', () {
      expect(SkinColor.of(const Color(0xFFFF2BD6)), '#ff2bd6');
      expect(SkinColor.of(const Color(0x80FF2BD6)), '#ff2bd680');
    });

    test('a paint on top of another: what it sets wins, a new colour replaces the old kind of colour', () {
      const base = ButtonPaint(gradient: ['#111111', '#222222'], text: 'text', anim: ButtonAnim.flow, speed: 6);
      final onTop = const ButtonPaint(fill: '#ff0000', speed: 2).over(base);
      expect(onTop.fill, '#ff0000');
      expect(onTop.gradient, isEmpty); // a plain colour on top of a gradient is a plain colour
      expect(onTop.text, 'text');
      expect(onTop.speed, 2.0);
      expect(onTop.anim, ButtonAnim.flow);
      final same = const ButtonPaint(glow: '#00ff00').over(base);
      expect(same.gradient, base.gradient);
      expect(same.glow, '#00ff00');
    });

    test('a weight is rounded to a real text weight', () {
      expect(const ButtonSpec(weight: 800).fontWeight, FontWeight.w800);
      expect(const ButtonSpec(weight: 840).fontWeight, FontWeight.w800);
      expect(const ButtonSpec().fontWeight, isNull);
    });

    test('shapes are corner sizes', () {
      expect(ButtonShape.pill.radius(16), 999);
      expect(ButtonShape.rounded.radius(16), 16);
      expect(ButtonShape.square.radius(16), 0);
    });
  });

  group('every icon a skin may name', () {
    test('has an icon, and the app\'s own screens have one too', () {
      for (final n in SkinIcons.names) {
        expect(SkinIcons.byName(n), isNotNull, reason: n);
      }
      expect(SkinIcons.byName('nope'), isNull);
      expect(SkinIcons.byName(null), isNull);
      for (final id in ['dashboard', 'movies', 'shows', 'music', 'updates', 'search', 'history', 'favorites', 'duplicates', 'unknown', 'plugins', 'settings', 'plugin:x']) {
        expect(SkinIcons.forScreen(id), isNotNull, reason: id);
      }
    });
  });

  group('SkinBuilder with a layout', () {
    SkinBuilder arcade() => SkinBuilder.fromAccent('Arcade Test', const Color(0xFFFF2BD6))
        .nav(position: NavPosition.right, show: NavShow.icons, order: ['music'], hide: ['duplicates'], labels: {'shows': 'Series'}, icons: {'movies': 'fire'}, brand: 'ARCADE', footer: '')
        .nav(shape: ButtonShape.pill) // a second call adds to the first, it does not replace it
        .buttons(radius: 8, uppercase: true, primary: const ButtonPaint(gradient: ['#ff2bd6', '#00d4ff'], anim: ButtonAnim.flow, speed: 3))
        .dashboard(['clock:m', 'nowplaying', 'continue'], locked: true)
        .miniPlayer(MiniZone.top)
        .posters('l');

    test('the calls combine', () {
      final skin = arcade().build();
      final l = skin.layout!;
      expect(l.nav.position, NavPosition.right);
      expect(l.nav.shape, ButtonShape.pill);
      expect(l.nav.show, NavShow.icons);
      expect(l.nav.hide, ['duplicates']);
      expect(l.buttons.radius, 8.0);
      expect(l.buttons.uppercase, isTrue);
      expect(l.buttons.primary.anim, ButtonAnim.flow);
      expect(l.dashboard.items.map((e) => '${e.type}:${e.size}'), ['clock:m', 'nowplaying:s', 'continue:s']);
      expect(l.dashboard.locked, isTrue);
      expect(l.miniPlayer, MiniZone.top);
      expect(l.poster, 'l');
    });

    test('a skin made in code and a skin made from its skin.json are the same layout', () {
      final skin = arcade().build();
      final text = SkinJson.toText(skin);
      expect(jsonDecode(text)['layout'], isA<Map>());
      final back = SkinJson.fromText(text)!;
      expect(back.layout, skin.layout);
    });

    test('a skin with no layout has none in its skin.json', () {
      final skin = SkinBuilder.fromAccent('Plain Test', const Color(0xFF38BDF8)).build();
      expect(skin.layout!.isEmpty, isTrue);
      expect(jsonDecode(SkinJson.toText(skin)).containsKey('layout'), isFalse);
    });

    test('mistakes are refused with a plain message', () {
      void refused(SkinBuilder b, Pattern message) =>
          expect(() => b.build(), throwsA(isA<SkinBuildException>().having((e) => e.message, 'message', contains(message))));
      SkinBuilder base() => SkinBuilder.fromAccent('Bad Test', const Color(0xFF38BDF8));
      refused(base().nav(hide: ['settings']), 'cannot be hidden');
      refused(base().nav(icons: {'movies': 'pizza'}), 'not an icon name');
      refused(base().dashboard(['clock', 'blender']), 'not a widget');
      refused(base().dashboard(['clock', 'clock']), 'listed twice');
      refused(base().dashboard(['plugin:a', 'plugin:a']), 'listed twice');
      refused(base().buttons(primary: const ButtonPaint(anim: ButtonAnim.flow)), 'needs a gradient');
      refused(base().posters('huge'), 'poster');
    });

    test('two different plugin widgets are not a repeat', () {
      expect(SkinBuilder.fromAccent('Two Test', const Color(0xFF38BDF8)).dashboard(['plugin:a', 'plugin:b']).layoutProblems(), isEmpty);
    });

    test('a skin built from an existing skin keeps its layout', () {
      final skin = arcade().build();
      expect(SkinBuilder.from(skin).build().layout, skin.layout);
    });
  });

  group('installing a skin with a layout', () {
    const tokens = '"tokens":{"bg":"#101010","text":"#f0f0f0","accent":"#ff8800"}';

    PreparedSkin prepare(String json) => SkinInstaller.prepare(SkinZipWriter.write('x', [f('skin.json', json)]), fileName: 'x.zip');

    test('the layout comes with it, cleaned', () {
      final p = prepare('{"name":"L",$tokens,"layout":{"nav":{"position":"top","hide":["dashboard","updates"],"width":40},"buttons":{"primary":{"anim":"flow","gradient":["#ff0000","#0000ff"]}}}}');
      expect(p.layout!.nav.position, NavPosition.top);
      expect(p.layout!.nav.width, 1.6);
      expect(p.layout!.buttons.primary.anim, ButtonAnim.flow);
      // hide still lists dashboard, but the shell never removes it (NavSpec.arrange with keep): see 'hidden screens go'.
      expect(p.layout!.nav.hide, ['dashboard', 'updates']);
      expect(const NavSpec(hide: ['dashboard']).arrange(['dashboard', 'x'], keep: NavSpec.protectedIds), ['dashboard', 'x']);
    });

    test('a skin with no layout has none', () {
      expect(prepare('{"name":"L",$tokens}').layout, isNull);
    });

    test('a layout that is not an object is refused', () {
      expect(() => prepare('{"name":"L",$tokens,"layout":[1]}'), throwsA(isA<StoreException>().having((e) => e.message, 'message', contains('layout'))));
    });

    test('the layout stays through a rename or a new id', () {
      final p = prepare('{"name":"L",$tokens,"layout":{"miniPlayer":"hidden"}}');
      expect(p.withId('other').layout!.miniPlayer, MiniZone.hidden);
    });
  });

  group('an animated button surface', () {
    double gradientX(WidgetTester tester) {
      final box = tester.widgetList<DecoratedBox>(find.descendant(of: find.byType(ButtonSurface), matching: find.byType(DecoratedBox))).first;
      final g = (box.decoration as BoxDecoration).gradient! as LinearGradient;
      return (g.begin as Alignment).x;
    }

    Widget surface({bool always = true, bool focused = false, bool reduceMotion = false}) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduceMotion),
            child: SizedBox(
              width: 200,
              height: 50,
              child: ButtonSurface(colors: const [Color(0xFFFF0000), Color(0xFF0000FF)], anim: ButtonAnim.flow, seconds: 2, always: always, focused: focused),
            ),
          ),
        );

    testWidgets('a flowing gradient slides', (tester) async {
      await tester.pumpWidget(surface());
      await tester.pump(); // the first frame of a ticker has no time gone by yet: this one starts it
      final start = gradientX(tester);
      expect(start, closeTo(-1, 0.01));
      await tester.pump(const Duration(milliseconds: 1000)); // half of a 2 second loop: half a button width along
      expect(gradientX(tester), closeTo(0, 0.1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('it stands still when the device asks for less motion', (tester) async {
      await tester.pumpWidget(surface(reduceMotion: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1000));
      expect(gradientX(tester), closeTo(-1, 0.01));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a focus-only animation waits for focus', (tester) async {
      await tester.pumpWidget(surface(always: false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1000));
      expect(gradientX(tester), closeTo(-1, 0.01));
      await tester.pumpWidget(surface(always: false, focused: true));
      await tester.pump(); // starts the ticker
      await tester.pump(const Duration(milliseconds: 1000));
      expect(gradientX(tester), greaterThan(-0.9));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
