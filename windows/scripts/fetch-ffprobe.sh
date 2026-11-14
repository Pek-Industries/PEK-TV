#!/usr/bin/env bash
# ffprobe.exe (reads the tags of video and music files for the library scan) for one CPU type into windows/ffmpeg/.
#   bash windows/scripts/fetch-ffprobe.sh win64      (64-bit Intel / AMD)
#   bash windows/scripts/fetch-ffprobe.sh winarm64   (ARM64)
# Source: BtbN/FFmpeg-Builds (LGPL build, static). Optional: FFPROBE_URL=<zip with bin/ffprobe.exe>.
set -euo pipefail
KIND="${1:?win64 or winarm64}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/windows/ffmpeg"
[ -s "$OUT/ffprobe.exe" ] && { echo "ffprobe.exe already in $OUT"; exit 0; }
mkdir -p "$OUT"
URL="${FFPROBE_URL:-https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-${KIND}-lgpl.zip}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "Downloading $URL"
curl -fsSL --retry 5 --retry-all-errors "$URL" -o "$TMP/ff.zip" || { echo "::error::Could not download ffprobe from $URL"; exit 1; }
7z x -y "$TMP/ff.zip" -o"$TMP/x" >/dev/null
EXE="$(find "$TMP/x" -iname 'ffprobe.exe' | head -1)"
[ -n "$EXE" ] || { echo "::error::ffprobe.exe is not in the archive"; exit 1; }
cp "$EXE" "$OUT/ffprobe.exe"
ls -l "$OUT"
