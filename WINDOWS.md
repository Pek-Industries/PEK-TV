# PEK TV for Windows

The Windows app is the same Flutter UI (`flutter_ui/`) and the same C++ server (`backend/`) as Android, with its own host in
`windows/`, exactly like `android/`. Everything Windows-specific is in that folder (plus the workflow
`.github/workflows/build_windows.yml`); the only edits outside it are small, platform-neutral ones listed at the bottom.

## 32-bit and 64-bit
Android ships two apks (64-bit `arm64-v8a`, 32-bit `armeabi-v7a`). **Windows cannot ship a 32-bit build:** Flutter's Windows engine
exists only for 64-bit Intel/AMD (x64) and 64-bit ARM (arm64). So the same "one file per CPU type" split is:

| File | For |
|---|---|
| `PEK-TV-<version>-windows-x64-setup.exe`   | **the installer** for normal PCs (Intel / AMD, 64-bit) |
| `PEK-TV-<version>-windows-arm64-setup.exe` | the installer for Windows on ARM (Snapdragon / Copilot+ PCs) |
| `PEK-TV-<version>-windows-x64.zip` / `-arm64.zip` | portable copy: unzip into a folder you can write to and run `pek_tv.exe` |

Run the setup program: it installs for the current user (no administrator prompt; the wizard can switch to "all users"), adds a Start menu
entry (and an optional desktop shortcut) and an uninstaller. Data lives in `%LOCALAPPDATA%\PEK TV` and is kept when the app is uninstalled.
The file names end in `-windows-<arch>-setup.exe` / `-windows-<arch>.zip` because that is what the in-app updater looks for
(`app_update.dart`): an installed copy (it has `unins000.exe` beside the exe) updates through the setup program, a portable copy through the zip.

## What is in `windows/`
```
windows/
  runner/                    the Flutter Windows host (C++): the counterpart of FlutterHostActivity.kt + Boot.kt
    main.cpp flutter_window.* standard Flutter window, plus the call that starts the PEK host
    pek_host.*               every pek/* channel (host, plugins, output, voice, update, ...), starts the server and Python
    pek_mpv.*                pek/mpv: libmpv draws into a Flutter texture (Dart: PekVideoSurface)
    runner.exe.manifest      UTF-8 process code page (file names), per-monitor DPI
  backend/                   builds backend/ as pek_server.dll (CMake, MSYS2 clang) + dll_entry.cpp (= jni_entry.cpp)
    compat/                  POSIX shims (poll, ifaddrs, strptime, ...) so the shared backend sources are used as they are
  python/pek_host.py         runs the plugins (embeddable Python) and answers pek/plugins "call"
  installer/pek_tv.iss       the Inno Setup script (the setup program)
  scripts/                   fetch-libmpv / fetch-ffprobe / fetch-python / collect-server-deps / stage-assets / prepare-flutter-host / package / make-installer
  pek_runner.cmake           added to the generated runner CMakeLists.txt
```
`windows/flutter/`, `win32_window.*` and the rest of the standard runner are NOT stored: `scripts/prepare-flutter-host.sh` lets
`flutter create` write them into `build/windows_app/` (a copy of `flutter_ui/` without the Android `module:` setting) and puts the
files above on top. The repo's `flutter_ui/` is never changed by the Windows build.

## Platform differences (what was edited for Windows)
- **Microphone / voice control.** `record` and `sherpa_onnx` work on Windows. `pek/host micPermission` reads Windows' own microphone
  switch (Settings > Privacy & security > Microphone) and returns false when it is off (voice.dart then says "Allow the microphone").
  The phone's own recognizer is Android only (`PekPlatform.hasSystemRecognizer`), so the bundled Moonshine model always listens: it is
  copied from `voice/stt` next to the exe on first use (`installVoice`). Spoken replies without the Piper download use Windows' own
  voice (SAPI) through `pek/voice speak`.
- **Links.** `LinkText` (link_text.dart) makes web and e-mail addresses in news, the sign-in pages and messages tappable; every link
  goes through `pek/plugins openUrl`, which on Windows opens the default browser / mail app (only `https://` and `mailto:`).
- **Video.** Android draws on a native surface behind Flutter. Windows uses libmpv's software renderer into a Flutter texture;
  `PekVideoSurface` sits under the whole Navigator, so the player and the live TV corner picture stay transparent as before.
- **Plugin trailers** need a web view; `webview_flutter` has none on Windows, so there are no trailers there (`PekPlatform.hasWebView`).
- **Plugins** run in `python\python.exe` (embeddable Python), talking to the app over a pipe; same `pek_runner` / `pek_flutter` modules as Android.
- **Folder picker** starts from the drives and the Videos / Music / Downloads folders (`server.cpp`, `storageRoots`).
- **ffprobe** ships as `ffprobe.exe`; the scanner starts it without a console window (`media_scanner.cpp`).
- **Self-update** downloads the `-windows-<arch>.zip`, and a small script swaps the files after the app closes (`pek/update install`).

