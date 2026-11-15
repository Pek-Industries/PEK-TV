// Windows replacement for main() in backend/core.cpp, the same job android/app/src/main/cpp/jni_entry.cpp does on Android:
// start the C++ server inside the app's own process. The runner (windows/runner/pek_host.cpp) loads this DLL and calls
// pek_start(); a mint call gives it the one-shot torrent pass (see torrent_routes.h).
#include <winsock2.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <io.h>
#include <atomic>
#include <iostream>
#include <string>
#include <thread>
#include <vector>
#include "httplib.h"
#include "server.h"
#include "media_scanner.h"
#include "vfs.h"
#include "torrent_routes.h"

static MediaScanner* g_scanner = nullptr;
static std::atomic<bool> g_started{false};

// The server prints with std::cout; a GUI app has no console, so everything goes to <root>/backend.log, which the in-app
// developer console shows (flutter_ui/lib/src/dev_console.dart). The file starts over at each launch.
static void captureStdio(const std::string& file) {
    FILE* f = nullptr;
    if (freopen_s(&f, file.c_str(), "w", stdout) != 0) return;
    FILE* g = nullptr;
    freopen_s(&g, file.c_str(), "a", stderr);
    setvbuf(stdout, nullptr, _IOLBF, 4096);
    setvbuf(stderr, nullptr, _IONBF, 0);
}


// Is something else already listening on (or has Windows reserved) the loopback port? Then the server below would never come up, or
// worse, the app would talk to the other program. Checked with the strictest bind (no address sharing) BEFORE anything starts.
static bool portTaken(int port) {
    SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == INVALID_SOCKET) return false;
    BOOL excl = TRUE;
    setsockopt(sock, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char*>(&excl), sizeof excl);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(static_cast<u_short>(port));
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bool taken = false;
    if (bind(sock, reinterpret_cast<sockaddr*>(&a), sizeof a) == SOCKET_ERROR) {
        const int e = WSAGetLastError();
        taken = (e == WSAEADDRINUSE || e == WSAEACCES);   // 10048 in use / 10013 held exclusively or inside a Windows-reserved range
    }
    closesocket(sock);
    return taken;
}

extern "C" {

// root: the data folder (plugins, skins, sources.tsv, cacert.pem ...). token: the per-launch secret every request must carry.
// ffprobe: full path of ffprobe.exe next to the app ("" = look on PATH). Returns 1 on the first call, 0 if already started,
// -1 when port 8080 is taken by another program (nothing was started; the host shows why).
__declspec(dllexport) int pek_start(const char* rootUtf8, const char* tokenUtf8, const char* ffprobeUtf8) {
    if (g_started.exchange(true)) return 0;
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);

    const std::string root = rootUtf8 ? rootUtf8 : "";
    const std::string token = tokenUtf8 ? tokenUtf8 : "";
    captureStdio(root + "/backend.log");

    if (portTaken(8080)) {
        std::cout << "[PEK Server] port 8080 is already in use or reserved by Windows; the server was not started." << std::endl;
        g_started = false;   // a retry (Try again) may find the port free
        return -1;
    }

    // OpenSSL on Windows does not read the Windows certificate store: use the Mozilla bundle that ships with the app.
    {
        const std::string pem = root + "/cacert.pem";
        if (_access(pem.c_str(), 4) == 0) _putenv_s("SSL_CERT_FILE", pem.c_str());
    }
    if (ffprobeUtf8 && *ffprobeUtf8) _putenv_s("PEK_FFPROBE", ffprobeUtf8);

    const std::string plugins = root + "/plugins";
    const std::string skins = root + "/skins";
    vfs::init(root + "/net_credentials.tsv");
    setTorrentDataDir(root);

    g_scanner = new MediaScanner(root + "/sources.tsv", root + "/media_cache.tsv");
    g_scanner->loadFromDisk();
    g_scanner->setShowResolver(PekServer::resolveShowName);
    std::thread([]() { g_scanner->scan(); }).detach();

    std::thread([plugins, skins, token]() {
        PekServer::start(8080, plugins, skins, []() { return std::vector<std::string>(); }, g_scanner, token);
    }).detach();
    return 1;
}

__declspec(dllexport) const char* pek_mint_grant() {
    static thread_local std::string s;
    s = mintTorrentGrant();
    return s.c_str();
}

}  // extern "C"
