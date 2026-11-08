import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/remote_pairing.dart';

void main() {
  late DateTime now;
  late RemotePairing p;

  setUp(() {
    now = DateTime(2026, 1, 1, 12);
    p = RemotePairing(random: Random(7), now: () => now);
  });

  test('nobody can pair while pairing is closed', () {
    expect(p.isOpen, false);
    expect(p.tryPair('a', 'Phone', '123456'), isNull);
  });

  test('right code gives a token that works, and the code works once', () {
    final pin = p.open();
    expect(pin.length, 6);
    final token = p.tryPair('a', 'Sam phone', pin)!;
    expect(p.checkToken('a', token), true);
    expect(p.checkToken('a', 'nope'), false);
    expect(p.checkToken('b', token), false);
    expect(p.isOpen, false);
    expect(p.tryPair('b', 'Other', pin), isNull);
  });

  test('five wrong guesses close pairing, even for the right code afterwards', () {
    final pin = p.open();
    final wrong = pin == '000000' ? '111111' : '000000';
    for (var i = 0; i < 5; i++) {
      expect(p.tryPair('a', 'x', wrong), isNull);
    }
    expect(p.isOpen, false);
    expect(p.tryPair('a', 'x', pin), isNull);
  });

  test('the code runs out after five minutes', () {
    final pin = p.open();
    now = now.add(const Duration(minutes: 5, seconds: 1));
    expect(p.tryPair('a', 'x', pin), isNull);
  });

  test('only the hash is stored, and it survives save and load', () {
    final pin = p.open();
    final token = p.tryPair('a', 'Sam phone', pin)!;
    final json = p.toJson();
    expect(json.contains(token), false);
    final q = RemotePairing()..load(json);
    expect(q.checkToken('a', token), true);
    expect(q.devices.single.name, 'Sam phone');
  });

  test('revoking a phone locks it out; the oldest of nine is dropped', () {
    final tokens = <String, String>{};
    for (var i = 0; i < 9; i++) {
      tokens['d$i'] = p.tryPair('d$i', 'Phone $i', p.open())!;
    }
    expect(p.devices.length, RemotePairing.maxDevices);
    expect(p.checkToken('d0', tokens['d0']!), false);
    expect(p.checkToken('d8', tokens['d8']!), true);
    p.revoke('d8');
    expect(p.checkToken('d8', tokens['d8']!), false);
  });

  test('bad saved data is ignored', () {
    p.load('not json');
    expect(p.devices, isEmpty);
    p.load('[{"id":1},{"id":"x","hash":"h"}]');
    expect(p.devices.length, 1);
  });
}
