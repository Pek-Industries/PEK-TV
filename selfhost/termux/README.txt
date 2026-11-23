PEK Server for Termux - your own PEK TV server on an Android phone or TV box
==========================================================================

INSTALL / UPDATE (in the Termux app)
  curl -fsSL https://github.com/Pek-Industries/PEK-TV/releases/download/server-latest/install-termux.sh | bash
  Get Termux from F-Droid or GitHub (the Google Play version is outdated).

FIRST RUN
  termux-setup-storage                                     let Termux read your files (once)
  pek-server --add-media /storage/emulated/0/Movies        add a folder, start, show the address + pairing code
  An SD card or USB drive is under /storage/<its id>/ (ls /storage to see it).
  It listens on port 8090 (PEK TV on the same phone already uses 8080). Ctrl+C stops it.

CONNECT A TV / PHONE
  In PEK TV: Settings > Library > Connect to a server. The server shows up in the list (or type its address,
  e.g. 192.168.1.30:8090), then type the 6-digit code. A code works 10 minutes, for one device.
  New code:  pek-server --pair

TMDB (titles, posters, plots) - needs YOUR OWN free key: themoviedb.org > Settings > API
  pek-server --tmdb-key <key>         then restart the server. Without a key only your own .nfo files and pictures are used.

SUBTITLES - subtitle search needs YOUR OWN free OpenSubtitles key: https://www.opensubtitles.com/en/consumers
  pek-server --subtitles-key <key>    (optional: --subtitles-user <name>), then restart the server.

UPDATES - PEK Server never updates by itself; it only tells you (log, and PEK TV's Settings > Library) when a new one is out.
  pek-server --update      (or run the install line again)

ACCOUNTS (sign in, and sync history between devices)
  pek-server --add-user alice          asks for the password; the first account is the owner
  In PEK TV: Settings > Account > Sign in.   Also: --list-users, --set-password <name>, --sign-out <name>, --remove-user <name>

IN THE BACKGROUND
  pek-server-start       start (with a wake lock)        pek-server-stop    stop
  cat ~/.local/share/pek-server/pairing.txt              address, pairing code, access key
  Start with the phone: install Termux:Boot (F-Droid) and open it once.

KEEP IT RUNNING
  Android stops background apps to save battery. Set Termux to "Unrestricted" (Android settings > Apps > Termux >
  Battery) and keep the device plugged in and on Wi-Fi. A spare phone or an Android TV box works best.
  Android 12+ may still stop it ("phantom process killer"); if that happens, see SELFHOST.md for the adb fix.

WHERE THINGS ARE
  ~/.local/share/pek-server/   library, settings, server.log, access-key.txt, pairing.txt
  $PREFIX/opt/pek-server/      the program
  Options: pek-server --help (--port, --name, --new-key, --rescan-minutes ...)   Remove: pek-server-uninstall
