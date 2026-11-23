# PEK Server (self-hosted): Windows and Linux

The same C++ server the apps run inside themselves (`backend/`), as a program of its own: `pek-server.exe`. It keeps your library
(scan, posters and titles from TMDb, Fix match data) and streams it to other devices on your network. It runs on the owner's own PC;
there is no cloud.

```
selfhost/linux/                see "Linux" below
selfhost/windows/
  main.cpp                    the program: data folder, access key, first-run folder prompt, scanner, server, log
  CMakeLists.txt              builds pek-server.exe from main.cpp + the shared backend/ sources (MSYS2 clang, like windows/backend)
  build.sh / package.sh       build, then zip (exe + its DLLs + ffprobe.exe + cacert.pem + the .bat helpers)
  collect-deps.sh             finds the DLLs the exe needs (OpenSSL, SQLite) so the zip can ship them next to it
  bundle/                     what goes in the zip next to the exe: Start / Allow network access / Start with Windows / Stop, README.txt
.github/workflows/build_selfhost_windows.yml     builds the zip on GitHub (x64 and arm64)
```

## Build it

**A. On GitHub (nothing to install).** Push the repo, open **Actions > Build PEK Server (Windows, self-hosted) > Run workflow** and tick
**publish**. Each CPU type then goes to the releases page as its own zip: `PEK-Server-<version>-windows-x64.zip` and
`PEK-Server-<version>-windows-arm64.zip` in `server-v<version>`, and the same files without the version in `server-latest`
(fixed links, e.g. `https://github.com/Pek-Industries/PEK-TV/releases/download/server-latest/PEK-Server-windows-x64.zip`).
Without "publish" they are only in the run's Artifacts (where GitHub wraps each one in another zip).

