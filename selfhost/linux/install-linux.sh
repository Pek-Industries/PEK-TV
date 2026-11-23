#!/usr/bin/env bash
# PEK Server for Linux: installs or updates the ready-made program from the newest release. Your library, accounts and settings
# are kept. Nothing updates by itself: this runs only when you run it (or  pek-server --update , which runs it for you).
#
#   curl -fsSL https://github.com/Pek-Industries/PEK-TV/releases/download/server-latest/install-linux.sh | sudo bash
#       install or update the service in /opt/pek-server (any install.sh options can follow:  | sudo bash -s -- --media /srv/movies)
#   curl -fsSL .../install-linux.sh | bash -s -- --into /path/to/folder
#       update a copy you start yourself, in that folder (then restart it)
set -euo pipefail

REPO="${PEK_REPO:-Pek-Industries/PEK-TV}"
BASE="${PEK_BASE:-https://github.com/$REPO/releases/download/server-latest}"
red() { printf '\033[31m%s\033[0m\n' "$*"; }

INTO=""; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --into) INTO="${2:?folder missing after --into}"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

case "$(uname -m)" in
  x86_64 | amd64) ARCH=x64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) red "This CPU ($(uname -m)) is not supported. PEK Server for Linux runs on x86-64 and 64-bit ARM."; exit 1 ;;
esac
for t in curl tar sha256sum; do command -v "$t" >/dev/null || { red "Please install $t first."; exit 1; }; done
if [ -z "$INTO" ] && [ "$(id -u)" != 0 ]; then red "Run it as root:  curl -fsSL $BASE/install-linux.sh | sudo bash"; exit 1; fi

NAME="PEK-Server-linux-$ARCH"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading $NAME..."
curl -fsSL --retry 3 -o "$TMP/$NAME.tar.gz" "$BASE/$NAME.tar.gz"
curl -fsSL --retry 3 -o "$TMP/$NAME.tar.gz.sha256" "$BASE/$NAME.tar.gz.sha256"
( cd "$TMP" && sha256sum -c "$NAME.tar.gz.sha256" >/dev/null ) || { red "The download is damaged (checksum mismatch). Try again."; exit 1; }
mkdir "$TMP/x" && tar -xzf "$TMP/$NAME.tar.gz" -C "$TMP/x"
SRC="$(find "$TMP/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -x "$SRC/pek-server" ] || { red "The download does not contain pek-server."; exit 1; }
echo "Version: $("$SRC/pek-server" --version 2>/dev/null || echo unknown)"

if [ -n "$INTO" ]; then
  [ -d "$INTO" ] && [ -w "$INTO" ] || { red "Cannot write to $INTO"; exit 1; }
  for f in pek-server ffprobe cacert.pem README.txt install.sh uninstall.sh pek-server.service; do
    [ -f "$SRC/$f" ] || continue
    cp "$SRC/$f" "$INTO/.$f.new" && mv -f "$INTO/.$f.new" "$INTO/$f"   # rename: safe while the old one is running
  done
  echo
  echo "Updated in $INTO. Restart PEK Server to use the new version."
else
  "$SRC/install.sh" "${ARGS[@]}"
fi
