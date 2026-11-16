// PEK Server for Linux: the self-hosted edition. The same C++ server the apps run inside themselves (backend/), as a program of its
// own that keeps your library and streams it to other devices. Meant for servers, NAS boxes, mini PCs and Docker: no window, logs go to
// the console (systemd journal / docker logs) and to <data>/server.log, and it stops cleanly on SIGTERM.
//
//   pek-server                          start (asks for a media folder on the first run when started from a terminal)
//   pek-server --add-media /srv/movies  add a folder, then start
//   pek-server --help
//
// Settings can also come from the environment (handy for Docker and systemd):
//   PEK_DATA=/data  PEK_MEDIA=/media/movies:/media/music  PEK_PORT=8080  PEK_BIND=0.0.0.0  PEK_TOKEN=<access key>
// Remote access is the server's own PEK_BIND / PEK_TOKEN mechanism (backend/server.cpp): every request from another device must carry
// the access key. Unless PEK_TOKEN is given, the key is made once and kept in <data>/access-key.txt (readable by its owner only),
// so paired devices stay paired across restarts.
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <pwd.h>
#include <sys/socket.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#include "server.h"
#include "media_scanner.h"
#include "vfs.h"
#include "torrent_routes.h"

#ifndef PEK_SERVER_VERSION
#define PEK_SERVER_VERSION "dev"
#endif

namespace fs = std::filesystem;

static volatile std::sig_atomic_t g_stop = 0;
static void onSignal(int) { g_stop = 1; }

static std::string trim(std::string s) {
    auto bad = [](char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '"'; };
    while (!s.empty() && bad(s.back())) s.pop_back();
    size_t i = 0;
    while (i < s.size() && bad(s[i])) ++i;
    return s.substr(i);
}
static std::string envOr(const char* name, const std::string& fallback = "") {
    const char* v = std::getenv(name);
    return (v && *v) ? std::string(v) : fallback;
}

// ---- log: everything the server prints goes to the console AND to <data>/server.log ------------------------------------------
class TeeBuf : public std::streambuf {
public:
    TeeBuf(std::streambuf* console, std::ofstream& file) : c_(console), f_(file) {}
protected:
    int overflow(int ch) override {
        if (ch == EOF) return 0;
        if (c_) c_->sputc(static_cast<char>(ch));
        f_.put(static_cast<char>(ch));
        return ch;
    }
    std::streamsize xsputn(const char* s, std::streamsize n) override {
        if (c_) c_->sputn(s, n);
        f_.write(s, n);
        return n;
    }
    int sync() override {
        if (c_) c_->pubsync();
        f_.flush();
        return 0;
    }
private:
    std::streambuf* c_;
    std::ofstream& f_;
};

// ---- access key --------------------------------------------------------------------------------------------------------------
static std::string randomHex(size_t bytes) {
    std::ifstream in("/dev/urandom", std::ios::binary);
    std::string raw(bytes, '\0');
    if (!in.read(raw.data(), static_cast<std::streamsize>(bytes))) return {};
    static const char* hex = "0123456789abcdef";
    std::string out;
    for (unsigned char c : raw) { out += hex[c >> 4]; out += hex[c & 15]; }
    return out;
}
static bool goodKey(const std::string& k) {
    if (k.size() < 24) return false;
    for (char c : k) if (!isalnum(static_cast<unsigned char>(c))) return false;
    return true;
}
static void ownerOnly(const fs::path& p) {
    std::error_code ec;
    fs::permissions(p, fs::perms::owner_read | fs::perms::owner_write, fs::perm_options::replace, ec);
}
static std::string loadOrMakeKey(const fs::path& file, bool forceNew, bool& made) {
    made = false;
    if (!forceNew) {
        std::ifstream in(file);
        std::string k;
        if (in && std::getline(in, k)) { k = trim(k); if (goodKey(k)) return k; }
    }
    const std::string k = randomHex(24);   // 48 hex characters
    if (k.empty()) return {};
    { std::ofstream out(file, std::ios::trunc); out << k << "\n"; }
    ownerOnly(file);
    made = true;
    return k;
}

// ---- network helpers ---------------------------------------------------------------------------------------------------------
// Is something already listening on the port? (SO_REUSEADDR set, like the server itself, so a lingering closed connection does not count.)
static bool portTaken(const std::string& bindAddr, int port) {
    const int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return false;
    int one = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(static_cast<uint16_t>(port));
    if (inet_pton(AF_INET, bindAddr.c_str(), &a.sin_addr) != 1) a.sin_addr.s_addr = htonl(INADDR_ANY);
    const bool taken = bind(sock, reinterpret_cast<sockaddr*>(&a), sizeof a) != 0 && errno == EADDRINUSE;
    close(sock);
    return taken;
}

