import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/cold_history.dart';

Map<String, dynamic> entry(String key, int at, {int count = 1, int? updated}) =>
    {'key': key, 'kind': 'movie', 'title': key, 'year': 2020, 'season': 0, 'episode': 0, 'at': at, 'count': count, 'updated': updated ?? at};

void main() {
  late Directory dir;
  final y2024 = DateTime.utc(2024, 6, 1).millisecondsSinceEpoch;
  final y2025 = DateTime.utc(2025, 6, 1).millisecondsSinceEpoch;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cold_history_test');
    await ColdHistory.initAt(dir);
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('entries are stored per profile and year, and survive a restart', () async {
    ColdHistory.putAll('p1', {'m|a|2020': entry('m|a|2020', y2024), 'm|b|2020': entry('m|b|2020', y2025)});
    expect(ColdHistory.count('p1'), 2);
    expect(dir.listSync().map((f) => f.uri.pathSegments.last).toSet(), {'p1__2024.gz', 'p1__2025.gz'});
    await ColdHistory.initAt(dir); // forgets memory, reads the files again
    expect(ColdHistory.get('p1', 'm|a|2020')!['at'], y2024);
    expect(ColdHistory.get('p1', 'm|b|2020')!['at'], y2025);
    expect(ColdHistory.count('p2'), 0);
  });

  test('only a newer entry replaces a cold one', () {
    ColdHistory.putAll('p1', {'k': entry('k', y2024, count: 1, updated: 100)});
    expect(ColdHistory.putAll('p1', {'k': entry('k', y2024, count: 9, updated: 50)}), 0);
    expect(ColdHistory.get('p1', 'k')!['count'], 1);
    expect(ColdHistory.putAll('p1', {'k': entry('k', y2024, count: 3, updated: 200)}), 1);
    expect(ColdHistory.get('p1', 'k')!['count'], 3);
  });

  test('an entry that moves to another year leaves its old file', () {
    ColdHistory.putAll('p1', {'k': entry('k', y2024, updated: 100)});
    ColdHistory.putAll('p1', {'k': entry('k', y2025, updated: 200)});
    expect(dir.listSync().map((f) => f.uri.pathSegments.last).toSet(), {'p1__2025.gz'});
    expect(ColdHistory.count('p1'), 1);
  });

  test('removal markers are kept and profiles stay apart', () {
    ColdHistory.putAll('p1', {'gone': {'deleted': 1, 'updated': y2024}});
    ColdHistory.putAll('p10', {'other': entry('other', y2024)});
    expect(ColdHistory.get('p1', 'gone')!['deleted'], 1);
    expect(ColdHistory.get('p1', 'other'), isNull);
    expect(ColdHistory.count('p10'), 1);
  });

  test('wipe removes one profile, wipeAll removes everything', () {
    ColdHistory.putAll('p1', {'a': entry('a', y2024)});
    ColdHistory.putAll('p2', {'b': entry('b', y2024)});
    ColdHistory.wipe('p1');
    expect(ColdHistory.count('p1'), 0);
    expect(ColdHistory.count('p2'), 1);
    ColdHistory.wipeAll();
    expect(dir.listSync(), isEmpty);
  });

  test('version changes whenever the cold history does', () {
    final v = ColdHistory.version;
    ColdHistory.putAll('p1', {'a': entry('a', y2024)});
    expect(ColdHistory.version, greaterThan(v));
  });
}
