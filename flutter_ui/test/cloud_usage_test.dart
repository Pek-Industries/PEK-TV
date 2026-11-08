import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/cloud_usage.dart';

void main() {
  test('UsagePart reads the cloud numbers', () {
    final p = UsagePart.fromJson({'count': 12, 'max': 30, 'bytes': 6291456, 'maxBytes': 62914560});
    expect(p.count, 12);
    expect(p.max, 30);
    expect(p.full, isFalse);
    expect(p.fraction, closeTo(0.4, 0.001)); // 12/30 items beats 6 MB / 60 MB
  });

  test('the bar follows whichever is fuller, items or space', () {
    const bytes = UsagePart(count: 3, max: 30, bytes: 54 * 1048576, maxBytes: 60 * 1048576);
    expect(bytes.fraction, closeTo(0.9, 0.001));
    expect(bytes.full, isFalse);
    const done = UsagePart(count: 30, max: 30, bytes: 1000, maxBytes: 60 * 1048576);
    expect(done.full, isTrue);
    expect(done.fraction, 1.0);
  });

  test('skins: full at 100, never over the bar', () {
    expect(const UsagePart(count: 99, max: 100).full, isFalse);
    expect(const UsagePart(count: 100, max: 100).full, isTrue);
    expect(const UsagePart(count: 140, max: 100).fraction, 1.0);
  });

  test('missing or odd data does not crash', () {
    expect(UsagePart.fromJson(null).max, 0);
    expect(UsagePart.fromJson({'count': '7', 'max': 'x'}).count, 7);
  });
}
