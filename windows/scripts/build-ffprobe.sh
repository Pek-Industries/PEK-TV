#!/usr/bin/env bash
# Builds a MINIMAL ffprobe.exe from the FFmpeg sources into windows/ffmpeg-min/ (run in the MSYS2 shell, see build_windows.yml).
#   bash windows/scripts/build-ffprobe.sh x64      (or arm64)
#
# Why: the BtbN ffprobe is a full static FFmpeg (136 MB on x64) and libmpv-2.dll already carries a second copy of FFmpeg. The scanner
# only runs `ffprobe -v quiet -print_format json -show_format <file>` (backend/media_scanner.cpp: duration and container tags), which
# needs the demuxers, the parsers and zlib (compressed Matroska / MP4 headers) and nothing else: no decoders, encoders, filters,
# muxers, network or devices. That build is a few MB.
# Optional: FFMPEG_VERSION=<release, default below>   FFMPEG_URL=<tar.gz of the FFmpeg sources>.
set -euo pipefail
ARCH="${1:?x64 or arm64}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.0}"
case "$ARCH" in
  x64)   FF_ARCH=x86_64 ;;
  arm64) FF_ARCH=aarch64 ;;
  *) echo "::error::unknown arch $ARCH"; exit 1 ;;
esac
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/windows/ffmpeg-min"
rm -rf "$OUT"; mkdir -p "$OUT"
URL="${FFMPEG_URL:-https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${FFMPEG_VERSION}.tar.gz}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
echo "Downloading $URL"
curl -fsSL --retry 5 --retry-all-errors "$URL" -o "$W/ff.tar.gz"
mkdir "$W/src"; tar -xzf "$W/ff.tar.gz" -C "$W/src" --strip-components=1
cd "$W/src"

MAKE="$(command -v make || command -v mingw32-make)"
./configure \
  --arch="$FF_ARCH" --target-os=mingw32 \
  --cc=clang --ar=llvm-ar --ranlib=llvm-ranlib --nm=llvm-nm --strip=llvm-strip \
  --disable-everything --disable-autodetect --disable-debug --disable-doc \
  --disable-ffmpeg --disable-ffplay --enable-ffprobe \
  --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample --disable-network \
  --enable-demuxers --enable-parsers --enable-protocol=file \
  --enable-zlib \
  --disable-asm --disable-pthreads --enable-w32threads \
  --enable-static --disable-shared --pkg-config-flags=--static \
  --extra-ldflags=-static
"$MAKE" -j"$(nproc)" ffprobe.exe
llvm-strip ffprobe.exe || strip ffprobe.exe || true
cp ffprobe.exe "$OUT/ffprobe.exe"
ls -l "$OUT"
