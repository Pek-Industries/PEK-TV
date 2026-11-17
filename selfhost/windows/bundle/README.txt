PEK Server - your own PEK TV server on this PC
================================================

START
  Double-click "Start PEK Server.bat". The first time it asks for the folder that holds
  your movies / shows / music (for example D:\Movies). It scans the folder, then prints:
    - the address(es) of this PC, like http://192.168.1.20:8080
    - your ACCESS KEY (also saved in %LOCALAPPDATA%\PEK Server\pairing.txt)
  Put those two into the app on your other devices. Keep the key private.

  Windows asks about network access the first time: choose "Private networks".
  If a device cannot connect, double-click "Allow network access.bat" (needs administrator).

QUICK TEST (no app needed)
  On another device on the same Wi-Fi open  http://<address>:8080/api/movies?token=<key>
  and you should see your movies as text.

RUN IN THE BACKGROUND, START WITH WINDOWS
  "Start with Windows (on).bat"   starts the server hidden each time you sign in
  "Start with Windows (off).bat"  turns that off
  "Stop PEK Server.bat"           stops a hidden server

MORE
  Your library, settings and logs are in  %LOCALAPPDATA%\PEK Server   (server.log is the first place to look).
  Options:  pek-server.exe --help      (--add-media, --port, --local-only, --new-key ...)
