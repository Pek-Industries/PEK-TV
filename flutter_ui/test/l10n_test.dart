import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/l10n.dart';

void main() {
  tearDown(() => L10n.useForTest('en'));

  test('System default follows the device language when it is offered, otherwise English', () {
    expect(L10n.resolve(L10n.system, 'es'), 'es');
    expect(L10n.resolve(L10n.system, 'pt'), 'pt');
    expect(L10n.resolve(L10n.system, 'ja'), 'en');
    expect(L10n.resolve(L10n.system, ''), 'en');
  });

  test('a picked language wins over the device language; an unknown one falls back to English', () {
    expect(L10n.resolve('fr', 'es'), 'fr');
    expect(L10n.resolve('en', 'de'), 'en');
    expect(L10n.resolve('xx', 'de'), 'en');
  });

  test('text is translated, and anything without an entry stays English', () {
    L10n.useForTest('es');
    expect('Sign in later'.tr, 'Iniciar sesión más tarde');
    expect('A title nobody translated'.tr, 'A title nobody translated');
    L10n.useForTest('en');
    expect('Sign in later'.tr, 'Sign in later');
  });

  test('placeholders are filled in', () {
    L10n.useForTest('de');
    expect('{n} new'.trp({'n': 3}), '3 neu');
    L10n.useForTest('en');
    expect('{n} new'.trp({'n': 3}), '3 new');
  });

  test('every language has the same strings, none empty, with the same placeholders', () {
    final codes = L10n.tables.keys.toList();
    final base = L10n.tables[codes.first]!.keys.toSet();
    final holder = RegExp(r'\{\w+\}');
    for (final code in codes) {
      final t = L10n.tables[code]!;
      expect(t.keys.toSet(), base, reason: '$code has different keys');
      t.forEach((k, v) {
        expect(v.trim().isNotEmpty, true, reason: '$code: empty translation for "$k"');
        expect(holder.allMatches(v).map((m) => m[0]).toList()..sort(), holder.allMatches(k).map((m) => m[0]).toList()..sort(), reason: '$code: placeholders for "$k"');
      });
    }
  });

  test('every offered language except English has a table', () {
    for (final l in L10n.languages) {
      if (l.code != 'en') expect(L10n.tables.containsKey(l.code), true, reason: l.code);
    }
  });
}
