#!/usr/bin/env bash
# Copies every DLL that pek_server.dll needs and Windows itself does not have (libtorrent, OpenSSL, libc++ ... from MSYS2)
# into build/backend/deps/, so stage-assets.sh can ship them next to the exe. Without them LoadLibrary fails and the app sits on
# the loading ring and then says the server did not start.
# Run in the MSYS2 shell (CLANG64 / CLANGARM64) right after the server is built:   bash windows/scripts/collect-server-deps.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DLL="$ROOT/build/backend/pek_server.dll"
OUT="$ROOT/build/backend/deps"
[ -f "$DLL" ] || { echo "::error::$DLL not found - build the server first"; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"

LISTING="$(ldd "$DLL" || true)"
echo "$LISTING"
if echo "$LISTING" | grep -q "not found"; then
  echo "::error::pek_server.dll has dependencies that cannot be found even here (see 'not found' above)."
  exit 1
fi

# "name.dll => /clang64/bin/name.dll (0x...)": ship what lives in the MSYS2 prefix, not what lives in Windows.
echo "$LISTING" | awk '/=>/ {print $3}' | grep -v -i -E '^/[a-z]/windows/|/windows/system32|^/c/windows' | grep -i '\.dll$' | sort -u | while read -r f; do
  [ -f "$f" ] || continue
  cp -v "$f" "$OUT/"
done
echo "Dependencies to ship next to the exe:"
ls -l "$OUT" || true
