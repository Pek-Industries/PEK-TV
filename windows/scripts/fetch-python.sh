#!/usr/bin/env bash
# The official "embeddable" Python for Windows (runs the plugins) into windows/python-embed/.
#   bash windows/scripts/fetch-python.sh amd64      or      bash windows/scripts/fetch-python.sh arm64
set -euo pipefail
ARCH="${1:?amd64 or arm64}"
PYV="${PYTHON_VERSION:-3.12.8}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/windows/python-embed"
[ -s "$OUT/python.exe" ] && { echo "Python already in $OUT"; exit 0; }
mkdir -p "$OUT"
URL="https://www.python.org/ftp/python/${PYV}/python-${PYV}-embed-${ARCH}.zip"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "Downloading $URL"
curl -fsSL --retry 5 --retry-all-errors "$URL" -o "$TMP/py.zip" || { echo "::error::Could not download $URL"; exit 1; }
7z x -y "$TMP/py.zip" -o"$OUT" >/dev/null
# The embeddable build only imports what its ._pth file lists: add the folder with PEK's own modules ("pek").
PTH="$(ls "$OUT"/python*._pth | head -1)"
ZIPNAME="$(basename "$PTH" ._pth).zip"
printf '%s\n.\npek\n' "$ZIPNAME" > "$PTH"
ls "$OUT" | head -20
