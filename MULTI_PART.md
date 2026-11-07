# Movies split over several files

`Gone With the Wind (1939) - Disk1.mkv` + `... - Disk2.mkv` in one folder are ONE movie, not two movies (and not a "Duplicate").

- **Naming rule** (`backend/part_names.h`): the name ends with `cd`, `dvd`, `disc`, `disk`, `part` or `pt` + a number, after a space, dot,
  underscore, dash or bracket. `Movie - Disk1`, `Movie.CD2`, `Movie (1999) [Part 2]` match; `Dune Part Two (2024)` and
  `... - Part 1 (2010)` (the marker is not last) do not.
- **Grouping** (`MediaScanner::groupParts`): files of one folder with the same name apart from the marker, numbered from 1 with no number
  twice. A lone `Disk1`, or parts that do not start at 1, stay ordinary movies. Only the first part is listed (library, search,
  Duplicates); the others are reached through it.
- **Playing**: `GET /api/parts/<id>` gives the ids in order; `playMedia` opens them as one `edl://` address (libmpv plays them back to back as
  one timeline: one seek bar, one resume point on the first part's id).
- Tests: `g++ -std=c++17 -o part_names_test part_names_test.cpp && ./part_names_test`
- Not covered: files whose names carry no year (they are "Unknown", not movies, so they are not grouped), and parts in different folders.
