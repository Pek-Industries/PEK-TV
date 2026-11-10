import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/voice_match.dart';

const lib = ['The Bear', 'Severance', 'Oppenheimer', 'The Matrix', 'The Matrix Reloaded', 'Lioness', 'Amélie', 'Se7en'];

void main() {
  test('the same title, any capitals', () {
    expect(bestTitle('lioness', lib)?.title, 'Lioness');
    expect(bestTitle('THE MATRIX', lib)?.title, 'The Matrix');
  });
  test('the whole title beats a longer one that starts the same', () {
    final m = bestTitle('the matrix', lib)!;
    expect(m.title, 'The Matrix');
    expect(m.exact, isTrue);
  });
  test('a misheard letter', () {
    expect(bestTitle('the beer', lib)?.title, 'The Bear');
    expect(bestTitle('severence', lib)?.title, 'Severance');
  });
  test('one word heard as several', () {
    expect(bestTitle('open her mer', lib)?.title, 'Oppenheimer');
  });
  test('accents are ignored', () {
    expect(bestTitle('amelie', lib)?.title, 'Amélie');
  });
  test('no match keeps the spoken words', () {
    expect(bestTitle('zzzzzz', lib), isNull);
    expect(bestTitle('', lib), isNull);
  });
  test('two equally close titles are not guessed', () {
    expect(bestTitle('bean', ['Bear', 'Beam']), isNull);
    expect(bestTitle('bean', ['Bear', 'Bean Counters'])?.title, 'Bean Counters');
  });
  test('short words are not matched loosely', () {
    expect(bestTitle('up', ['Us']), isNull);
  });
}
