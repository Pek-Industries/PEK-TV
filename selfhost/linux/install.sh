#!/usr/bin/env bash
# Installs PEK Server as a service (systemd): starts at boot, restarts if it stops.
#   sudo ./install.sh --media /srv/movies --media /srv/music [--port 8080]
# Media folders must be readable by the "pek" user the service runs as.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root:  sudo ./install.sh ..."; exit 1; }
command -v systemctl >/dev/null || { echo "This installer needs systemd. Without it, run ./pek-server directly (see README.txt)."; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"
MEDIA=(); PORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --media) MEDIA+=("${2:?folder missing after --media}"); shift 2 ;;
    --port)  PORT="${2:?number missing after --port}"; shift 2 ;;
    *) echo "usage: sudo ./install.sh [--media <folder>]... [--port <number>]"; exit 2 ;;
  esac
done

id pek >/dev/null 2>&1 || useradd --system --home-dir /var/lib/pek-server --shell "$(command -v nologin || echo /usr/sbin/nologin)" pek
install -d -o pek -g pek -m 750 /var/lib/pek-server
install -d -m 755 /opt/pek-server
install -m 755 "$DIR/pek-server" /opt/pek-server/pek-server
[ -f "$DIR/ffprobe" ]    && install -m 755 "$DIR/ffprobe" /opt/pek-server/ffprobe
[ -f "$DIR/cacert.pem" ] && install -m 644 "$DIR/cacert.pem" /opt/pek-server/cacert.pem
install -m 644 "$DIR/pek-server.service" /etc/systemd/system/pek-server.service

if [ ${#MEDIA[@]} -gt 0 ] || [ -n "$PORT" ] || [ ! -f /etc/pek-server.env ]; then
  {
    echo "# Settings for PEK Server. After editing: sudo systemctl restart pek-server"
    if [ ${#MEDIA[@]} -gt 0 ]; then echo "PEK_MEDIA=$(IFS=:; echo "${MEDIA[*]}")"; else echo "#PEK_MEDIA=/srv/movies:/srv/music"; fi
    if [ -n "$PORT" ]; then echo "PEK_PORT=$PORT"; else echo "#PEK_PORT=8080"; fi
  } > /etc/pek-server.env
fi

systemctl daemon-reload
systemctl enable pek-server >/dev/null
systemctl restart pek-server
echo "Starting PEK Server ..."
for _ in $(seq 1 30); do [ -s /var/lib/pek-server/pairing.txt ] && break; sleep 1; done
echo
if [ -s /var/lib/pek-server/pairing.txt ]; then cat /var/lib/pek-server/pairing.txt
else echo "It did not report in yet. Look at:  journalctl -u pek-server -e"; fi
echo
echo "Later:  sudo cat /var/lib/pek-server/pairing.txt   |   journalctl -u pek-server -f   |   sudo systemctl restart pek-server"
echo "If the machine has a firewall (ufw / firewalld) allow the port, e.g.  sudo ufw allow ${PORT:-8080}/tcp"
