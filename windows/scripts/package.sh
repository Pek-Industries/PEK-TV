#!/usr/bin/env bash
# Puts the Flutter build and the staged files together and zips them.
# Usage: package.sh <x64|arm64> <version name> <build type>     Output: dist/PEK-TV-<version>-windows-<arch>.zip
# (the name ends in -windows-<arch>.zip: that is what the app's own updater looks for, app_update.dart)
set -euo pipefail
ARCH="${1:?x64 or arm64}"; VERSION="${2:?version}"; BUILD_TYPE="${3:-release}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REL="$ROOT/build/windows_app/build/windows/$ARCH/runner/Release"
[ -f "$REL/pek_tv.exe" ] || { echo "::error::$REL/pek_tv.exe not found - did flutter build windows run?"; exit 1; }
S="$ROOT/build/windows_stage"
[ -d "$S" ] || { echo "::error::run stage-assets.sh first"; exit 1; }
cp -r "$S/." "$REL/"
mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/PEK-TV-${VERSION}-windows-${ARCH}.zip"
rm -f "$OUT"
( cd "$REL" && 7z a -tzip -mx=5 "$OUT" . >/dev/null )
ls -lh "$OUT"
