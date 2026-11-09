import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/skin_layout.dart';
import 'package:pek_tv_ui/src/skins.dart';

void main() {
  group('skins in the cloud', () {
    test('every built-in look survives the trip to the cloud and back', () {
      for (final b in Skins.builtIn) {
        final skin = Skin('custom-abc123', b.name, b.description, b.tokens, custom: true, author: 'me', version: '1.2.3');
        final wire = jsonDecode(jsonEncode(Skins.syncValue(skin)));
        expect(jsonEncode(wire).length, lessThan(Skins.syncBudget));
        final back = Skins.cleanSync('custom-abc123', wire, 42)!;
        expect(back.updated, 42);
        expect(back.name, b.name);
        expect(back.author, 'me');
        expect(SkinJson.tokensTo(back.tokens), SkinJson.tokensTo(b.tokens));
      }
    });

    test('a GitHub skin keeps where it came from', () {
      final skin = Skin('pkg-sunset', 'Sunset', '', Skins.ember,
          custom: true, source: const {'type': 'github', 'owner': 'a', 'repo': 'b', 'tag': 'v1', 'kind': 'asset'});
      final back = Skins.cleanSync('pkg-sunset', jsonDecode(jsonEncode(Skins.syncValue(skin))), 1)!;
      expect(back.fromGithub, isTrue);
      expect(back.source!['repo'], 'b');
    });

    test('nothing odd from the cloud is taken in', () {
      final good = Map<String, dynamic>.from(Skins.syncValue(Skin('custom-a', 'A', '', Skins.ember, custom: true)));
      expect(Skins.cleanSync('custom-a', good, 1), isNotNull);
      expect(Skins.cleanSync('../evil', good, 1), isNull); // not a skin id
      expect(Skins.cleanSync('custom-a', {...good, 'c': 'zz'}, 1), isNull); // colours of the wrong size
      expect(Skins.cleanSync('custom-a', {...good, 'c': 'x' * 104}, 1), isNull); // not hex
      expect(Skins.cleanSync('custom-a', 'text', 1), isNull);
      expect(Skins.cleanSync('custom-a', {...good, 'r': 9999}, 1)!.tokens.radius, 40); // corner size is kept in range
    });

    test('a skin\'s layout goes to the cloud and comes back', () {
      final layout = SkinLayout.fromJson({
        'nav': {'position': 'right', 'show': 'icons', 'order': ['music', 'movies'], 'hide': ['duplicates'], 'labels': {'shows': 'Series'}, 'brand': 'ARCADE'},
        'buttons': {'radius': 8, 'uppercase': true, 'primary': {'gradient': ['#ff2bd6', '#00d4ff'], 'anim': 'flow', 'speed': 3}},
        'dashboard': {'items': [{'type': 'clock', 'size': 'm'}, {'type': 'nowplaying'}]},
        'miniPlayer': 'top',
        'poster': 'l',
      })!;
      final skin = Skin('custom-lay1', 'Arcade', '', Skins.ember, custom: true, layout: layout);
      final wire = jsonDecode(jsonEncode(Skins.syncValue(skin)));
      expect(wire['layout'], isA<Map>());
      expect(jsonEncode(wire).length, lessThan(Skins.syncBudget));
      final back = Skins.cleanSync('custom-lay1', wire, 7)!;
      expect(back.layout, isNotNull);
      expect(back.layout, layout);
    });

    test('a skin with no layout sends none, and an older cloud copy says nothing about layouts', () {
      final skin = Skin('custom-lay2', 'Plain', '', Skins.ember, custom: true);
      final wire = Map<String, dynamic>.from(jsonDecode(jsonEncode(Skins.syncValue(skin))));
      expect(wire.containsKey('layout'), isFalse);
      expect(Skins.cleanSync('custom-lay2', wire, 1)!.layout, isNull); // null = keep the layout this device has
    });

    test('a layout from the cloud is cleaned, not trusted', () {
      final good = Map<String, dynamic>.from(Skins.syncValue(Skin('custom-lay3', 'A', '', Skins.ember, custom: true)));
      final back = Skins.cleanSync('custom-lay3', {
        ...good,
        'layout': {'nav': {'position': 'sideways', 'brand': 'x' * 500}, 'poster': 'huge', 'evil': {'run': 'code'}},
      }, 1)!;
      expect(back.layout, isNotNull);
      expect(back.layout!.poster, isNull);
      expect(back.layout!.nav.position, isNull);
      expect(Skins.cleanSync('custom-lay3', {...good, 'layout': 'text'}, 1)!.layout!.isEmpty, isTrue);
    });

    test('ids', () {
      expect(Skins.validId('custom-lq3x9'), isTrue);
      expect(Skins.validId('pkg-my-skin_2'), isTrue);
      expect(Skins.validId('ember'), isFalse);
      expect(Skins.validId('pkg-'), isFalse);
    });
  });
}
