PEK Server - your own PEK TV server
====================================

INSTALL AS A SERVICE (systemd: Debian, Ubuntu, Fedora, Arch, Raspberry Pi OS ...)
  tar xzf PEK-Server-*-linux-*.tar.gz && cd PEK-Server-*
  sudo ./install.sh --media /srv/movies --media /srv/music
  It starts at boot and prints the address(es) and your ACCESS KEY. Put those into the app on your devices. Keep the key private.
  Open the port if you have a firewall:  sudo ufw allow 8080/tcp

JUST RUN IT
  ./pek-server --add-media /srv/movies          (Ctrl+C stops it; data in ~/.local/share/pek-server)
  ./pek-server --help

QUICK TEST (no app needed)
  On another device open  http://<address>:8080/api/movies?token=<key>   -> your movies as text.

DOCKER
  See SELFHOST.md in the repository (docker compose up -d).

WHERE THINGS ARE (service install)
  /opt/pek-server/        the program, ffprobe, cacert.pem
  /var/lib/pek-server/    library, settings, server.log, access-key.txt, pairing.txt
  /etc/pek-server.env     PEK_MEDIA=/a:/b  and  PEK_PORT  (restart after editing)
  Logs:  journalctl -u pek-server -f      Remove:  sudo ./uninstall.sh [--purge]
