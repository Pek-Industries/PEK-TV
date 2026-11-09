# PEK TV

A media center with a sandboxed plugin system, network library support and a TV-first interface. It is in beta, so expect rough edges.

Website:
https://pekindustries.com

## Screenshots

PEK TV running at 1920x1080.

| | |
|---|---|
| ![Dashboard](assets/screenshots/dashboard.png)<br>**Dashboard** | ![TV Shows](assets/screenshots/tv-shows.png)<br>**TV Shows library** |
| ![Show page](assets/screenshots/show-page.png)<br>**Show page** | ![Episode details](assets/screenshots/episode-details.png)<br>**Episode details** |
| ![Settings](assets/screenshots/settings.png)<br>**Settings** | ![Music library](assets/screenshots/music.png)<br>**Music library** |
| ![Now Playing](assets/screenshots/music-now-playing.png)<br>**Music: Now Playing** | |

> **About the artwork in these screenshots.** The movie and show posters, episode stills and album covers shown are **stand-ins**: plain generated gradient images with a title on them, made for these screenshots. They are not the official artwork. Real posters, stills and album covers are copyrighted by their owners, so none are included in this repository. The titles, descriptions, episode text, artist names and album and song titles shown are invented sample entries for demonstration only. All titles and names mentioned are the property of their respective owners, and PEK TV is not affiliated with or endorsed by them. In normal use PEK TV shows artwork from your own files or fetches it from TMDB for your own library.

## What it does

- **Your library, everywhere:** local folders and network shares (SMB, NFS, FTP, WebDAV, UPnP/DLNA). Reads Kodi-style NFO files and artwork first, and asks TMDb only for what is missing.
- **A player that stays out of the way:** libmpv. Automatic subtitles, Skip Intro / Skip Recap, and an Up Next card.
- **Music from your own folders:** albums, artists, songs, playlists and search over the same local and network folders. Tags and cover art are read from the files; shuffle, repeat, a queue and a player bar. Songs play in libmpv on Android. Files that will not open (for example a 0-byte or damaged file) are marked "Can't be played" and skipped, and a home-screen widget shows the song that is playing (phones and tablets). See `MUSIC.md`.
- **Built for the couch:** D-pad, remote and gamepad support, with a 10-foot look.
- **DVD and ISO playback:** a DVD image (`.iso`) or a ripped DVD folder (`VIDEO_TS`) in your library plays as one movie, with a title picker for discs that have a menu or extras. Physical discs are not supported yet. See `DVD.md`.
- **Discord Rich Presence:** link Discord and your profile shows what you are watching, with the elapsed time (a button on phones, a QR code on TV; titles can be hidden). Android only for now. See `DISCORD.md`.
- **Phone remote:** pair an Android phone once with a 6-digit code and use it as the TV's remote and keyboard.
- **Search and filters:** Movies and TV Shows search by title, actor, director, genre, studio or year, with sort and filter drop-downs. Movies split over several files show up as one title (`MULTI_PART.md`).
- **Sound controls:** audio delay, volume boost, night mode, dialogue boost, bass / treble and a stereo downmix for video and music.
- **A dashboard you design:** widgets you choose and order, saved per profile.
- **Profiles and PEK Cloud:** profiles with their own history and favorites, plus optional paid cloud backup and sync (monthly, yearly or lifetime; see the Plans page on the website).
- **Skins:** install a skin from a `.zip`. Skins cannot run code or reach the network.
- **Sandboxed plugins:** plugins declare what they may do and run in a locked-down sandbox.

See `PLUGINS.md`, `SKINS.md`, `SUBTITLES.md`, `LOCAL_METADATA.md`, `MUSIC.md`, `DVD.md`, `DISCORD.md` and `MULTI_PART.md` for details.

## Project layout

- `flutter_ui/`: the app's screens (Flutter). The only UI.
- `backend/`: the C++ server (library scanner, network sources, music, subtitles, and a torrent engine that only plugins can start).
- `android/`: the Android app (start-up, libmpv player, Python plugin host) and the GitHub Actions build.
- `plugins/`, `skins/`: built-in plugins and skins (Weather, TMDb Discover, Skin maker). Plugins are only ever installed from `.PEK` files; build one with `python tools/pektool.py --official pack plugins/<id> --clean -o dist/<id>.PEK` (`dist/` is not committed).
- The Cloudflare workers (accounts and sync, plugin store, billing) are run by PEK Industries. They are separate, proprietary software and are not in this repository. `CLOUD_API.md` lists what the app calls.
- `assets/`: branding artwork: launcher icon, TV banner, splash videos (`assets/android/res`) and README screenshots.
- `tools/`: helper scripts (`make_skin.py`, `sync_providers.js` with `providers.json`).

## Contributing

See `CONTRIBUTING.md` for how to report bugs and send changes. The Android app has its own guide in `android/CONTRIBUTING.md`.

## Legal

The PEK TV app in this repository is free software under the GNU Affero General Public License v3.0 (AGPL-3.0). See the `LICENCE` file. You may use, study, change and share it under that licence, and if you run a modified version as a network service, you must offer its source to the people using it. PEK Cloud (accounts, backup and sync, the plugin store and billing) is separate software that PEK Industries runs on its own servers. Its server code is proprietary, is not part of this repository and is not covered by the AGPL. The app works without it. The names and logos "PEK" and "PEK TV" are trademarks of PEK Industries and are not covered by the licence.

PEK Industries is not associated with any illegal activity involving torrents. PEK TV does not host, provide or link to any content, and ships with no search provider or index. You are responsible for what you play.

This product uses the TMDB API but is not endorsed or certified by TMDB. Streaming availability data provided by JustWatch.
