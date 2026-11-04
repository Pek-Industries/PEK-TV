# Contributing to PEK TV

Thanks for helping. PEK TV is a media center with a sandboxed plugin system, network library support and a TV-first
interface. It is in beta, so there is plenty to fix and polish.

## Licence

PEK TV is free software under the GNU Affero General Public License v3.0 (AGPL-3.0); see the `LICENCE` file.

- By sending a contribution (a pull request, a patch, a plugin or skin added to this repository) you agree that it is
  licensed under the AGPL-3.0, the same as the rest of the project.
- Only submit work you wrote or have the right to submit under that licence. Do not copy code from projects whose
  licence is not compatible with the AGPL-3.0.
- The names and logos "PEK" and "PEK TV" are trademarks of PEK Industries and are not covered by the licence. Forks
  must not present themselves as the official app.
- If you run a modified version as a network service (for example your own cloud workers), the AGPL requires you to
  offer its source to the people using it.

## Where things live

| Folder | What it is |
|---|---|
| `flutter_ui/` | The app's screens (Flutter). The only UI. |
| `backend/` | The C++ server: library scanner, network sources, music, subtitles, torrent engine (plugins only). |
| `android/` | The Android app and its build. See `android/CONTRIBUTING.md`. |
| `plugins/`, `skins/` | Built-in plugins and skins. |
| `tools/` | Helper scripts (`pektool.py`, `make_skin.py`, `sync_providers.js`) and the cloud tests. |
| `assets/` | Branding artwork and README screenshots. |

More platforms will get their own `CONTRIBUTING.md` inside their folder. This file covers what applies everywhere.

The reference docs are in the repository root: `PLUGINS.md`, `FLUTTER_PLUGINS.md`, `SKINS.md`, `FLUTTER.md`, `MUSIC.md`,
`SUBTITLES.md`, `LOCAL_METADATA.md`, `PEK_FORMAT.md`, `UPDATES.md` and `DISCORD.md`.

## Before you start

1. **Bugs:** open an issue with the app version (Settings), your device and Android version, and the steps to
   reproduce. Say whether it happens on a TV, a phone or both.
2. **Features and larger changes:** open an issue first so the direction can be agreed before you spend time on it.
3. **Security problems:** do not post them in a public issue. Email <pektv@pekindustries.com>.

## Making a change

1. Fork the repository and make a branch from `main`.
2. Keep the change focused: one fix or one feature per pull request.
3. Follow the style of the code around you. Do not reformat files you are not changing.
4. Test it. The Flutter tests are in `flutter_ui/test` (`flutter test`), the C++ tests are in `backend/*_test.cpp`, and
   the cloud tests are in the separate `pek-cloud` repo. Add or update a test when you change behaviour that has one.
5. Update the documentation in the same pull request (see below).
6. Open the pull request and say what changed, why, and how you tested it (device, Android version, TV or phone).

## Documentation is part of the change

The repository is the single source of truth. The website at pekindustries.com/pektv builds its documentation pages
from the `.md` files in this repository, so a doc fixed here is fixed there. Do not keep a second copy of a doc
anywhere else.

- If you change behaviour, update the doc that describes it, in the same pull request.
- If you add a dependency, add it to Settings > Open source (`flutter_ui/lib/src/open_source.dart`) with its licence.
  Do not add a dependency whose licence is incompatible with the AGPL-3.0.
- If you change the licence wording anywhere, it must say AGPL-3.0 and match the `LICENCE` file.

## Artwork and content

Do not add real posters, stills, album covers, logos or trademarked artwork you do not own. Screenshots in this
repository use generated stand-ins. PEK TV does not host, provide or link to any content, and ships with no search
provider or index; contributions must not add one.

## Plugins and skins

Plugins run in a sandbox and declare what they may do. Read `PLUGINS.md` and `FLUTTER_PLUGINS.md` first. Plugins are
installed only from `.PEK` files; build one with
`python tools/pektool.py --official pack plugins/<id> --clean -o dist/<id>.PEK`.
Skins are data only and cannot run code or reach the network; see `SKINS.md`.

## Platforms

- Android: `android/CONTRIBUTING.md`
