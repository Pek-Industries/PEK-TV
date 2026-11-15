#!/usr/bin/env bash
# Builds the Windows setup program with Inno Setup (https://jrsoftware.org/isinfo.php).
# Usage: make-installer.sh <x64|arm64> <version name> <folder with pek_tv.exe and the staged files>
# Output: dist/PEK-TV-<version>-windows-<arch>-setup.exe
set -euo pipefail
ARCH="${1:?x64 or arm64}"; VERSION="${2:?version}"; SRC="${3:?folder to install}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$ROOT/dist"

ISCC=""
for c in "$(command -v ISCC || true)" "$(command -v iscc || true)" \
         "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" "/c/Program Files/Inno Setup 6/ISCC.exe" \
         "${LOCALAPPDATA:-/nonexistent}/Programs/Inno Setup 6/ISCC.exe"; do
  [ -n "$c" ] && [ -x "$c" ] && { ISCC="$c"; break; }
done
[ -n "$ISCC" ] || { echo "::error::Inno Setup (ISCC.exe) was not found. Install it from https://jrsoftware.org/isdl.php (or: winget install JRSoftware.InnoSetup) and run this again."; exit 1; }

# Git Bash rewrites arguments that start with "/" (ISCC's /D options) as paths: switch that off for this call.
export MSYS2_ARG_CONV_EXCL='*'
WSRC="$(cygpath -w "$SRC")"
WOUT="$(cygpath -w "$ROOT/dist")"
WISS="$(cygpath -w "$ROOT/windows/installer/pek_tv.iss")"
"$ISCC" "/DAppVersion=$VERSION" "/DArch=$ARCH" "/DSourceDir=$WSRC" "/DOutDir=$WOUT" "$WISS"
ls -lh "$ROOT/dist/PEK-TV-${VERSION}-windows-${ARCH}-setup.exe"
