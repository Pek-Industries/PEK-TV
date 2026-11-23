PEK Server - your own PEK TV server
====================================

INSTALL AS A SERVICE (systemd: Debian, Ubuntu, Fedora, Arch, Raspberry Pi OS ...)
  tar xzf PEK-Server-*-linux-*.tar.gz && cd PEK-Server-*
  sudo ./install.sh --media /srv/movies --media /srv/music
  It starts at boot and prints the address(es), a 6-digit PAIRING CODE and your ACCESS KEY. Keep the key private.
  Open the ports if you have a firewall:  sudo ufw allow 8080/tcp && sudo ufw allow 8768/udp   (8768 lets the app find the server)

CONNECT A TV / PHONE
  In PEK TV open  Settings > Library > Connect to a server.  The server shows up in the list (or type its address),
  then type the pairing code. A code works for 10 minutes, for one device. New code:  /opt/pek-server/pek-server --pair
  (Docker:  docker exec pek-server pek-server --pair). Typing the access key instead of a code works too.

TMDB (titles, posters, plots) - needs YOUR OWN free key: themoviedb.org > Settings > API
  sudo -u pek /opt/pek-server/pek-server --data /var/lib/pek-server --tmdb-key <key>    then: sudo systemctl restart pek-server
  (or TMDB_API_KEY in the service / Docker). Without a key only your own .nfo files and pictures are used.

SUBTITLES - subtitle search needs YOUR OWN free OpenSubtitles key: https://www.opensubtitles.com/en/consumers
  sudo -u pek /opt/pek-server/pek-server --data /var/lib/pek-server --subtitles-key <key>   (optional: --subtitles-user <name>)
  then: sudo systemctl restart pek-server   (or OPENSUBTITLES_API_KEY in the service / Docker)

UPDATES - PEK Server never updates by itself; it only tells you (log, and PEK TV's Settings > Library) when a new one is out.
  sudo /opt/pek-server/pek-server --update      (a copy you start yourself: pek-server --update in its folder, then restart)

ACCOUNTS (sign in, and sync history between devices)
  /opt/pek-server/pek-server --add-user alice      (asks for the password; the first account is the owner)
  In PEK TV: Settings > Account > Sign in. --list-users | --set-password <name> | --sign-out <name> | --remove-user <name>
  Run these as the pek user so the files stay theirs:  sudo -u pek /opt/pek-server/pek-server --data /var/lib/pek-server --add-user alice

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
  /etc/pek-server.env     PEK_MEDIA=/a:/b,  PEK_PORT,  PEK_NAME=<name shown in the app>  (restart after editing)
  Logs:  journalctl -u pek-server -f      Remove:  sudo ./uninstall.sh [--purge]