## "The PEK server did not start"
The host (`pek_host.cpp`, `Boot()`) now says why on that screen and writes the same text to `%LOCALAPPDATA%\PEK TV\hesper\boot.log`:
- **"needs these files, which are missing: ..."**: `pek_server.dll` was built against MSYS2 libraries (libtorrent, OpenSSL ...) that were not
  shipped beside it. `windows/scripts/collect-server-deps.sh` (run in the MSYS2 shell after the server is built) copies them and
  `stage-assets.sh` ships them.
- **"Port 8080 is already in use"**: another program (a second PEK TV, a dev server, Docker, a Windows-reserved port range) holds the port.
- The server's own log is `%LOCALAPPDATA%\PEK TV\hesper\backend.log`.

## Not there yet on Windows
SMB and NFS network folders (libsmb2 / libnfs are not built; FTP, WebDAV, DLNA work), Picture-in-picture,
asking the receiver which formats it supports (passthrough itself works, see below).

## Refresh-rate matching
**Settings > Video output > Match refresh rate** (on by default, like Android). When a video starts, `Mpv` reports its frame rate
(`container-fps`) and `pek_display.cpp` switches the screen the window is on to a mode that suits it: 24 / 23.976 fps -> 24 Hz, 25 -> 50 Hz,
30 / 29.97 -> stays on 60 Hz (already a whole multiple), and so on up to five times the film's rate. The choice is `PickRefreshHz`
(`pek_refresh.h`, no Windows dependencies; `pek_refresh_test.cpp`: `g++ -std=c++17 pek_refresh_test.cpp -o t && ./t`).
- Only the refresh rate changes (same size and colour depth), and only to a mode the screen lists. Windows lists whole hertz, so a
  23.976 Hz film gets the screen's 24 Hz mode.
- The change is temporary (`CDS_FULLSCREEN`): Windows puts the person's own rate back if PEK TV is closed or crashes. PEK TV also puts it back
  itself 3 seconds after the video ends (not at once, so an episode followed by another one does not flash the screen twice), when the
  setting is switched off, and when a song starts.
- Songs (and the cover picture inside them) never switch the screen. Saved in `output.ini` as `matchrate=1|0`.

## Media keys and the now-playing tile
`pek/music` is no longer a stub: `pek_media.cpp` registers a Windows `SystemMediaTransportControls` session for the window, the same job
`FlutterMusic.kt` + `MusicService` do with a `MediaSession` on Android. While a song is current the play / pause / next / previous / stop
keys of the keyboard or a headset work, and the volume flyout and the lock screen show the title, artist, album, cover and a seek bar
(dragging it seeks). Play, pause and seek are answered in the host at once (`Host::OnRemote`, straight to libmpv); next, previous and
stop go to Dart (`music_session.dart` answers `remote`), which owns the queue. The app registers the id `PEKIndustries.PEKTV`
(`main.cpp`) and the installer's Start menu shortcuts carry it, so the tile is named "PEK TV" with its icon (a portable copy shows the exe name).
If Windows will not give a session the music still plays, only without the keys.

**Films** use the same session. When a video is loaded (`pek/mpv load` while no song is current) the tile shows its title, and the play / pause
keys and the seek bar control it; next, previous and stop are switched off for a film (the player screen decides what follows).
`Mpv` reports play / pause / buffering changes and seeks through `SetMediaCallback`; the tile moves its own clock in between. The tile
goes away when the player is closed (`pek/mpv destroy`). A song that starts takes the tile over.

## Sound settings and Audio output on Windows
**Settings > Playback > Sound** (and the speaker / Equalizer panels in the players) work the same as on Android: audio delay, volume boost,
night mode, dialogue boost, bass / treble, the ten-band equalizer and the stereo downmix. They are applied to libmpv at once (also to
what is playing) and when it starts, using the same lavfi filter chain as `MpvController.kt`. The logic is in `windows/runner/pek_audiofx.h`
(no Windows dependencies; `pek_audiofx_test.cpp` checks it: `g++ -std=c++17 pek_audiofx_test.cpp -o t && ./t`). They are kept in
`%LOCALAPPDATA%\\PEK TV\\output.ini` (`audiofx=<json>`).

**Settings > Audio output** (Dolby Digital / Plus, TrueHD, DTS, DTS-HD): switching a format on sends it untouched to the receiver
(`audio-spdif`, kept as `passthrough=ac3,eac3,...` in `output.ini`). Windows can only do this in WASAPI **exclusive mode**, so while any
format is on `audio-exclusive=yes` is set and other programs cannot use that sound device during playback. Windows cannot tell which
formats the receiver supports, so the screen shows no "your device supports this" claim; if the receiver refuses a format, mpv decodes it as
normal sound. Applies to the next video. Passthrough audio is not decoded here, so the Sound settings do not change it.

