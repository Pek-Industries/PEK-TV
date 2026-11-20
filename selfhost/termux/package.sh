#!/usr/bin/env bash
# Packs each built program with cacert.pem and the helper scripts:
#   dist-selfhost/PEK-Server-termux-<abi>.tar.gz (+ .sha256)   fixed names, so install-termux.sh can always find the newest one
#   dist-selfhost/PEK-Server-<version>-termux-<abi>.tar.gz     the same file under its version, for the versioned release
#   dist-selfhost/install-termux.sh                             the one-line installer
# Run after build.sh.  Usage: bash selfhost/termux/package.sh [abi ...]   (default: every build/termux-* found)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
VERSION="${PEK_SERVER_VERSION:-$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' flutter_ui/pubspec.yaml | head -1)}"
ABIS=("$@")
if [ ${#ABIS[@]} -eq 0 ]; then for d in build/termux-*/; do [ -f "$d/pek-server" ] && ABIS+=("$(basename "$d" | sed 's/^termux-//')"); done; fi
[ ${#ABIS[@]} -gt 0 ] || { echo "Build first: bash selfhost/termux/build.sh"; exit 1; }
mkdir -p dist-selfhost
CA="$(mktemp)"; trap 'rm -f "$CA"' EXIT
if [ -n "${CACERT_FILE:-}" ]; then cp "$CACERT_FILE" "$CA"; else curl -fsSL --retry 5 --retry-all-errors https://curl.se/ca/cacert.pem -o "$CA"; fi   # CACERT_FILE: offline builds
for ABI in "${ABIS[@]}"; do
  NAME="PEK-Server-termux-$ABI"
  OUT="dist-selfhost/$NAME"
  rm -rf "$OUT"; mkdir -p "$OUT"
  cp "build/termux-$ABI/pek-server" "$OUT/"
  cp "$CA" "$OUT/cacert.pem"; chmod 644 "$OUT/cacert.pem"
  cp selfhost/termux/README.txt "$OUT/"
  echo "$VERSION" > "$OUT/VERSION"
  chmod 755 "$OUT/pek-server"
  ( cd dist-selfhost
    tar -czf "$NAME.tar.gz" "$NAME"
    sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256"
    cp "$NAME.tar.gz" "PEK-Server-$VERSION-termux-$ABI.tar.gz"
    sha256sum "PEK-Server-$VERSION-termux-$ABI.tar.gz" > "PEK-Server-$VERSION-termux-$ABI.tar.gz.sha256" )
done
cp selfhost/termux/install-termux.sh dist-selfhost/
ls -l dist-selfhost
