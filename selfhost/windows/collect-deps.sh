#!/usr/bin/env bash
# Copies every DLL that pek-server.exe needs and Windows itself does not have (OpenSSL, SQLite ... from MSYS2) into build/selfhost/deps/,
# so package.sh can ship them next to the exe. Same method as windows/scripts/collect-server-deps.sh (reads the PE import table).
# Run in the MSYS2 shell right after build.sh builds the exe (build.sh calls it).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXE="$ROOT/build/selfhost/pek-server.exe"
OUT="$ROOT/build/selfhost/deps"
[ -f "$EXE" ] || { echo "::error::$EXE not found - build first"; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"
BIN="${MSYSTEM_PREFIX:-/clang64}/bin"
OBJDUMP="$(command -v llvm-objdump || command -v objdump || true)"
[ -n "$OBJDUMP" ] || { echo "::error::Neither llvm-objdump nor objdump found in the MSYS2 shell."; exit 1; }
imports() { "$OBJDUMP" -p "$1" 2>/dev/null | sed -n 's/^[[:space:]]*DLL Name: //p' | tr -d '\r'; }
declare -A seen=()
queue=("$EXE")
while [ ${#queue[@]} -gt 0 ]; do
  cur="${queue[0]}"; queue=("${queue[@]:1}")
  while read -r name; do
    [ -n "$name" ] || continue
    key="${name,,}"
    [ -z "${seen[$key]:-}" ] || continue
    seen[$key]=1
    case "$key" in api-ms-win-*|ext-ms-win-*) continue ;; esac
    if [ -f "$BIN/$name" ]; then cp -v "$BIN/$name" "$OUT/"; queue+=("$BIN/$name")
    elif [ -f "/c/Windows/System32/$name" ] || [ -f "/c/Windows/SysWOW64/$name" ]; then :
    else echo "::error::pek-server.exe needs $name, which is neither in $BIN nor in System32."; exit 1; fi
  done < <(imports "$cur")
done
echo "DLLs to ship next to pek-server.exe:"; ls -l "$OUT"
