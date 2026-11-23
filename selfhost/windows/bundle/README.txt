PEK Server - your own PEK TV server on this PC
================================================

START
  Double-click "Start PEK Server.bat". The first time it asks for the folder that holds
  your movies / shows / music (for example D:\Movies). It scans the folder, then prints:
    - the address(es) of this PC, like http://192.168.1.20:8080
    - a 6-digit PAIRING CODE (works for 10 minutes, for one device)
    - your ACCESS KEY (also saved in %LOCALAPPDATA%\PEK Server\pairing.txt). Keep it private.

CONNECT A TV / PHONE
  In PEK TV open  Settings > Library > Connect to a server.  This PC shows up in the list
  (or type its address), then type the pairing code. Pairing another device later:
  double-click "Pair a device.bat" for a new code. Typing the access key instead of a
  code works too.

  Windows asks about network access the first time: choose "Private networks".
  If a device cannot connect, double-click "Allow network access.bat" (needs administrator).

QUICK TEST (no app needed)
  On another device on the same Wi-Fi open  http://<address>:8080/api/movies?token=<key>
  and you should see your movies as text.

TMDB (titles, posters, plots) - needs YOUR OWN free key: themoviedb.org > Settings > API
  Double-click "Set TMDb key.bat", paste the key, then restart PEK Server.
  Without a key only your own .nfo files and pictures are used.

SUBTITLES - subtitle search needs YOUR OWN free OpenSubtitles key: https://www.opensubtitles.com/en/consumers
  Double-click "Set subtitles key.bat", paste the key (and, if you like, your OpenSubtitles login), then restart PEK Server.

UPDATES - PEK Server never updates by itself; it only tells you (log, and PEK TV's Settings > Library) when a new one is out.
  Double-click "Update PEK Server.bat" when you want to update. Your library, accounts and settings are kept.

ACCOUNTS (sign in, and sync history between devices)
  Double-click "Add a user.bat" for each person. In PEK TV they sign in under Settings > Account
  (or with "Sign in instead" on the pairing screen, which also pairs the device). Their watch history,
  resume points, favorites and profiles then sync between their devices through this PC.
  pek-server.exe --list-users | --set-password <name> | --sign-out <name> | --remove-user <name>

RUN IN THE BACKGROUND, START WITH WINDOWS
  "Start with Windows (on).bat"   starts the server hidden each time you sign in
  "Start with Windows (off).bat"  turns that off
  "Stop PEK Server.bat"           stops a hidden server

MORE
  Your library, settings and logs are in  %LOCALAPPDATA%\PEK Server   (server.log is the first place to look).
  Options:  pek-server.exe --help      (--add-media, --port, --local-only, --new-key, --pair, --name ...)
