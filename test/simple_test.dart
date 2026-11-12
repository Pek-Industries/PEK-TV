import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/api.dart';
import 'package:pek_tv_ui/src/recs.dart';
import 'package:pek_tv_ui/src/simple_data.dart';

Map<String, dynamic> video(String key, String type, {bool official = false, String lang = 'en', String site = 'YouTube'}) =>
    {'key': key, 'type': type, 'official': official, 'iso_639_1': lang, 'site': site};

void main() {
  group('trailer pick (Simple layout)', () {
    test('a Trailer beats a Teaser, an official one beats an unofficial one', () {
      final info = {
        'videos': {
          'results': [
            video('AAAAAAAAAAA', 'Teaser', official: true),
            video('BBBBBBBBBBB', 'Trailer'),
            video('CCCCCCCCCCC', 'Trailer', official: true),
          ],
        },
      };
      expect(SimpleMeta.pickTrailer(info), 'CCCCCCCCCCC');
    });

    test('English wins a tie; clips, other sites and bad ids are ignored', () {
      final info = {
        'videos': {
          'results': [
            video('AAAAAAAAAAA', 'Trailer', lang: 'fr'),
            video('BBBBBBBBBBB', 'Trailer'),
            video('CCCCCCCCCCC', 'Clip', official: true),
            video('DDDDDDDDDDD', 'Trailer', official: true, site: 'Vimeo'),
            video('short', 'Trailer', official: true),
          ],
        },
      };
      expect(SimpleMeta.pickTrailer(info), 'BBBBBBBBBBB');
    });

    test('nothing usable gives an empty string, never a crash', () {
      expect(SimpleMeta.pickTrailer(null), '');
      expect(SimpleMeta.pickTrailer({'videos': {'results': []}}), '');
      expect(SimpleMeta.pickTrailer({'videos': 'x'}), '');
    });
  });

  group('facts line', () {
    const movie = Movie(id: '1', title: 'Heat', year: 1995, filename: 'heat.mkv');
    test('year, two genres and the running time', () {
      const m = SimpleMeta(ok: true, genres: ['Crime', 'Drama', 'Thriller'], runtime: 170);
      expect(m.facts(const SimpleTitle.movie(movie)), '1995 \u00b7 Crime \u00b7 Drama \u00b7 2h 50m');
    });

    test('a show says how many seasons', () {
      const show = Show(title: 'Lost', episodeCount: 100, seasons: []);
      const m = SimpleMeta(ok: true, genres: ['Mystery'], seasons: 6);
      expect(m.facts(const SimpleTitle.show(show)), 'Mystery \u00b7 6 seasons');
    });
  });

  group('library lookups', () {
    final lib = SimpleLib(
      const [Movie(id: 'a', title: 'The Matrix', year: 1999, filename: 'm.mkv'), Movie(id: 'b', title: 'Heat', year: 1995, filename: 'h.mkv')],
      const [Show(title: 'Lost', episodeCount: 10, seasons: [])],
    );

    test('a recommendation is matched by its title, movie or show', () {
      expect(lib.named('the matrix', tv: false)?.movie?.id, 'a');
      expect(lib.named('LOST', tv: true)?.show?.title, 'Lost');
      expect(lib.named('Lost', tv: false), isNull);
    });

    test('search answers (file ids, show titles) become titles; unknown ones are dropped', () {
      final out = lib.fromSearch((movies: ['b', 'zzz'], shows: ['Lost', 'Nope']));
      expect(out.map((t) => t.key).toList(), ['m:b', 's:Lost']);
    });

    test('new = newest movies and shows taking turns', () {
      expect(lib.recentMixed.map((t) => t.title).toList(), ['Heat', 'Lost', 'The Matrix']);
    });

    test('a TMDb suggestion the library has is the library title; any other stays a suggestion', () {
      final inLib = lib.fromRec(const RecItem(id: 1, tv: false, title: 'heat', year: 1995, poster: '/a.jpg'));
      expect(inLib.inLibrary, isTrue);
      expect(inLib.key, 'm:b');
      final other = lib.fromRec(const RecItem(id: 2, tv: false, title: 'Alien', year: 1979, poster: '/b.jpg'));
      expect(other.inLibrary, isFalse);
      expect(other.key, 'r:m2');
      expect(other.title, 'Alien');
      expect(other.subtitle, '1979');
    });
  });
}
