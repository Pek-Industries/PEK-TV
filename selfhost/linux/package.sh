#!/usr/bin/env bash
# Collects pek-server + ffprobe + cacert.pem + install.sh etc. into one tar.gz:
#   dist-selfhost/PEK-Server-<version>-linux-<arch>.tar.gz  (+ .sha256)
# Run after build.sh.   Usage: bash selfhost/linux/package.sh [x64|arm64]   (default: this machine's)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
ARCH="${1:-}"
if [ -z "$ARCH" ]; then case "$(uname -m)" in x86_64) ARCH=x64 ;; aarch64|arm64) ARCH=arm64 ;; *) echo "Unknown CPU $(uname -m): pass x64 or arm64"; exit 1 ;; esac; fi
FF=linux64; [ "$ARCH" = arm64 ] && FF=linuxarm64
VERSION="${PEK_SERVER_VERSION:-$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' flutter_ui/pubspec.yaml | head -1)}"
NAME="PEK-Server-${VERSION}-linux-${ARCH}"
OUT="dist-selfhost/$NAME"
[ -f build/selfhost-linux/pek-server ] || { echo "Build first: bash selfhost/linux/build.sh"; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"
cp build/selfhost-linux/pek-server "$OUT/"
# ffprobe (reads the details of video and music files for the library scan): static LGPL build from BtbN/FFmpeg-Builds
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
URL="${FFPROBE_URL:-https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-${FF}-lgpl.tar.xz}"
echo "Downloading $URL"
curl -fsSL --retry 5 --retry-all-errors "$URL" -o "$TMP/ff.tar.xz"
tar -xJf "$TMP/ff.tar.xz" -C "$TMP"
FFPROBE="$(find "$TMP" -type f -name ffprobe | head -1)"
[ -n "$FFPROBE" ] || { echo "ffprobe is not in the archive"; exit 1; }
cp "$FFPROBE" "$OUT/ffprobe"; chmod 755 "$OUT/ffprobe"
curl -fsSL --retry 5 --retry-all-errors https://curl.se/ca/cacert.pem -o "$OUT/cacert.pem"
cp selfhost/linux/install.sh selfhost/linux/uninstall.sh selfhost/linux/pek-server.service selfhost/linux/README.txt "$OUT/"
chmod 755 "$OUT/pek-server" "$OUT/install.sh" "$OUT/uninstall.sh"
cp selfhost/linux/install-linux.sh dist-selfhost/install-linux.sh   # published on its own to server-latest
( cd dist-selfhost && tar -czf "$NAME.tar.gz" "$NAME" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
ls -l dist-selfhost