static bool waitForPort(int port, int timeoutMs) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (std::chrono::steady_clock::now() < end) {
        const int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s >= 0) {
            sockaddr_in a{};
            a.sin_family = AF_INET;
            a.sin_port = htons(static_cast<uint16_t>(port));
            inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
            const bool ok = connect(s, reinterpret_cast<sockaddr*>(&a), sizeof a) == 0;
            close(s);
            if (ok) return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }
    return false;
}

// This machine's IPv4 addresses (interface up, not loopback, not 169.254.x.x self-assigned).
static std::vector<std::pair<std::string, std::string>> lanAddresses() {   // {interface name, address}
    std::vector<std::pair<std::string, std::string>> out;
    ifaddrs* list = nullptr;
    if (getifaddrs(&list) != 0) return out;
    for (ifaddrs* a = list; a; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) continue;
        if (!(a->ifa_flags & IFF_UP) || (a->ifa_flags & IFF_LOOPBACK)) continue;
        char ip[INET_ADDRSTRLEN] = {};
        inet_ntop(AF_INET, &reinterpret_cast<sockaddr_in*>(a->ifa_addr)->sin_addr, ip, sizeof ip);
        const std::string s = ip;
        if (s.rfind("127.", 0) == 0 || s.rfind("169.254.", 0) == 0) continue;
        out.emplace_back(a->ifa_name ? a->ifa_name : "net", s);
    }
    freeifaddrs(list);
    return out;
}

// ---- command line ------------------------------------------------------------------------------------------------------------
struct Options {
    std::string dataDir;
    int port = 8080;
    std::string bind = "0.0.0.0";
    std::vector<std::string> media;
    bool newKey = false, noScan = false, printKey = false, help = false, version = false;
    int rescanMinutes = 60;
};

static void usage() {
    std::cout <<
        "PEK Server " PEK_SERVER_VERSION " - your own PEK TV server\n\n"
        "  pek-server [options]\n\n"
        "  --add-media <folder>   add a movie / show / music folder (can be repeated; or PEK_MEDIA=/a:/b)\n"
        "  --data <folder>        where the server keeps its library and settings (or PEK_DATA)\n"
        "                         default: /var/lib/pek-server when run as root, else ~/.local/share/pek-server\n"
        "  --port <number>        port to listen on (default 8080, or PEK_PORT)\n"
        "  --local-only           answer this machine only (no other device can connect)\n"
        "  --new-key              make a new access key (every paired device must pair again)\n"
        "  --print-key            print the access key and exit\n"
        "  --rescan-minutes <n>   look for new files every n minutes, 0 = never (default 60)\n"
        "  --no-scan              do not scan at start-up\n"
        "  --version, --help\n";
}

static bool parseArgs(int argc, char** argv, Options& o) {
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        auto next = [&](std::string& v) {
            if (i + 1 >= argc) { std::cerr << "Missing value after " << a << std::endl; return false; }
            v = argv[++i];
            return true;
        };
        std::string v;
        if (a == "--help" || a == "-h") o.help = true;
        else if (a == "--version") o.version = true;
        else if (a == "--add-media") { if (!next(v)) return false; o.media.push_back(trim(v)); }
        else if (a == "--data") { if (!next(v)) return false; o.dataDir = trim(v); }
        else if (a == "--port") {
            if (!next(v)) return false;
            o.port = atoi(v.c_str());
            if (o.port < 1 || o.port > 65535) { std::cerr << "--port must be 1 to 65535" << std::endl; return false; }
        }
        else if (a == "--local-only") o.bind = "127.0.0.1";
        else if (a == "--new-key") o.newKey = true;
        else if (a == "--print-key") o.printKey = true;
        else if (a == "--no-scan") o.noScan = true;
        else if (a == "--rescan-minutes") { if (!next(v)) return false; o.rescanMinutes = (std::max)(0, atoi(v.c_str())); }
        else { std::cerr << "Unknown option: " << a << "  (try --help)" << std::endl; return false; }
    }
    return true;
}

static fs::path exeDir() {
    std::error_code ec;
    const fs::path p = fs::read_symlink("/proc/self/exe", ec);
    return ec ? fs::path(".") : p.parent_path();
}

static bool onPath(const std::string& program) {
    std::stringstream ss(envOr("PATH"));
    std::string dir;
    while (std::getline(ss, dir, ':')) {
        if (dir.empty()) continue;
        if (access((dir + "/" + program).c_str(), X_OK) == 0) return true;
    }
    return false;
}

