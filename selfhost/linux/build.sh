#!/usr/bin/env bash
# Builds ONE static pek-server program (runs on any Linux distribution) with Docker:
#   bash selfhost/linux/build.sh            -> build/selfhost-linux/pek-server
# Needs Docker with BuildKit (any recent Docker). On ARM machines (Raspberry Pi, ARM servers) it builds the ARM program.
# Without Docker: on Alpine, `apk add build-base cmake ninja linux-headers openssl-dev openssl-libs-static sqlite-dev sqlite-static zlib-dev zlib-static`
# then  cmake -S selfhost/linux -B build/selfhost-linux -G Ninja -DCMAKE_BUILD_TYPE=Release -DPEK_STATIC=ON && cmake --build build/selfhost-linux
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
VERSION="${PEK_SERVER_VERSION:-$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' flutter_ui/pubspec.yaml | head -1)}"
rm -rf build/selfhost-linux
DOCKER_BUILDKIT=1 docker build -f selfhost/linux/Dockerfile --target binary --build-arg VERSION="${VERSION:-dev}" --output type=local,dest=build/selfhost-linux .
ls -l build/selfhost-linux/pek-server
./build/selfhost-linux/pek-server --version
echo "Next: bash selfhost/linux/package.sh   (or run it: build/selfhost-linux/pek-server --add-media /path/to/movies)"
