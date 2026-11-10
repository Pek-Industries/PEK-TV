#!/usr/bin/env bash
# Downloads the speech-to-text model that is BUNDLED in the APK (Moonshine tiny, English, int8, via sherpa-onnx).
# Output: assets/bundled/voice/stt/{preprocess.onnx,encode.int8.onnx,uncached_decode.int8.onnx,cached_decode.int8.onnx,tokens.txt}
# Platform-neutral: lives in the repo's tools/ folder and writes into the top-level assets/ folder, so every platform build
# (Android today, others later) picks the same files up. Run by GitHub Actions; run it once by hand for a local build.
# Optional:
#   VOICE_MODEL_URL=<address of sherpa-onnx-moonshine-tiny-en-int8.tar.bz2>   mirror or local file:// copy
#   VOICE_MODEL_SHA256=<hash>                                                  refuse a download that differs
set -euo pipefail

URL="${VOICE_MODEL_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-moonshine-tiny-en-int8.tar.bz2}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # repo root
OUT="$ROOT/assets/bundled/voice/stt"
FILES="preprocess.onnx encode.int8.onnx uncached_decode.int8.onnx cached_decode.int8.onnx tokens.txt"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

have_all() { for f in $FILES; do [ -s "$OUT/$f" ] || return 1; done; }
if have_all; then echo "Voice model already in $OUT"; exit 0; fi

echo "Downloading $URL"
curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors "$URL" -o "$WORK/m.tar.bz2" \
  || { echo "::error::Could not download the voice model from $URL (set VOICE_MODEL_URL, or copy the files into $OUT yourself)"; exit 1; }
if [ -n "${VOICE_MODEL_SHA256:-}" ]; then
  echo "${VOICE_MODEL_SHA256}  $WORK/m.tar.bz2" | sha256sum -c - || { echo "::error::voice model hash mismatch"; exit 1; }
fi
tar -xjf "$WORK/m.tar.bz2" -C "$WORK"
SRC="$(find "$WORK" -name encode.int8.onnx -printf '%h\n' | head -1)"
[ -n "$SRC" ] || { echo "::error::encode.int8.onnx not found inside the archive"; exit 1; }
mkdir -p "$OUT"
for f in $FILES; do
  [ -s "$SRC/$f" ] || { echo "::error::$f missing from the archive"; exit 1; }
  cp "$SRC/$f" "$OUT/$f"
done
du -ch $(for f in $FILES; do echo "$OUT/$f"; done) | tail -1
echo "Voice model ready in $OUT"