static std::string defaultDataDir() {
    if (geteuid() == 0) return "/var/lib/pek-server";
    const std::string xdg = envOr("XDG_DATA_HOME");
    if (!xdg.empty()) return xdg + "/pek-server";
    std::string home = envOr("HOME");
    if (home.empty()) if (const passwd* pw = getpwuid(geteuid())) home = pw->pw_dir ? pw->pw_dir : "";
    return home.empty() ? std::string("./pek-data") : home + "/.local/share/pek-server";
}

int main(int argc, char** argv) {
    Options opt;
    if (!parseArgs(argc, argv, opt)) return 2;
    if (opt.help) { usage(); return 0; }
    if (opt.version) { std::cout << "PEK Server " << PEK_SERVER_VERSION << std::endl; return 0; }

    // environment fills in what the command line did not say
    if (opt.dataDir.empty()) opt.dataDir = envOr("PEK_DATA", defaultDataDir());
    if (const std::string p = envOr("PEK_PORT"); !p.empty() && opt.port == 8080) { const int n = atoi(p.c_str()); if (n >= 1 && n <= 65535) opt.port = n; }
    if (const std::string b = envOr("PEK_BIND"); !b.empty() && opt.bind == "0.0.0.0") opt.bind = b;
    {
        const std::string m = envOr("PEK_MEDIA");
        size_t start = 0;
        while (start <= m.size()) {
            size_t colon = m.find(':', start);
            if (colon == std::string::npos) colon = m.size();
            const std::string part = trim(m.substr(start, colon - start));
            start = colon + 1;
            if (!part.empty()) opt.media.push_back(part);
        }
    }

    signal(SIGPIPE, SIG_IGN);   // a client that goes away mid-stream must not kill the server
    signal(SIGINT, onSignal);
    signal(SIGTERM, onSignal);

    // ---- data folder + log ---------------------------------------------------------------------------------------------------
    std::error_code ec;
    fs::create_directories(opt.dataDir, ec);
    fs::create_directories(opt.dataDir + "/plugins", ec);
    fs::create_directories(opt.dataDir + "/skins", ec);
    if (ec) { std::cerr << "Cannot create the data folder " << opt.dataDir << ": " << ec.message() << std::endl; return 1; }

    const bool remote = opt.bind != "127.0.0.1";
    if (opt.printKey) {   // no log, no server: just the key
        bool made = false;
        const std::string k = loadOrMakeKey(opt.dataDir + "/access-key.txt", opt.newKey, made);
        std::cout << k << std::endl;
        return k.empty() ? 1 : 0;
    }

    static std::ofstream logFile;
    const fs::path logPath = fs::path(opt.dataDir) / "server.log";
    if (fs::exists(logPath, ec) && fs::file_size(logPath, ec) > 5u * 1024 * 1024)
        fs::rename(logPath, fs::path(opt.dataDir) / "server.old.log", ec);
    logFile.open(logPath, std::ios::app);
    static TeeBuf teeOut(std::cout.rdbuf(), logFile);
    static TeeBuf teeErr(std::cerr.rdbuf(), logFile);
    std::cout.rdbuf(&teeOut);
    std::cerr.rdbuf(&teeErr);

    std::cout << "==== PEK Server " << PEK_SERVER_VERSION << " starting ====" << std::endl;

    // ---- environment the server reads ----------------------------------------------------------------------------------------
    const fs::path here = exeDir();
    if (fs::exists(here / "cacert.pem", ec)) setenv("SSL_CERT_FILE", (here / "cacert.pem").c_str(), 0);   // minimal containers have no CA bundle
    if (fs::exists(here / "ffprobe", ec)) setenv("PEK_FFPROBE", (here / "ffprobe").c_str(), 1);
    else if (!onPath("ffprobe")) std::cout << "[warning] ffprobe not found (next to pek-server or on PATH): the library scan cannot read file details. Install ffmpeg." << std::endl;

    std::string key;
    if (remote) {
        const std::string fromEnv = envOr("PEK_TOKEN");
        if (!fromEnv.empty()) {
            if (!goodKey(fromEnv)) { std::cerr << "PEK_TOKEN must be at least 24 letters / digits." << std::endl; return 1; }
            key = fromEnv;
        } else {
            bool made = false;
            key = loadOrMakeKey(fs::path(opt.dataDir) / "access-key.txt", opt.newKey, made);
            if (key.empty()) { std::cerr << "Could not make an access key." << std::endl; return 1; }
            if (made) std::cout << "A new access key was made." << std::endl;
        }
        setenv("PEK_TOKEN", key.c_str(), 1);
    }
    setenv("PEK_BIND", opt.bind.c_str(), 1);

    if (portTaken(opt.bind, opt.port)) {
        std::cerr << "Port " << opt.port << " is already in use (is PEK Server already running?). Use --port to pick another." << std::endl;
        return 1;
    }

    // ---- library -------------------------------------------------------------------------------------------------------------
    vfs::init(opt.dataDir + "/net_credentials.tsv");
    setTorrentDataDir(opt.dataDir);
    MediaScanner* scanner = new MediaScanner(opt.dataDir + "/sources.tsv", opt.dataDir + "/media_cache.tsv");
    scanner->loadFromDisk();
    scanner->setShowResolver(PekServer::resolveShowName);

    for (const auto& m : opt.media) {
        if (scanner->addMediaDir(m)) std::cout << "Media folder: " << m << std::endl;
        else std::cerr << "Not a folder, skipped: " << m << std::endl;
    }
    if (scanner->getMediaDirs().empty() && isatty(STDIN_FILENO)) {
        std::cout << "\nNo media folders yet. Type the folder that holds your movies / shows / music\n"
                     "(for example /srv/movies), or press Enter to add one later with --add-media: " << std::flush;
        std::string m;
        std::getline(std::cin, m);
        m = trim(m);
        if (!m.empty()) {
            if (scanner->addMediaDir(m)) std::cout << "Media folder: " << m << std::endl;
            else std::cerr << "That is not a folder: " << m << std::endl;
        }
    }
    std::cout << "Media folders: " << scanner->getMediaDirs().size() << std::endl;

    // ---- scan now, and look for new files from time to time ------------------------------------------------------------------
    std::thread([scanner, opt]() {
        if (!opt.noScan) scanner->scan();
        auto next = std::chrono::steady_clock::now() + std::chrono::minutes(opt.rescanMinutes);
        while (!g_stop) {
            std::this_thread::sleep_for(std::chrono::seconds(1));
            if (opt.rescanMinutes > 0 && std::chrono::steady_clock::now() >= next) {
                if (!scanner->isScanning()) scanner->scan();
                next = std::chrono::steady_clock::now() + std::chrono::minutes(opt.rescanMinutes);
            }
        }
    }).detach();

    // ---- the server (same call the apps make) --------------------------------------------------------------------------------
    const std::string plugins = opt.dataDir + "/plugins", skins = opt.dataDir + "/skins";
    const int port = opt.port;
    std::thread([port, plugins, skins, scanner]() {
        PekServer::start(port, plugins, skins, []() { return std::vector<std::string>(); }, scanner, "");
    }).detach();

    if (!waitForPort(port, 10000)) {
        std::cerr << "The server did not come up. See " << opt.dataDir << "/server.log" << std::endl;
        return 1;
    }

    // ---- how to connect ------------------------------------------------------------------------------------------------------
    std::ostringstream info;
    info << "PEK Server " PEK_SERVER_VERSION " is running.\n\n";
    if (remote) {
        const auto addrs = lanAddresses();
        info << "Connect your devices to one of these addresses:\n";
        if (addrs.empty()) info << "  (no network connection found)\n";
        for (const auto& a : addrs) info << "  http://" << a.second << ":" << port << "    (" << a.first << ")\n";
        if (fs::exists("/.dockerenv", ec)) info << "  Running in Docker: use the address of the machine Docker runs on, not the one above.\n";
        info << "\nAccess key:\n  " << key << "\n"
             << "\nAnyone with this key can use your library - keep it private.\n"
             << "To test from a browser on another device, open  http://<address>:" << port << "/api/movies?token=" << key << "\n";
    } else {
        info << "Local only: http://127.0.0.1:" << port << "  (no other device can connect)\n";
    }
    info << "\nData folder: " << opt.dataDir << "\nLog:         " << opt.dataDir << "/server.log\n";
    std::cout << "\n" << info.str() << std::endl;
    {
        const fs::path pairing = fs::path(opt.dataDir) / "pairing.txt";
        { std::ofstream p(pairing, std::ios::trunc); p << info.str(); }
        ownerOnly(pairing);
    }

    while (!g_stop) std::this_thread::sleep_for(std::chrono::milliseconds(500));
    std::cout << "PEK Server stopped." << std::endl;
    logFile.flush();
    _exit(0);   // the server and scan threads are detached: end the process instead of unwinding under them
}
