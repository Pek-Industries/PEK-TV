# Contributing to PEK TV for Android

This covers the `android/` folder and the Android build. Read the repository's `CONTRIBUTING.md` first for the licence
(AGPL-3.0), how to open issues and pull requests, and the documentation rules. Everything there applies here too.

## What is in `android/`

| Path | What it is |
|---|---|
| `app/src/main/java/com/pektv/app/` | Kotlin: start-up, splash, the mpv video and audio players, the music service and widget, the updater, device profile. |
| `app/src/flutter/java/com/pektv/app/flutter/` | Kotlin that hosts the Flutter UI (`FlutterHostActivity`) and its platform channels (`pek/mpv`, `pek/music`, `pek/host`, ...). |
| `app/src/main/cpp/` | The JNI layer (`jni_entry.cpp`), the Discord presence code and the CMake build for the C++ backend in `backend/`. |
| `app/src/main/python/` | The Python plugin host (Chaquopy): `pek_runner.py`, `pek_ui.py`, `pek_flutter.py`, `pek_providers.py`, `pek_epg.py`. |
| `app/src/main/res/` | Layouts, drawables, themes and the music widget. |
| `app/libs/` | Optional `discord_partner_sdk.aar` (see `DISCORD.md`). |
| `scripts/` | `build-openssl.sh` and `fetch-sqlite.sh`. |

The Flutter screens are in `flutter_ui/`, not here. A change that touches both sides (a new platform channel, for
example) belongs in one pull request.

## What you need

- JDK 17.
- Gradle. The repository has no Gradle wrapper; CI uses the version set in `.github/workflows/build_android.yml`
  (Android Gradle Plugin 8.7 needs Gradle 8.9 or newer).
- The Android SDK with platform 36 and build-tools 36. `minSdk` is 26 (Android 8.0), `compileSdk` and `targetSdk` are 36.
- The NDK version named by `ndkVersion` in `android/app/build.gradle`.
- Flutter (stable channel) to build `flutter_ui/`.
- To build the native pieces: OpenSSL and SQLite, built by the two scripts in `android/scripts/`. SMB (libsmb2) and
  NFS (libnfs) are optional. Torrent streaming needs libtorrent (branch `RC_2_0`) and the Boost 1.86.0 headers.

`.github/workflows/build_android.yml` is the reference for the exact steps. If these notes and the workflow ever
disagree, the workflow is right; please fix the notes.

## Building

The workflow builds one APK per CPU type, because Chaquopy needs `ndk.abiFilters` and that cannot be combined with APK
splits. Mirror it locally:

1. In `flutter_ui/` run `flutter pub get`.
2. Copy `plugins/` and `skins/` into `android/app/src/main/assets/hesper/`, add `cacert.pem` there, and remove any
   `__pycache__` folders and `plugins/*/data`. This is the "Stage app assets" step in the workflow.
3. Run `bash android/scripts/build-openssl.sh` and `bash android/scripts/fetch-sqlite.sh`.
4. Optional: clone libsmb2 and libnfs into `android/`, and for torrents libtorrent and the Boost headers (see the
   workflow for the exact layout).
5. From `android/`, run Gradle once per CPU type:

   ```
   gradle assembleDebug -PpekAbi=arm64-v8a
   gradle assembleDebug -PpekAbi=armeabi-v7a
   ```

   Add `-PpekTorrent=true` to build the torrent engine in, and `-PpekVersionName=x.y.z` to set the version name.

The debug build installs next to a release build (its application id ends in `.debug`), so you can test without
removing the real app. Debug builds, `-dev.N` builds and local builds never show the update screen.

You can also run the workflow from the Actions tab (`workflow_dispatch`) on your fork and download the debug APK.

## Test on real devices

- Test on a phone **and** a TV or TV emulator. D-pad, remote and gamepad focus matter as much as touch.
- A 32-bit and a 64-bit build both ship. If you touch native code, check both ABIs.
- Android 8.0 (API 26) is the lowest supported version; avoid APIs above that without a version check.
- Say in your pull request which devices and Android versions you tested on.

## Signing and releases

- Never commit a keystore, passwords or API keys. Release signing happens only in CI from repository secrets
  (`PEK_KEYSTORE_BASE64`, `PEK_KEYSTORE_PASSWORD`, `PEK_KEY_ALIAS`, `PEK_KEY_PASSWORD`). A local release build with no
  keystore is signed with the debug key and is not for distribution.
- Contributors do not publish releases. If you are a maintainer, the steps are in `UPDATES.md`: raise `pekBaseCode` in
  `android/app/build.gradle`, update `flutter_ui/lib/src/whats_new.dart` and `version:` in `flutter_ui/pubspec.yaml`,
  then push the tag. The release must always be signed with the same key, or installed apps cannot update.

## Rules for Android changes

- **Permissions and the manifest:** add a permission only when a feature needs it, and say why in the pull request.
- **Plugin sandbox:** the Python host and its guard are security code. Do not widen what plugins may import or reach
  without discussing it in an issue first; see `PLUGINS.md`.
- **Torrents:** the engine starts only for a stream that a plugin with the `torrent` permission hands over. Do not add
  a way to start one from the app itself.
- **Dependencies:** a new library or native dependency must be AGPL-compatible and listed in Settings > Open source
  (`flutter_ui/lib/src/open_source.dart`). The Discord Social SDK is proprietary and stays optional.
- **Privacy:** do not add analytics or any network call that is not described in the docs and the website's privacy
  page. Keep the privacy text in step if what leaves the device changes.
- **Docs:** if you change something described in `UPDATES.md`, `FLUTTER.md`, `FLUTTER_PLUGINS.md`, `MUSIC.md` or
  `DISCORD.md`, update it in the same pull request.