**B. On a Windows PC.** Install [MSYS2](https://www.msys2.org), open **MSYS2 CLANG64** (ARM64 PCs: CLANGARM64), then:
```
pacman -S --needed mingw-w64-clang-x86_64-{toolchain,cmake,ninja,openssl,sqlite3,pkgconf,zlib} p7zip curl git
cd /c/path/to/PEK-TV-main
bash selfhost/windows/build.sh          # -> build/selfhost/pek-server.exe
bash selfhost/windows/package.sh win64  # -> dist-selfhost/PEK-Server-<version>-windows-x64.zip
```

## Run it
1. Unzip anywhere (a folder you can write to).
2. Double-click **Start PEK Server.bat**. First run: type your media folder (for example `D:\Movies`).
3. It scans, then prints this PC's address(es), a 6-digit **pairing code** and the **access key**. They are also saved in `%LOCALAPPDATA%\PEK Server\pairing.txt`.
4. Allow Windows Firewall for **Private networks** when asked (or run **Allow network access.bat** as administrator).
5. Test from a phone on the same Wi-Fi: `http://<address>:8080/api/movies?token=<key>` should list your movies.
6. Connect PEK TV: see **Connecting the apps** below. Another device later: double-click **Pair a device.bat** for a new code.

Hide it and start it with Windows: **Start with Windows (on).bat**. Stop a hidden one: **Stop PEK Server.bat**.
Options: `pek-server.exe --help` (`--add-media`, `--port`, `--local-only`, `--new-key`, `--pair`, `--name`, `--rescan-minutes`, `--data`).

## Where things are
`%LOCALAPPDATA%\PEK Server\`: `server.log` (look here first), `pairing.txt`, `access-key.txt`, `server-id.txt`, `sources.tsv` (media folders),
`library.db` (the library), `net_credentials.tsv`, `plugins\`, `skins\`.

## Connecting the apps (Windows and Linux)
In PEK TV: **Settings > Library > Connect to a server** (a new install also asks "Where is your library?" during setup).
1. Servers on the same network are listed by themselves (UDP broadcast on port 8768). Not listed (Docker bridge network, another
   subnet, a VPN)? Type the address, e.g. `192.168.1.20` (port 8080 is assumed) or `https://pek.example.com`.
2. Type the 6-digit pairing code. One code pairs one device and works for 10 minutes; 5 wrong tries end it. New code:
   `pek-server --pair` on the server, **Pair a device.bat** on Windows, or **Pair another device** on a TV / phone that is already
   connected. Pasting the access key from `pairing.txt` instead of a code also works.
3. The app keeps the key and sends it with every library request (`X-Pek-Token`, or `?pek_t=` for the video player).

Only the **library** moves to the server: movies, shows, music, artwork, streams, media sources, Fix match and subtitles. Plugins,
skins, torrents and trailers stay on the device (the Python plugin host belongs to the app). Settings > Library > Media sources then
lists and adds the *server's* folders. If the server is away the app opens with the lists saved last time and says so; if its
address changed (DHCP), the app finds it again by its id. `pek-server --new-key` unpairs every device; they are asked to pair again.

How it works (for contributors): `backend/selfhost.h` (`GET /api/server/info` and `POST /api/pair` answer without the key,
`POST /api/pair/new` needs the key or loopback), `backend/selfhost_beacon.h` (UDP 8768), `flutter_ui/lib/src/server_target.dart`
(pairing, discovery, the saved target), `flutter_ui/lib/src/server_connect.dart` (the screens) and `Api.urlFor` in `api.dart`,
which decides per path whether a request goes to the library server or to this device.

## Accounts and sync (Windows, Linux, Termux)
The server can hold the household's accounts and do what PEK Cloud does for everyone else: keep each account's profiles, watch
history, resume points, favorites, ratings, skins and dashboard settings, and sync them between that account's devices. Free on
your own server; nothing goes to PEK Cloud.

```
pek-server --add-user alice                 # asks for the password twice (or PEK_PASSWORD=...); the first account is the owner
pek-server --add-user bob --email bob@example.com   # bob can then sign in with his email too
pek-server --list-users                     # who has an account, and on how many devices they are signed in
pek-server --set-password bob               # a new password; bob is signed out everywhere
pek-server --sign-out bob                   # signs bob out on every device; his account and data stay
pek-server --remove-user bob                # deletes bob's account and everything it synced; his devices are signed out at once
```
Their devices are told why: "You were removed from …", "Your password was changed" or "You were signed out" (the server keeps
the reason for each ended session for six months). If the server stops answering, a signed-in device shows "Can't access the
server right now", pauses syncing, and tries again by itself (15 s, 30 s, 60 s, then every 2 minutes) until it is back.
After `--new-key`, paired devices show "This device was disconnected" with a button to pair again.
Windows: **Add a user.bat** (or the same options on `pek-server.exe`). Docker: `docker exec -it pek-server pek-server --add-user alice`.
These work while the server is running.

In PEK TV: **Settings > Account > Sign in** with the username (or email) and password. On a device that is not paired yet, the
Connect screen offers **Sign in** instead of a pairing code: the account also pairs the device. As soon as a server with accounts
is paired, signing in and sync go to it (an earlier PEK Cloud session on that device is signed out; PEK Cloud keeps its data).
Plugin backup and Discord linking are PEK Cloud services and are off while signed in to a server. Forgotten password: the owner
runs `--set-password`; there is no email on a self-hosted server.

How it works: `backend/accounts.h` answers the same `/v1` calls as PEK Cloud (`auth/login`, `auth/logout`, `auth/confirm`, `me`,
`profiles/sync`, `sync`, `account`) and stores everything in `<data>/accounts.db` (SQLite). Passwords are PBKDF2-SHA256 hashes
(210,000 rounds); session tokens are stored as SHA-256 hashes. Every call except `auth/login` needs the access key as well as the
session. 10 wrong passwords from one address mean 15 minutes' wait. Sync is last-writer-wins per item with a change cursor, 2000
items a page, like PEK Cloud. **Back up `accounts.db`** with the rest of the data folder: unlike the library database it cannot
be rebuilt by a rescan, so the server never replaces it when it cannot be read (accounts then stay off and the log says why).

## Version 1: what is not there yet
- **Continue watching from before pairing** points at the old library's files; items started on the server work as usual.
- **DVD images and VIDEO_TS folders on the server** are listed but do not play yet (the player opens them as a local path).
- **No plugins.** On Windows and Android the Python plugin host belongs to the app, not to the C++ server.
- **No SMB / NFS / torrent streaming** in this build (FTP, WebDAV and DLNA sources work). They can be added like in `windows/backend`.
- **No HTTPS.** The access key travels in plain HTTP, fine on a home network. For use away from home put it behind Tailscale
  or a reverse proxy with TLS; do not just forward the port on your router. The app warns when a typed address looks like the
  internet without https.

---

# Linux (servers, NAS, Raspberry Pi, Docker)

One **static** program (built on Alpine / musl), so the same `pek-server` file runs on any Linux distribution, with no libraries to install.
Intel/AMD (`x64`) and ARM (`arm64`: Raspberry Pi 4/5, ARM servers).

```
selfhost/linux/
  main.cpp                 the program (Linux version of the Windows main.cpp): env + options, access key, scanner, server, SIGTERM
  CMakeLists.txt           builds pek-server from main.cpp + the shared backend/ sources (-DPEK_STATIC=ON = fully static)
  Dockerfile               builds the static program (--target binary) or the Docker image (default)
  docker-compose.yml       run the image
  build.sh / package.sh    build with Docker, then make PEK-Server-<version>-linux-<arch>.tar.gz (+ ffprobe, cacert.pem, install.sh)
  install.sh / uninstall.sh / pek-server.service     install as a systemd service
.github/workflows/build_selfhost_linux.yml           builds, smoke-tests and packages x64 and arm64 on GitHub
```
`backend/server.cpp` got a Linux folder-picker (`storageRoots`): the picker offers the folders in `PEK_MEDIA` / `PEK_MEDIA_ROOTS`, the home
folder, and drives mounted under `/mnt`, `/media`, `/run/media`, `/srv`. The Android and Windows branches are unchanged.

## Build it
**A. On GitHub:** Actions > **Build PEK Server (Linux, self-hosted)** > Run workflow. It builds, starts the program and checks that
`/api/movies` answers, then gives you two downloads: `PEK-Server-linux-x64` and `PEK-Server-linux-arm64`
(each holds a `.tar.gz` and its `.sha256`). Tick **publish** to also put them on the releases page as separate files, like the
Windows build: versioned in `server-v<version>`, fixed names (`PEK-Server-linux-x64.tar.gz`, `...-arm64.tar.gz`) in `server-latest`.

**B. On a Linux machine with Docker:**
```
bash selfhost/linux/build.sh        # -> build/selfhost-linux/pek-server
bash selfhost/linux/package.sh      # -> dist-selfhost/PEK-Server-<version>-linux-<arch>.tar.gz
```

## Run it
**As a service (systemd):**
```
tar xzf PEK-Server-*-linux-x64.tar.gz && cd PEK-Server-*
sudo ./install.sh --media /srv/movies --media /srv/music        # [--port 8080]
```
It makes a `pek` user, installs to `/opt/pek-server`, keeps data in `/var/lib/pek-server`, starts at boot, and prints the address(es), a
**pairing code** and the **access key** (also in `/var/lib/pek-server/pairing.txt`). Pair another device: `/opt/pek-server/pek-server --pair`. The media folders must be readable by the `pek` user. Settings live in
`/etc/pek-server.env` (`PEK_MEDIA=/a:/b`, `PEK_PORT=8080`); `sudo systemctl restart pek-server` after editing. Logs: `journalctl -u pek-server -f`.
Open the ports if there is a firewall (`sudo ufw allow 8080/tcp && sudo ufw allow 8768/udp`; 8768 lets the app find the server). Remove: `sudo ./uninstall.sh [--purge]`.

**Just run it:** `./pek-server --add-media /srv/movies` (Ctrl+C stops it; data in `~/.local/share/pek-server`).

**Docker:**
```
docker build -f selfhost/linux/Dockerfile -t pek-server .
docker run -d --name pek-server --restart unless-stopped -p 8080:8080 \
  -v pek-data:/data -v /srv/media:/media:ro pek-server
docker logs pek-server          # shows the pairing code and the access key
docker exec pek-server pek-server --pair     # a new pairing code
```
Or `docker compose -f selfhost/linux/docker-compose.yml up -d`. In the apps use the address of the machine Docker runs on, not the container's. The app's network search does not reach a container on
Docker's normal bridge network: type the address, or run it with `--network host` (Linux) so it can be found.
With a bind-mounted data folder, run the container as its owner: `--user $(id -u):$(id -g)`.

**Test with no app:** on another device open `http://<address>:8080/api/movies?token=<key>`.
Options: `pek-server --help` (also `--print-key`, `--pair`, `--name`; settings from `PEK_DATA`, `PEK_MEDIA`, `PEK_PORT`, `PEK_BIND`, `PEK_TOKEN`, `PEK_NAME`).

Same limits as the Windows version (no accounts / logins yet, no plugins, no SMB / NFS / torrent, no built-in HTTPS).

---

# Android (Termux): phones and TV boxes

A ready-made program for [Termux](https://termux.dev) (from F-Droid or GitHub; the Google Play version is outdated). Nobody builds
anything on the phone: GitHub Actions cross-compiles it with the Android NDK. It is the same program as the Linux server
(`selfhost/linux/main.cpp`; the Android differences are under `__ANDROID__`), with OpenSSL, SQLite and libc++ built in.
64-bit ARM (`arm64-v8a`: almost every phone and TV box since 2017) and 32-bit ARM (`armeabi-v7a`: older / cheap TV boxes). Android 8+.

```
selfhost/termux/
  CMakeLists.txt           NDK build of ../linux/main.cpp + backend/ (OpenSSL / SQLite from android/scripts, like the APK)
  build.sh / package.sh    build both CPU types, then pack PEK-Server-termux-<abi>.tar.gz (+ .sha256, cacert.pem, README.txt)
  install-termux.sh        the installer people run in Termux (also updates)
.github/workflows/build_selfhost_termux.yml   builds, starts the arm64 build inside a Termux container, and (when asked) publishes
```

## Publish it
Actions > **Build PEK Server (Termux, Android)** > Run workflow, tick **publish**. It uploads to two releases, neither marked "latest"
(so the app's own release stays on top): `server-v<version>` (kept) and `server-latest` (always the newest; the installer downloads
from it, so the install line never changes). Without "publish" the files are only in the run's Artifacts.

## Install (on the phone, in Termux)
```
curl -fsSL https://github.com/Pek-Industries/PEK-TV/releases/download/server-latest/install-termux.sh | bash
termux-setup-storage                                   # once: let Termux read your files
pek-server --add-media /storage/emulated/0/Movies      # starts, shows the address + pairing code (Ctrl+C stops)
pek-server-start                                       # later: in the background, with a wake lock (pek-server-stop stops it)
```
It installs ffmpeg (for ffprobe), checks the download's checksum, puts the program in `$PREFIX/opt/pek-server` with the commands
`pek-server`, `pek-server-start`, `pek-server-stop`, `pek-server-uninstall`, and a Termux:Boot script (`~/.termux/boot/start-pek-server`)
that starts it with the phone once the Termux:Boot app is installed and opened. Running the same line again updates it (a running
server is stopped and started again). Data: `~/.local/share/pek-server` (library, `server.log`, `pairing.txt`, `access-key.txt`).

**Port 8090** by default, not 8080: PEK TV installed on the same phone already runs its own server on 8080. The name devices show is
the phone's model ("Pixel 7 (Termux)"); change it with `--name`. Pairing, discovery and the Connect screen work exactly as above.

## Keeping it running
Android stops background work to save battery. Set Termux's battery use to **Unrestricted** (Settings > Apps > Termux > Battery),
keep the device plugged in and on Wi-Fi; `pek-server-start` takes a wake lock. Android 12+ can still kill it ("phantom process killer",
Termux shows `[Process completed (signal 9)]`). Android 14+: Developer options > **Disable child process restrictions**. Android 12-13,
once from a PC with adb:
```
adb shell "/system/bin/device_config set_sync_disabled_for_tests persistent; /system/bin/device_config put activity_manager max_phantom_processes 2147483647"
```
Best on a spare phone or an Android TV box (Shield, Chromecast with Google TV + storage, Fire TV with Termux sideloaded).

Same limits as the other versions (no accounts yet, no plugins, no SMB / NFS, no built-in HTTPS). Build it yourself on a PC:
`ANDROID_NDK_HOME=/path/to/ndk bash selfhost/termux/build.sh && bash selfhost/termux/package.sh`.