## HDR on Windows
The video reaches Flutter as an 8-bit texture, so HDR10 / HLG video cannot go to the screen as HDR the way it does on Android. Instead
(Settings > Video output > \"HDR tone-mapping\", on by default, kept in `%LOCALAPPDATA%\\PEK TV\\output.ini`) HDR video is converted to SDR
with an ffmpeg filter chain (`zscale` + `tonemap=hable`, scaled to at most 1920 wide first) so it has the right brightness and colour
instead of looking grey. The chain is only used when libmpv-2.dll contains the zscale / tonemap filters; if it produces no picture within
8 s it is taken off for that file. The log lines are `PEK hdr: ...` (run the exe from a terminal). Dolby Vision profile 5 is not handled.
Real HDR output needs the video in its own native window under a transparent Flutter view: not done.

## CPU or GPU rendering (Settings > Video output > \"GPU rendering\")
Applies to the next video; kept in `%LOCALAPPDATA%\\PEK TV\\output.ini` (`renderer=cpu|gpu`). **CPU**: libmpv's software renderer, software decoding.
**GPU**: libmpv's OpenGL renderer on a hidden WGL context (render thread, `pek_mpv.cpp`), copy-back hardware decoding (`hwdec=auto-copy`),
mpv's own shader tone mapping for HDR. The finished frame (at most 1920 x 1080) is read back into the pixel buffer Flutter shows, so it is
not zero-copy. If the PC has no OpenGL 3.3 driver (ARM64 Windows needs Microsoft's OpenGL compatibility pack) it falls back to the CPU and
the Settings row says why. Log lines: `PEK gpu:` / `PEK video:`. If the GPU picture is upside down on some driver, add `glflip=1` to output.ini.
New installs start on CPU: set `kDefaultGpu = true` in `pek_host.cpp` to change that.

## Maximum picture size (Settings > Video output, Windows only)
Auto / 1080p / 1440p / 4K, kept as `maxsize=auto|1080|1440|2160` in output.ini, applies to the next video. A video is only scaled down to it,
never up. Auto = the size of the screen the window is on (read before each video), but on the CPU renderer never above 1080p. It also sets
the width the HDR tone-map filter scales to on the CPU renderer. The setting is only shown when the host sends `maxSize` (Android does not).

## Build
CI does everything: Actions > "Build PEK TV (Windows)". Locally: Git Bash, Flutter on PATH, 7-Zip, `gh` (or `LIBMPV_URL`), Inno Setup 6
(`winget install JRSoftware.InnoSetup`) for the setup program, and MSYS2 CLANG64 for the server. First, **in the MSYS2 CLANG64 shell**:
```
cmake -S windows/backend -B build/backend -G Ninja -DCMAKE_BUILD_TYPE=Release -DPEK_TORRENT=ON && cmake --build build/backend
bash windows/scripts/collect-server-deps.sh
```
then **in Git Bash**:
```
bash windows/scripts/fetch-libmpv.sh x86_64 && bash windows/scripts/fetch-ffprobe.sh win64 && bash windows/scripts/fetch-python.sh amd64
bash tools/fetch-voice-model.sh && bash windows/scripts/stage-assets.sh 0.0.0-local
bash windows/scripts/prepare-flutter-host.sh && (cd build/windows_app && flutter pub get && flutter build windows --release)
bash windows/scripts/package.sh x64 0.0.0-local debug      # dist/: the setup program and the zip (SKIP_INSTALLER=1 = zip only)
```

## Hot reload
After one normal build, `bash windows/scripts/dev.sh` runs the app with `flutter run`: edit `flutter_ui/lib/...`, press `r` (hot reload) or `R` (restart). C++ changes (`windows/runner`, `backend`) need a rebuild.

## Outside `windows/` (shared files touched)
`flutter_ui/lib/src/{platform,link_text,video_surface}.dart` (new), `mpv.dart`, `main.dart`, `voice.dart`, `plugin_host.dart`,
`plugin_ui.dart`, `app_update.dart`, `dev_console.dart`, `news.dart` and a few more one-line `LinkText` swaps; `backend/server.cpp`,
`media_scanner.cpp`, `discovery.cpp`, `vfs_ftp.cpp` (each change sits in `#ifdef _WIN32`).

## Discord Rich Presence
Same feature and same Dart code as Android (`discord.dart`, `discord_ui.dart`, DISCORD.md): a linked profile shows "Watching <title>" on its
Discord profile. The Windows host is `windows/runner/pek_discord.cpp` (a port of `discord_presence.cpp`) behind the `pek/discord` channel.
It needs the **Discord Social SDK for Windows**, which is not in the repo (the Android `.aar` is the only SDK file committed). Without it the
app builds and runs as before and Settings says Discord is not supported in this build. To switch it on, take these from the SDK zip
(`DiscordSocialSdk-<version>.zip`, the C++ one, from the developer portal) and commit them:
```
windows/discord/include/discordpp.h
windows/discord/x64/discord_partner_sdk.lib     windows/discord/x64/discord_partner_sdk.dll
windows/discord/arm64/discord_partner_sdk.lib   windows/discord/arm64/discord_partner_sdk.dll   (only if Discord ships an ARM64 build)
```
`prepare-flutter-host.sh` copies the folder into the runner, `pek_runner.cmake` turns on `PEK_DISCORD_SDK` and links the `.lib` when the
files for that CPU type exist (the build log says `PEK: Discord Rich Presence ON (x64)` or `OFF`), and `stage-assets.sh` ships the `.dll` next
to the exe. A CPU type without its folder builds without Discord.
