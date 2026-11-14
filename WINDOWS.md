# PEK TV for Windows

The Windows app is the same Flutter UI (`flutter_ui/`) and the same C++ server (`backend/`) as Android, with its own host in
`windows/`, exactly like `android/`. Everything Windows-specific is in that folder (plus the workflow
`.github/workflows/build_windows.yml`); the only edits outside it are small, platform-neutral ones listed at the bottom.

## 32-bit and 64-bit
Android ships two apks (64-bit `arm64-v8a`, 32-bit `armeabi-v7a`). **Windows cannot ship a 32-bit build:** Flutter's Windows engine
exists only for 64-bit Intel/AMD (x64) and 64-bit ARM (arm64). So the same "one file per CPU type" split is:

| File | For |
|---|---|
| `PEK-TV-<version>-windows-x64.zip`   | normal PCs (Intel / AMD, 64-bit) |
| `PEK-TV-<version>-windows-arm64.zip` | Windows on ARM (Snapdragon / Copilot+ PCs) |

Unzip anywhere (a folder you can write to, so the app can update itself) and run `pek_tv.exe`. Data lives in `%LOCALAPPDATA%\PEK TV`.
The file name ends in `-windows-<arch>.zip` because that is what the in-app updater looks for (`app_update.dart`).

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
  scripts/                   fetch-libmpv / fetch-ffprobe / fetch-python / stage-assets / prepare-flutter-host / package
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

## Not there yet on Windows
SMB and NFS network folders (libsmb2 / libnfs are not built; FTP, WebDAV, DLNA work), Discord Rich Presence, Picture-in-picture,
HDR / refresh-rate matching, Dolby/DTS passthrough and the audio effects (stored, not applied), media keys / now-playing tile.

## Build
CI does everything: Actions > "Build PEK TV (Windows)". Locally (Git Bash, MSYS2 CLANG64 for the server, Flutter on PATH):
```
cmake -S windows/backend -B build/backend -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build build/backend
bash windows/scripts/fetch-libmpv.sh x86_64 && bash windows/scripts/fetch-ffprobe.sh win64 && bash windows/scripts/fetch-python.sh amd64
bash tools/fetch-voice-model.sh && bash windows/scripts/stage-assets.sh 0.0.0-local
bash windows/scripts/prepare-flutter-host.sh && (cd build/windows_app && flutter pub get && flutter build windows --release)
bash windows/scripts/package.sh x64 0.0.0-local debug
```

## Outside `windows/` (shared files touched)
`flutter_ui/lib/src/{platform,link_text,video_surface}.dart` (new), `mpv.dart`, `main.dart`, `voice.dart`, `plugin_host.dart`,
`plugin_ui.dart`, `app_update.dart`, `dev_console.dart`, `news.dart` and a few more one-line `LinkText` swaps; `backend/server.cpp`,
`media_scanner.cpp`, `discovery.cpp`, `vfs_ftp.cpp` (each change sits in `#ifdef _WIN32`).
