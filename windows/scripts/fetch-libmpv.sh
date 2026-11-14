#!/usr/bin/env bash
# Downloads libmpv-2.dll (video playback, DVD, audio filters) for one CPU type into windows/libmpv/.
#   bash windows/scripts/fetch-libmpv.sh x86_64      (64-bit Intel / AMD)
#   bash windows/scripts/fetch-libmpv.sh aarch64     (ARM64)
# Source: zhongfly/mpv-winbuild releases (mpv-dev-<arch>-<date>-git-<hash>.7z). The newest release that has this CPU type wins
# (ARM64 builds are not in every release). Needs: gh (GH_TOKEN set), 7z, curl.   Optional: LIBMPV_URL=<direct address> to use your own build.
set -euo pipefail
ARCH="${1:?x86_64 or aarch64}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/windows/libmpv"
[ -s "$OUT/libmpv-2.dll" ] && { echo "libmpv-2.dll already in $OUT"; exit 0; }
mkdir -p "$OUT"
URL="${LIBMPV_URL:-}"
if [ -z "$URL" ]; then
  URL="$(gh api "repos/zhongfly/mpv-winbuild/releases?per_page=40" \
    --jq "[.[].assets[] | select(.name | test(\"^mpv-dev-${ARCH}-[0-9]{8}-git-[0-9a-f]+\\\\.7z\$\")) | .browser_download_url][0]")"
fi
[ -n "$URL" ] && [ "$URL" != "null" ] || { echo "::error::No libmpv build for $ARCH found. Set LIBMPV_URL to a mpv-dev-*.7z of your own."; exit 1; }
echo "Downloading $URL"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 5 --retry-all-errors "$URL" -o "$TMP/mpv.7z"
7z x -y "$TMP/mpv.7z" -o"$TMP/x" >/dev/null
DLL="$(find "$TMP/x" -iname 'libmpv-2.dll' | head -1)"
[ -n "$DLL" ] || { echo "::error::libmpv-2.dll is not in the archive"; exit 1; }
cp "$DLL" "$OUT/libmpv-2.dll"
ls -l "$OUT"
