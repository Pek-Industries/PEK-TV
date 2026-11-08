# Local metadata: NFO files and artwork

PEK TV reads the small files that Kodi, Radarr, Sonarr, tinyMediaManager and similar tools put next to your
videos. They work on local folders and on network sources (SMB, NFS, FTP, WebDAV, UPnP), need no internet, and
win over the file name and over TMDb. TMDb is only asked for what is still missing.

Files are picked up by the normal scan (**Rescan** after adding or editing them). Nothing is written to your folders.

## NFO files (.nfo)

| Where | What it is |
|---|---|
| `Movie Name (2001).nfo` next to `Movie Name (2001).mkv` | movie: `<movie>` with `title`, `year` (or `premiered`), `plot` (or `outline`), plus the search fields below |
| `movie.nfo` in a folder that holds one video | same, for that video |
| `Show S01E02.nfo` next to the episode | `<episodedetails>` with `title`, `showtitle`, `season`, `episode`, `plot` |
| `tvshow.nfo` in the show folder (the parent of the `Season N` folders) | `<tvshow>` with `title`, `plot` |

- An NFO fixes files that would otherwise be "Unknown" or mis-named: the title, year, show, season and episode
  come from the file, not from the file name.
- Show name priority: the episode NFO's `showtitle`, then `tvshow.nfo`'s `title`, then tags / the file name.
- Files holding only a link (for example a themoviedb.org address) are ignored.
- Only the first `<episodedetails>` in a file is read.

## Searching and browsing by actor, genre, year ...

After every scan PEK TV also reads these fields from the movie and `tvshow.nfo` files and keeps them in its library
database (`library.db`): `genre`, `actor` (`name`, `role`), `director`, `studio`, `rating` (or `ratings`), `runtime`,
`mpaa` and `set` (collection). Only titles that have an NFO have them; the title and year work for every file. The
library **Search** has Genre, Year, Actor and Director buttons next to the box (Year offers decades and, below them, single years; the
Actor and Director lists are narrowed by typing part of a name in the box), and typing "tom hanks", "drama 1995" or
"nolan" finds titles by cast, genre, year, director, studio or collection (accents and capitals ignored). Details are
read once per title and again only when its NFO changes (local folders) or the video changes (network sources), so a
rescan stays quick; while the first read is running the Genre / Actor / Director lists say how far it is.
API: `GET /api/library/search` and `GET /api/library/facets` (see `server.cpp`).

## Artwork (images)

Image types: `.jpg`, `.jpeg`, `.png`, `.webp`, `.tbn`. Names are not case sensitive.

| Image | Names looked for |
|---|---|
| Movie poster | `<video name>-poster.jpg`, `<video name>.jpg`; and, when the folder holds only that one video: `poster.jpg`, `folder.jpg`, `cover.jpg`, `movie.jpg` |
| Movie background | `<video name>-fanart.jpg`, `-backdrop`, `-background`; single-video folders also: `fanart.jpg`, `backdrop.jpg`, `background.jpg` |
| Episode picture | `<video name>-thumb.jpg`, `<video name>.jpg` |
| Show poster | `poster.jpg`, `folder.jpg`, `cover.jpg`, `show.jpg` in the show folder |
| Show background | `fanart.jpg`, `backdrop.jpg`, `background.jpg` in the show folder |

Folder-wide names such as `poster.jpg` are ignored when a folder holds several videos, so a loose collection of
movies in one folder never shares one poster. Images over 12 MB are ignored.

## Not supported (yet)

Season posters, actor photos, clear logos, NFOs that only carry IDs or links, and writing NFO files.

## Sorting and combining filters (Movies, TV Shows, Watch History)

The Movies and TV Shows tabs and Watch History share one filter bar of drop-downs (`library_sort.dart`):

| Drop-down | Choices |
|---|---|
| Show | All, Unwatched, Watching, Watched (Watch History has no Unwatched: everything there has been started) |
| Sort by | Default, Random, Title A–Z, Title Z–A, Year newest / oldest, Rating (highest first), Recently added, Runtime (longest / shortest first) (movies; TV Shows have Default, Random, A–Z, Z–A, Rating, Recently added); Recently watched, Oldest watched, Random, A–Z, Z–A (Watch History) |
| Genre | Any genre, then the genres found in your .nfo files, with counts |
| Actor | Any actor, then the actors found in your .nfo files, with counts |

