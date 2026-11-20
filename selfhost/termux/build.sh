#!/usr/bin/env bash
# Builds PEK Server for Termux with the Android NDK (on a PC or GitHub Actions, NOT on the phone):
#   bash selfhost/termux/build.sh [arm64-v8a|armeabi-v7a ...]     default: both
#   -> build/termux-<abi>/pek-server
# Needs: the Android NDK (ANDROID_NDK_HOME or ANDROID_NDK_LATEST_HOME), cmake, ninja, curl, unzip.
# OpenSSL and SQLite come from the app's own scripts (android/scripts), so the server uses the same versions as the APK.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
[ -n "$NDK" ] && [ -f "$NDK/build/cmake/android.toolchain.cmake" ] || { echo "Set ANDROID_NDK_HOME to the Android NDK folder."; exit 1; }
export ANDROID_NDK_HOME="$NDK"
VERSION="${PEK_SERVER_VERSION:-$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' flutter_ui/pubspec.yaml | head -1)}"
ABIS=("$@"); [ ${#ABIS[@]} -gt 0 ] || ABIS=(arm64-v8a armeabi-v7a)

[ -f android/openssl/arm64-v8a/lib/libssl.a ] && [ -f android/openssl/armeabi-v7a/lib/libssl.a ] || bash android/scripts/build-openssl.sh
bash android/scripts/fetch-sqlite.sh

for ABI in "${ABIS[@]}"; do
  B="build/termux-$ABI"
  rm -rf "$B"
  # API 26 = Android 8.0, the same minimum as the PEK TV app (minSdk 26), where the backend is known to build.
  cmake -S selfhost/termux -B "$B" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" -DANDROID_PLATFORM=26 -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release -DPEK_SERVER_VERSION="${VERSION:-dev}"
  cmake --build "$B"
  file "$B/pek-server" 2>/dev/null || ls -l "$B/pek-server"
done
echo "Next: bash selfhost/termux/package.sh"
