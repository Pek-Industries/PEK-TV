#!/data/data/com.termux/files/usr/bin/bash
# PEK Server for Termux: installs (or updates) the ready-made program. Nothing is built on the phone.
#
#   curl -fsSL https://github.com/Pek-Industries/PEK-TV/releases/download/server-latest/install-termux.sh | bash
#
# What it does: installs ffmpeg (ffprobe reads your files' details), downloads the program for this phone's CPU and checks its
# checksum, puts it in $PREFIX/opt/pek-server with the commands pek-server, pek-server-start and pek-server-stop, and (if the
# Termux:Boot app is installed) starts it when the phone starts. Your library and settings in ~/.local/share/pek-server are kept
# on update. Remove:  pek-server-uninstall
set -euo pipefail

REPO="${PEK_REPO:-Pek-Industries/PEK-TV}"
TAG="${PEK_TAG:-server-latest}"
BASE="${PEK_BASE:-https://github.com/$REPO/releases/download/$TAG}"   # PEK_BASE: a mirror, or a local test server

red() { printf '\033[31m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

[ -n "${PREFIX:-}" ] && [ -d "$PREFIX" ] && command -v pkg >/dev/null 2>&1 || { red "Run this inside the Termux app (from F-Droid or GitHub)."; exit 1; }

case "$(uname -m)" in
  aarch64 | arm64) ABI=arm64-v8a ;;
  armv7l | armv8l | arm) ABI=armeabi-v7a ;;
  *) red "This phone's CPU ($(uname -m)) is not supported. PEK Server runs on ARM phones and TV boxes."; exit 1 ;;
esac

bold "PEK Server for Termux ($ABI)"
echo "Installing ffmpeg (needed to read video and music details)..."
pkg install -y ffmpeg curl procps >/dev/null 2>&1 || pkg install -y ffmpeg curl procps

NAME="PEK-Server-termux-$ABI"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading $NAME..."
curl -fsSL --retry 3 -o "$TMP/$NAME.tar.gz" "$BASE/$NAME.tar.gz"
curl -fsSL --retry 3 -o "$TMP/$NAME.tar.gz.sha256" "$BASE/$NAME.tar.gz.sha256"
( cd "$TMP" && sha256sum -c "$NAME.tar.gz.sha256" >/dev/null ) || { red "The download is damaged (checksum mismatch). Try again."; exit 1; }
tar -xzf "$TMP/$NAME.tar.gz" -C "$TMP"

# Stop a running copy before replacing it (an update).
WAS_RUNNING=0
if pgrep -f "$PREFIX/opt/pek-server/pek-server" >/dev/null 2>&1; then
  WAS_RUNNING=1
  pkill -f "$PREFIX/opt/pek-server/pek-server" || true
  sleep 1
fi

DEST="$PREFIX/opt/pek-server"
mkdir -p "$DEST"
cp "$TMP/$NAME/pek-server" "$TMP/$NAME/cacert.pem" "$TMP/$NAME/README.txt" "$TMP/$NAME/VERSION" "$DEST/"
chmod 755 "$DEST/pek-server"
ln -sf "$DEST/pek-server" "$PREFIX/bin/pek-server"   # cacert.pem is found next to the real file

# pek-server-start: in the background, with a wake lock so Android does not put it to sleep.
cat > "$PREFIX/bin/pek-server-start" <<EOS
#!/data/data/com.termux/files/usr/bin/sh
if pgrep -f "$DEST/pek-server" >/dev/null 2>&1; then echo "PEK Server is already running."; exit 0; fi
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock
mkdir -p "\$HOME/.local/share/pek-server"
nohup "$DEST/pek-server" "\$@" > "\$HOME/.local/share/pek-server/console.log" 2>&1 < /dev/null &
sleep 3
if pgrep -f "$DEST/pek-server" >/dev/null 2>&1; then
  echo "PEK Server is running in the background."
  echo "Address, pairing code and key:  cat ~/.local/share/pek-server/pairing.txt"
  echo "New pairing code:               pek-server --pair"
  echo "Stop it:                        pek-server-stop"
else
  echo "PEK Server did not start. See ~/.local/share/pek-server/console.log"
  exit 1
fi
EOS
cat > "$PREFIX/bin/pek-server-stop" <<EOS
#!/data/data/com.termux/files/usr/bin/sh
pkill -f "$DEST/pek-server" && echo "PEK Server stopped." || echo "PEK Server was not running."
command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock
exit 0
EOS
cat > "$PREFIX/bin/pek-server-uninstall" <<EOS
#!/data/data/com.termux/files/usr/bin/sh
pkill -f "$DEST/pek-server" 2>/dev/null
rm -rf "$DEST" "\$HOME/.termux/boot/start-pek-server"
rm -f "$PREFIX/bin/pek-server" "$PREFIX/bin/pek-server-start" "$PREFIX/bin/pek-server-stop" "$PREFIX/bin/pek-server-uninstall"
echo "PEK Server removed. Your library and settings are still in ~/.local/share/pek-server (delete that folder to remove them too)."
EOS
chmod 755 "$PREFIX/bin/pek-server-start" "$PREFIX/bin/pek-server-stop" "$PREFIX/bin/pek-server-uninstall"

# Start with the phone: the Termux:Boot app (F-Droid) runs ~/.termux/boot/* once after the phone starts.
mkdir -p "$HOME/.termux/boot"
cat > "$HOME/.termux/boot/start-pek-server" <<EOS
#!/data/data/com.termux/files/usr/bin/sh
# Started by the Termux:Boot app when the phone starts (installed by PEK Server's install-termux.sh).
pek-server-start
EOS
chmod 755 "$HOME/.termux/boot/start-pek-server"

echo
bold "PEK Server $(cat "$DEST/VERSION") is installed."
[ "$WAS_RUNNING" = 1 ] && { echo "Starting it again..."; pek-server-start || true; }
cat <<'EOT'

Next steps:
  1. Let Termux read your files (once):   termux-setup-storage
  2. Add your media folder:               pek-server --add-media /storage/emulated/0/Movies
     (it starts in this window and shows the address and a 6-digit pairing code; Ctrl+C stops it)
  3. In PEK TV on your TV / phone:        Settings > Library > Connect to a server, then type the code
  4. Run it in the background:            pek-server-start      (stop: pek-server-stop)

Keep it running:
  - Turn off battery optimisation for Termux: Android settings > Apps > Termux > Battery > Unrestricted
  - Start with the phone: install the Termux:Boot app (F-Droid) and open it once
  - Best on a spare phone or TV box that stays plugged in and on Wi-Fi
More: cat $PREFIX/opt/pek-server/README.txt
EOT
