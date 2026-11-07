# DVD playback

PEK TV plays DVDs: a folder that holds `VIDEO_TS/`, or a `.iso` image of a DVD-Video disc.

## What is in the box

- **`android/app/libs/libmpv-release.aar`** - a libmpv build with DVD support (libdvdnav, libdvdread, libdvdcss). It has the same
  `dev.jdtech.mpv.MPVLib` API as the Maven build, so `MpvController.kt` did not need a new player. `app/build.gradle` uses it when the
  file exists and falls back to `dev.jdtech.mpv:libmpv:1.0.0` (no DVD) when it does not, so **the .aar has to be in git** (48 MB, under
  GitHub's 100 MB limit) for CI builds to get DVD.
- **`backend/dvd_info.h`** - finds discs and reads their IFO tables: titles, lengths, chapters, angles, the longest title, and whether
  the disc has its own menu. Header only, no new native dependency. `backend/dvd_test.cpp` tests it:
  `g++ -std=c++17 -Wall -Wextra -o dvd_test dvd_test.cpp && ./dvd_test`
- **Library scan** (`media_scanner.cpp`): a folder with VIDEO_TS (any letter case) or a `.iso` that is a DVD-Video image becomes ONE movie
  (named from its folder / file name, year picked out of it, no ffprobe). Other `.iso` files are ignored.
- **`GET /api/dvd/<id>`** (`playback.cpp`): `{"dvd":false}` for a normal file, otherwise the disc description. `/api/stream/<id>` answers 409
  for a disc (it is not one file).
- **Player**: `playMedia` asks `/api/dvd/<id>` for a movie; a disc goes to `playDvd` (`flutter_ui/lib/src/dvd.dart`), which opens
  `PlayerScreen(url: 'dvd://<title>', dvdDevice: ...)`. `MpvController` sets mpv's `dvd-device` and loads `dvd://<title>`.

## Menus - what works and what does not

**Detected: yes. The original interactive menu: no.** `hasMenu` is true when the disc has menu pages and `VIDEO_TS.VOB` is really there
(rips often delete it). The libmpv in the .aar plays titles and chapters but has no menu navigation: mpv removed DVD menu support
upstream, and this build has no menu / button calls in it. So a disc with a menu (or with several real titles) first shows a title
picker - **Play movie** (the longest title) and the other titles with length and chapter count - instead of the disc's own menu.
Real menu navigation would need a different engine (for example libvlc) or an app-drawn menu on top of libdvdnav.

## Good to know

- The disc must be on the phone / SD card (a local path): libdvdread opens files directly, so DVDs on SMB / NFS / FTP shares are not
  picked up. Shared storage also needs "All files access" (the same permission the library scan already uses).
- Resume Watching is kept for the main movie only; extras always start at 0.
- Audio / subtitle tracks and chapters come from the disc through mpv's normal track list. DVD subtitles are pictures, so they need
  the normal renderer; the player switches out of Smooth mode when one is chosen (as it already does for other pictures-subtitles).
- libdvdcss is inside the .aar and handles copy-protected discs; whether you may use it on your own discs depends on the country.
