#!/usr/bin/env bash
# Copies every DLL that pek_server.dll needs and Windows itself does not have (libtorrent, OpenSSL, libc++ ... from MSYS2)
# into build/backend/deps/, so stage-assets.sh can ship them next to the exe. Without them LoadLibrary fails and the app sits on
# the loading ring and then says the server did not start.
# Reads the PE import table (objdump -p) instead of running ldd: ldd cannot resolve the api-ms-win-* forwarders under the
# x64-emulated MSYS2 on the ARM64 runner and stops listing dependencies.
# Run in the MSYS2 shell (CLANG64 / CLANGARM64) right after the server is built:   bash windows/scripts/collect-server-deps.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DLL="$ROOT/build/backend/pek_server.dll"
OUT="$ROOT/build/backend/deps"
[ -f "$DLL" ] || { echo "::error::$DLL not found - build the server first"; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"

PREFIX="${MSYSTEM_PREFIX:-/clang64}"
BIN="$PREFIX/bin"
OBJDUMP="$(command -v llvm-objdump || command -v objdump || true)"
[ -n "$OBJDUMP" ] || { echo "::error::Neither llvm-objdump nor objdump found in the MSYS2 shell."; exit 1; }

imports() { "$OBJDUMP" -p "$1" 2>/dev/null | sed -n 's/^[[:space:]]*DLL Name: //p' | tr -d '\r'; }

declare -A seen=()
queue=("$DLL")
while [ ${#queue[@]} -gt 0 ]; do
  cur="${queue[0]}"
  queue=("${queue[@]:1}")
  while read -r name; do
    [ -n "$name" ] || continue
    key="${name,,}"
    [ -z "${seen[$key]:-}" ] || continue
    seen[$key]=1
    case "$key" in
      api-ms-win-*|ext-ms-win-*) continue ;;   # Windows virtual forwarders: always present on Windows 10/11
    esac
    if [ -f "$BIN/$name" ]; then
      cp -v "$BIN/$name" "$OUT/"
      queue+=("$BIN/$name")                     # follow its own imports too
    elif [ -f "/c/Windows/System32/$name" ] || [ -f "/c/Windows/SysWOW64/$name" ]; then
      :                                         # ships with Windows
    else
      echo "::error::pek_server.dll needs $name, which is neither in $BIN nor in System32."
      exit 1
    fi
  done < <(imports "$cur")
done

echo "Dependencies to ship next to the exe:"
ls -l "$OUT" || true
