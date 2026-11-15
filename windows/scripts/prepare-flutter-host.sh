#!/usr/bin/env bash
# Builds the Flutter Windows project in build/windows_app/ (the repo is not changed):
#   1. copies flutter_ui/ there without the Android-module setting in pubspec.yaml (a module cannot be a desktop app),
#   2. lets `flutter create` write the standard Windows runner template (windows/flutter/*, win32_window.*, Runner.rc ...),
#   3. lays this repo's windows/ files over it (main.cpp, flutter_window.*, pek_host.*, pek_mpv.*, the manifest, the icon).
# Needs Flutter on PATH. Prints nothing but the folder it made. Run by the workflow; run it by hand for a local build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/windows_app"
rm -rf "$APP"
mkdir -p "$APP"
cp -r "$ROOT/flutter_ui/lib" "$ROOT/flutter_ui/assets" "$ROOT/flutter_ui/pubspec.yaml" "$APP/"

PY="$(command -v python3 || command -v python)"
"$PY" - "$APP/pubspec.yaml" <<'PYEND'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
# drop the "module:" block (androidX / androidPackage / iosBundleIdentifier)
s = re.sub(r"\n  module:\n(?:    .*\n)+", "\n", s)
open(p, "w", encoding="utf-8").write(s)
PYEND

( cd "$APP" && flutter create --platforms=windows --project-name pek_tv_ui --org com.pektv . >&2 )

W="$ROOT/windows"
cp -f "$W"/runner/{main.cpp,flutter_window.cpp,flutter_window.h,pek_host.cpp,pek_host.h,pek_mpv.cpp,pek_mpv.h,pek_audiofx.h,pek_refresh.h,pek_display.cpp,pek_display.h,pek_media.cpp,pek_media.h,pek_discord.cpp,pek_discord.h,runner.exe.manifest} "$APP/windows/runner/"
[ -f "$W/runner/resources/app_icon.ico" ] && cp -f "$W/runner/resources/app_icon.ico" "$APP/windows/runner/resources/app_icon.ico"
[ -d "$W/discord" ] && { rm -rf "$APP/windows/runner/discord"; cp -r "$W/discord" "$APP/windows/runner/discord"; }   # the Discord Social SDK, if it is there (DISCORD.md)
sed -i 's/set(BINARY_NAME "[^"]*")/set(BINARY_NAME "pek_tv")/' "$APP/windows/CMakeLists.txt"
grep -q 'BINARY_NAME "pek_tv"' "$APP/windows/CMakeLists.txt" || { echo "::error::BINARY_NAME not found in the generated CMakeLists.txt" >&2; exit 1; }
cat "$W/pek_runner.cmake" >> "$APP/windows/runner/CMakeLists.txt"
echo "$APP"
