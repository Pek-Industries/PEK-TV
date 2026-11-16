#!/usr/bin/env bash
# Removes the PEK Server service. Your library and access key (/var/lib/pek-server) stay unless you add --purge.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root:  sudo ./uninstall.sh [--purge]"; exit 1; }
systemctl disable --now pek-server 2>/dev/null || true
rm -f /etc/systemd/system/pek-server.service
systemctl daemon-reload 2>/dev/null || true
rm -rf /opt/pek-server
if [ "${1:-}" = "--purge" ]; then rm -rf /var/lib/pek-server /etc/pek-server.env; userdel pek 2>/dev/null || true; echo "Removed, including the library and access key."
else echo "Removed. Library and access key are still in /var/lib/pek-server (use --purge to delete them)."; fi