They combine: "Unwatched + Action + Random" lists unwatched action movies in a random order. With Random chosen, **Shuffle again**
reshuffles; the order stays put until then, even when something is marked watched. **Clear filters** puts everything back.
The Movies and TV Shows tabs remember their choices while the app runs. Genre, actor, the typed search, the extra filters
below and the Rating / Recently added / Runtime orders are answered by the server (`/api/library/search`), so they need the .nfo
details above (Recently added needs none); Show and the title / year orders work on the device.

## Posters and synopses are looked up once

PEK TV does not ask for a poster each time a card scrolls into view. A background worker in the server (`startArtWorker` in
`backend/server.cpp`) looks every movie and show up once, in this order: the poster and plot next to your files first, then TMDb
(through the Worker) for whatever is missing. The result is kept in `library.db` (table `title_art`) and sent with
`/api/movies` and `/api/shows` (`poster`, `overview`), so the grid needs no per-card requests and every later start is
instant. A title with no poster found is tried again after a day. The worker waits while a scan runs, goes at no more than
about 4 TMDb requests per second, and pauses when the Worker answers 429 (too many requests).

After every scan the worker also compares each stored title with its files (the poster file's name, size and date, and the
plot text). Only a title whose files changed (a new or replaced `poster.jpg`, an edited `.nfo`) is looked up again; the rest are
left alone. If that look-up cannot be done (no internet) the old poster stays and it is retried 10 minutes later. The poster's
address carries a `v=` version, so the app fetches a fresh copy of a changed picture.

### TMDb posters follow the same rule

A poster or synopsis that came from TMDb is also looked up once and then left alone. It is looked up again only when:

- the title's files change (you add a `poster.jpg` or `.nfo`, which then wins over TMDb),
- the title or year PEK TV asked TMDb about changes (a renamed file or a corrected year), or
- it is 30 days old: TMDb is asked again in the background, and the stored poster is replaced only if TMDb now answers with
  something different. If TMDb has nothing, or there is no internet, the old poster stays and the check is retried 10 minutes later.

Whenever a stored poster or synopsis really changes, the server's change counter (`art` in `/api/scan-status`) goes up and the
Movies / TV Shows pages read their lists again. Unchanged posters are not downloaded again; Refresh no longer wipes them.

## Search bar and extra filters on the Movies and TV Shows tabs

Both tabs have a search box (`library_search.dart`) above the filter bar. It reads the title, year and everything the title's
`.nfo` says: genres, cast, director, studio, collection, rating, runtime and certificate. **Where a title has a `.nfo`, the
`.nfo`'s title and details are used; a title without one is still found by its title and year** and just has no genre, cast or
rating to match on. Nothing here asks TMDb.

- The drop-down narrows on every letter from titles already known (the library on the device and every earlier answer), so
  there is no wait and no blank gap between letters; the server's answer (`GET /api/library/suggest`) only adds to it (cast,
  genre and studio matches, ratings) in the same order. A row says why it matched when its name is not what was typed
  (`Cast: Tom Hanks`, `Genre: Drama`), and shows the year, type and rating.
- The grid under the box follows the typed text a moment later and keeps showing its last answer until the new one arrives.
- **More filters:** Director, Studio, Collection, Rated (certificate), Decade, Year, Rating (6, 7, 8, 9 and up),
  Runtime (under 90 min, 90 min to 2 hours, over 2 hours) and Details from (has a `.nfo` / no `.nfo`). They combine with each
  other, with Show, Genre and Actor, and with the typed text; **Clear filters** empties the box too.
- **Sort by** also has Rating (highest first), Recently added and Runtime (longest / shortest first), put in order by the
  server's library database.
- API: `GET /api/library/search` takes `q`, `genre`, `actor`, `director`, `studio`, `collection`, `mpaa`, `year`, `decade`,
  `min_rating`, `min_runtime`, `max_runtime`, `nfo=with|without` and `sort=title|title_desc|year|year_asc|added|rating|runtime|runtime_asc`;
  `GET /api/library/suggest` takes the same plus `type=movies|shows|both`; `GET /api/library/facets` also lists `studios`,
  `collections`, `mpaa` and how many titles have a `.nfo`.
