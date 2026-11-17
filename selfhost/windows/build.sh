#!/usr/bin/env bash
# Builds pek-server.exe. Run in the MSYS2 "CLANG64" shell (ARM64 PCs: "CLANGARM64"):
#   bash selfhost/windows/build.sh
# One-time setup of that shell:
#   pacman -S --needed mingw-w64-clang-x86_64-{toolchain,cmake,ninja,openssl,sqlite3,pkgconf,zlib} p7zip curl
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="${PEK_SERVER_VERSION:-$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' "$ROOT/flutter_ui/pubspec.yaml" | head -1)}"
cd "$ROOT"
rm -rf build/selfhost
cmake -S selfhost/windows -B build/selfhost -G Ninja -DCMAKE_BUILD_TYPE=Release -DPEK_SERVER_VERSION="${VERSION:-dev}"
cmake --build build/selfhost
ls -l build/selfhost/pek-server.exe
bash selfhost/windows/collect-deps.sh
echo "Built pek-server.exe ${VERSION:-dev}. Next: bash selfhost/windows/package.sh"
