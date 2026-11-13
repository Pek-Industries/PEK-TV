import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/api.dart';
import 'package:pek_tv_ui/src/fix_match.dart';

void main() {
  group('splitTitleYear', () {
    test('takes the year off a show that shares its name', () {
      final r = splitTitleYear('Battlestar Galactica (2003)', 0);
      expect(r.name, 'Battlestar Galactica');
      expect(r.year, 2003);
    });

    test('a year that is passed in wins over the one in the title', () {
      expect(splitTitleYear('Dredd (1995)', 2012).year, 2012);
    });

    test('a plain title stays as it is', () {
      final r = splitTitleYear('Dredd', 2012);
      expect(r.name, 'Dredd');
      expect(r.year, 2012);
    });

    test('a title that is only a year is not emptied', () {
      expect(splitTitleYear('(2012)', 0).name, '(2012)');
      expect(splitTitleYear('2012', 0).name, '2012');
    });
  });

  group('MatchCandidate', () {
    test('reads a search result', () {
      final c = MatchCandidate.fromJson({'id': '49049', 'title': 'Dredd', 'year': 2012, 'poster': 'https://x/p.jpg', 'overview': 'A cop.'});
      expect(c.id, '49049');
      expect(c.label, 'Dredd (2012)');
    });

    test('reads the saved match (tmdb_id) and a title with no year', () {
      final c = MatchCandidate.fromJson({'pinned': true, 'tmdb_id': '9301', 'title': 'Judge Dredd', 'year': 0});
      expect(c.id, '9301');
      expect(c.label, 'Judge Dredd');
    });
  });
}
