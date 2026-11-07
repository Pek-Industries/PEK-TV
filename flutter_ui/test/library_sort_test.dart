import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/library_sort.dart';
import 'package:pek_tv_ui/src/watch_filter.dart';

void main() {
  // (title, year)
  const films = [('The Matrix', 1999), ('Alien', 1979), ('Heat', 1995), ('Untitled', 0), ('A Bug\'s Life', 1998)];
  List<String> names(List<(String, int)> l) => [for (final f in l) f.$1];
  List<(String, int)> sort(LibrarySort s, {int seed = 1}) => sortedBy<(String, int)>(films, s, seed, title: (f) => f.$1, year: (f) => f.$2);

  test('standard keeps the order it was given', () {
    expect(names(sort(LibrarySort.standard)), names(films));
  });

  test('A-Z ignores a leading The / A / An, and Z-A reverses it', () {
    expect(names(sort(LibrarySort.titleAz)), ['Alien', "A Bug's Life", 'Heat', 'The Matrix', 'Untitled']);
    expect(names(sort(LibrarySort.titleZa)), ['Untitled', 'The Matrix', 'Heat', "A Bug's Life", 'Alien']);
  });

  test('year sorts put a title with no year last, whichever way the years run', () {
    expect(names(sort(LibrarySort.yearNew)), ['The Matrix', "A Bug's Life", 'Heat', 'Alien', 'Untitled']);
    expect(names(sort(LibrarySort.yearOld)), ['Alien', 'Heat', "A Bug's Life", 'The Matrix', 'Untitled']);
  });

  test('oldest watched is the history turned around', () {
    expect(names(sort(LibrarySort.oldestFirst)), names(films.reversed.toList()));
  });

  test('random keeps every title, repeats for the same seed and does not touch the input', () {
    final a = sort(LibrarySort.random, seed: 7);
    final b = sort(LibrarySort.random, seed: 7);
    expect(names(a), names(b));
    expect(names(a)..sort(), names(films)..sort());
    expect(names(films), ['The Matrix', 'Alien', 'Heat', 'Untitled', "A Bug's Life"]);
    // Across many seeds it is not always the same order.
    final orders = {for (var s = 0; s < 20; s++) names(sort(LibrarySort.random, seed: s)).join('|')};
    expect(orders.length, greaterThan(1));
  });

  test('ties keep their old order', () {
    const same = [('B', 2000), ('A', 2000), ('C', 2000)];
    final out = sortedBy<(String, int)>(same, LibrarySort.yearNew, 0, title: (f) => f.$1, year: (f) => f.$2);
    expect([for (final f in out) f.$1], ['A', 'B', 'C']); // same year: then by title
  });

  test('controller: active, random reseeds, clear resets', () {
    final f = LibraryFilters(sorts: LibrarySort.history);
    expect(f.active, isFalse);
    f.setWatch(WatchFilter.watched);
    expect(f.active, isTrue);
    final seed = f.seed;
    f.setSort(LibrarySort.random);
    expect(f.sort, LibrarySort.random);
    expect(f.seed, isNot(seed)); // 1 in a billion this ties; picking Random is a new shuffle
    final again = f.seed;
    f.reshuffle();
    expect(f.seed, isNot(again));
    f.clear();
    expect(f.active, isFalse);
    expect(f.sort, LibrarySort.standard);
    expect(f.pending, isFalse);
  });

  test('controller: with no genre or actor everything passes', () {
    final f = LibraryFilters();
    expect(f.pending, isFalse);
    expect(f.failed, isFalse);
  });
}
