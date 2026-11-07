import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/dvd.dart';

void main() {
  Map<String, dynamic> disc({bool menu = true, bool known = true, List<Map<String, dynamic>>? titles}) => {
        'dvd': true,
        'iso': false,
        'device': '/storage/emulated/0/Movies/Heat (1995)',
        'detailsKnown': known,
        'hasMenu': menu,
        'hasTitleMenus': menu,
        'main': 1,
        'titles': titles ??
            [
              {'n': 1, 'seconds': 6750, 'chapters': 28, 'angles': 1},
              {'n': 2, 'seconds': 310, 'chapters': 3, 'angles': 1},
              {'n': 3, 'seconds': 4, 'chapters': 1, 'angles': 1},
            ],
      };

  test('parses a disc and formats lengths', () {
    final d = DvdInfo.fromJson(disc());
    expect(d.main, 1);
    expect(d.titles.length, 3);
    expect(d.titles.first.length, '1:52:30');
    expect(d.titles[1].length, '5:10');
    expect(d.titles.first.detail, '1:52:30 · 28 chapters');
    expect(d.device, '/storage/emulated/0/Movies/Heat (1995)');
  });

  test('menu stills a few seconds long are not listed', () {
    final d = DvdInfo.fromJson(disc());
    expect(d.listed.map((t) => t.n), [1, 2]);
  });

  test('the picker only appears when there is something to choose', () {
    expect(DvdInfo.fromJson(disc()).needsPicker, true);
    final plain = DvdInfo.fromJson(disc(menu: false, titles: [
      {'n': 1, 'seconds': 5000, 'chapters': 12, 'angles': 1},
    ]));
    expect(plain.needsPicker, false);
    expect(DvdInfo.fromJson(disc(menu: false)).needsPicker, true); // two real titles
    expect(DvdInfo.fromJson(disc(known: false, titles: [])).needsPicker, false); // unreadable tables: just play it
  });
}
