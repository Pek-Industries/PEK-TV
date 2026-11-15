#!/usr/bin/env bash
# Dev loop with hot reload (Git Bash, Flutter on PATH). Run the normal build ONCE first (server, collect-server-deps, fetch-*, stage-assets),
# then:   bash windows/scripts/dev.sh
#   * build/windows_app/lib becomes a junction to flutter_ui/lib, so you edit flutter_ui/lib/... and press  r  (hot reload) or  R  (restart)
#   * the staged files (pek_server.dll, libmpv, python, hesper ...) are copied beside the debug exe so the server starts
#   * changes to windows/runner/*.cpp or backend/*.cpp are NOT hot-reloadable: stop (q), redo the server build / run this again.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/windows_app"
STAGE="$ROOT/build/windows_stage"
[ -d "$STAGE" ] || { echo "Run the normal build once first (see WINDOWS.md): build/windows_stage is missing."; exit 1; }

# A fresh project copy every time the link is missing: prepare-flutter-host.sh wipes build/windows_app, so lib is a real folder here.
if [ ! -f "$APP/.lib_linked" ]; then
  bash "$ROOT/windows/scripts/prepare-flutter-host.sh" >/dev/null
  rm -rf "$APP/lib"
  cmd //c mklink //J "$(cygpath -w "$APP/lib")" "$(cygpath -w "$ROOT/flutter_ui/lib")" >/dev/null
  touch "$APP/.lib_linked"
fi

cd "$APP"
flutter pub get
flutter build windows --debug
DEBUG_DIR="$APP/build/windows/x64/runner/Debug"
cp -r "$STAGE/." "$DEBUG_DIR/"
flutter run -d windows
