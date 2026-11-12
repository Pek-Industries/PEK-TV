import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/welcome.dart';

void main() {
  test('every slide has a title and a plain sentence or two', () {
    expect(welcomeSlides.length, greaterThan(3));
    for (final s in welcomeSlides) {
      expect(s.title.trim(), isNotEmpty);
      expect(s.body.trim().length, greaterThan(20));
    }
  });

  test('each screenshot exists for TVs and for phones', () {
    for (final s in welcomeSlides.where((s) => s.shot != null)) {
      expect(File('assets/welcome/${s.shot}.jpg').existsSync(), isTrue, reason: '${s.shot}.jpg (TV)');
      expect(File('assets/welcome/${s.shot}-portrait.jpg').existsSync(), isTrue, reason: '${s.shot}-portrait.jpg (phone)');
    }
  });

  test('one screenshot per feature: no picture is used twice', () {
    final shots = [for (final s in welcomeSlides) if (s.shot != null) s.shot];
    expect(shots.toSet().length, shots.length);
  });
}
