#!/usr/bin/env bash
# Collects pek-server.exe + ffprobe.exe + cacert.pem + the .bat helpers into one folder and zips it:
#   dist-selfhost/PEK-Server-<version>-windows-<arch>/   and   dist-selfhost/PEK-Server-<version>-windows-<arch>.zip
# Run in the MSYS2 shell after build.sh.   Usage: bash selfhost/windows/package.sh [win64|winarm64]
set -euo pipefail
KIND="${1:-win64}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
VERSION="${PEK_SERVER_VERSION:-$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' flutter_ui/pubspec.yaml | head -1)}"
ARCH=x64; [ "$KIND" = winarm64 ] && ARCH=arm64
NAME="PEK-Server-${VERSION}-windows-${ARCH}"
OUT="dist-selfhost/$NAME"
[ -f build/selfhost/pek-server.exe ] || { echo "Build first: bash selfhost/windows/build.sh"; exit 1; }
bash windows/scripts/fetch-ffprobe.sh "$KIND"
rm -rf "$OUT"; mkdir -p "$OUT"
cp build/selfhost/pek-server.exe "$OUT/"
cp windows/ffmpeg/ffprobe.exe "$OUT/"
curl -fsSL --retry 5 --retry-all-errors https://curl.se/ca/cacert.pem -o "$OUT/cacert.pem"
cp selfhost/windows/dist/*.bat "$OUT/"
cp selfhost/windows/dist/README.txt "$OUT/"
( cd dist-selfhost && 7z a -tzip -mx=9 "$NAME.zip" "$NAME" >/dev/null )
ls -l dist-selfhost
