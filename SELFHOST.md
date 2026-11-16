# PEK Server (self-hosted): Windows and Linux

The same C++ server the apps run inside themselves (`backend/`), as a program of its own: `pek-server.exe`. It keeps your library
(scan, posters and titles from TMDb, Fix match data) and streams it to other devices on your network. It runs on the owner's own PC;
there is no cloud.

```
selfhost/linux/                see "Linux" below
selfhost/windows/
  main.cpp                    the program: data folder, access key, first-run folder prompt, scanner, server, log
  CMakeLists.txt              builds pek-server.exe from main.cpp + the shared backend/ sources (MSYS2 clang, like windows/backend)
  build.sh / package.sh       build, then zip (exe + ffprobe.exe + cacert.pem + the .bat helpers)
  dist/                       what goes in the zip next to the exe: Start / Allow network access / Start with Windows / Stop, README.txt
.github/workflows/build_selfhost_windows.yml     builds the zip on GitHub (x64 and arm64)
```

## Build it

**A. On GitHub (nothing to install).** Push the repo, open **Actions > Build PEK Server (Windows, self-hosted) > Run workflow**.
When it finishes, download `PEK-Server-windows-x64` from the run's Artifacts (it is a zip that contains the real zip).

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
3. It scans, then prints this PC's address(es) and the **access key**. They are also saved in `%LOCALAPPDATA%\PEK Server\pairing.txt`.
4. Allow Windows Firewall for **Private networks** when asked (or run **Allow network access.bat** as administrator).
5. Test from a phone on the same Wi-Fi: `http://<address>:8080/api/movies?token=<key>` should list your movies.

Hide it and start it with Windows: **Start with Windows (on).bat**. Stop a hidden one: **Stop PEK Server.bat**.
Options: `pek-server.exe --help` (`--add-media`, `--port`, `--local-only`, `--new-key`, `--rescan-minutes`, `--data`).

## Where things are
`%LOCALAPPDATA%\PEK Server\`: `server.log` (look here first), `pairing.txt`, `access-key.txt`, `sources.tsv` (media folders),
`library.db` (the library), `net_credentials.tsv`, `plugins\`, `skins\`.

## Version 1: what is not there yet
- **The apps cannot connect to it yet.** The Flutter app talks to `http://127.0.0.1:8080` (`flutter_ui/lib/src/api.dart`, `Api.base`).
  Next step: a "Connect to a server" screen that stores the address and access key, and uses them in place of that constant.
- **No plugins.** On Windows and Android the Python plugin host belongs to the app, not to the C++ server.
- **No SMB / NFS / torrent streaming** in this build (FTP, WebDAV and DLNA sources work). They can be added like in `windows/backend`.
- **No HTTPS.** The access key travels in plain HTTP, fine on a home network. For use away from home put it behind Tailscale
  or a reverse proxy with TLS; do not just forward the port on your router.

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
(each holds a `.tar.gz` and its `.sha256`).

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
It makes a `pek` user, installs to `/opt/pek-server`, keeps data in `/var/lib/pek-server`, starts at boot, and prints the address(es) and the
**access key** (also in `/var/lib/pek-server/pairing.txt`). The media folders must be readable by the `pek` user. Settings live in
`/etc/pek-server.env` (`PEK_MEDIA=/a:/b`, `PEK_PORT=8080`); `sudo systemctl restart pek-server` after editing. Logs: `journalctl -u pek-server -f`.
Open the port if there is a firewall (`sudo ufw allow 8080/tcp`). Remove: `sudo ./uninstall.sh [--purge]`.

**Just run it:** `./pek-server --add-media /srv/movies` (Ctrl+C stops it; data in `~/.local/share/pek-server`).

**Docker:**
```
docker build -f selfhost/linux/Dockerfile -t pek-server .
docker run -d --name pek-server --restart unless-stopped -p 8080:8080 \
  -v pek-data:/data -v /srv/media:/media:ro pek-server
docker logs pek-server          # shows the access key
```
Or `docker compose -f selfhost/linux/docker-compose.yml up -d`. In the apps use the address of the machine Docker runs on, not the container's.
With a bind-mounted data folder, run the container as its owner: `--user $(id -u):$(id -g)`.

**Test with no app:** on another device open `http://<address>:8080/api/movies?token=<key>`.
Options: `pek-server --help` (also `--print-key`; settings from `PEK_DATA`, `PEK_MEDIA`, `PEK_PORT`, `PEK_BIND`, `PEK_TOKEN`).

Same limits as the Windows version (no accounts / logins yet, no plugins, no SMB / NFS / torrent, no built-in HTTPS, apps cannot connect yet).
