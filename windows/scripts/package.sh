#!/usr/bin/env bash
# Puts the Flutter build and the staged files together and zips them.
# Usage: package.sh <x64|arm64> <version name> <build type>     Output: dist/PEK-TV-<version>-windows-<arch>.zip
# Also builds the setup program (Inno Setup): dist/PEK-TV-<version>-windows-<arch>-setup.exe - the file to hand out; the zip is the portable copy.
# (the names end in -windows-<arch>.zip / -windows-<arch>-setup.exe: that is what the app's own updater looks for, app_update.dart)
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

# The installer. PEK_INSTALLER_OPTIONAL=1 (CI, ARM64 runner) turns a failure into a warning so the zip is still published.
if [ "${SKIP_INSTALLER:-0}" != 1 ]; then
  if ! bash "$ROOT/windows/scripts/make-installer.sh" "$ARCH" "$VERSION" "$REL"; then
    if [ "${PEK_INSTALLER_OPTIONAL:-0}" = 1 ]; then echo "::warning::The installer could not be built; only the zip was made."; else exit 1; fi
  fi
fi
