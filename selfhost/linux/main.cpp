// PEK Server for Linux: the self-hosted edition. The same C++ server the apps run inside themselves (backend/), as a program of its
// own that keeps your library and streams it to other devices. Meant for servers, NAS boxes, mini PCs and Docker: no window, logs go to
// the console (systemd journal / docker logs) and to <data>/server.log, and it stops cleanly on SIGTERM.
//
// The same file is the Android edition that runs in Termux (selfhost/termux, built with the NDK): the few differences are under
// __ANDROID__ (default port 8090, because PEK TV on the same phone already uses 8080; the phone's model as the name; Termux hints).
//
//   pek-server                          start (asks for a media folder on the first run when started from a terminal)
//   pek-server --add-media /srv/movies  add a folder, then start
//   pek-server --pair                   ask the running server for a 6-digit code to pair a TV / phone with
//   pek-server --add-user alice         make an account (asks for the password; the first account is the owner)
//   pek-server --help
//
// Settings can also come from the environment (handy for Docker and systemd):
//   PEK_DATA=/data  PEK_MEDIA=/media/movies:/media/music  PEK_PORT=8080  PEK_BIND=0.0.0.0  PEK_TOKEN=<access key>  PEK_NAME=<shown name>
// Remote access is the server's own PEK_BIND / PEK_TOKEN mechanism (backend/server.cpp): every request from another device must carry
// the access key. Unless PEK_TOKEN is given, the key is made once and kept in <data>/access-key.txt (readable by its owner only),
// so paired devices stay paired across restarts.
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <pwd.h>
#include <sys/socket.h>
#include <termios.h>
#include <unistd.h>
#ifdef __ANDROID__
#include <sys/system_properties.h>
#endif
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
#include "selfhost.h"          // /api/server/info + pairing codes
#include "accounts.h"          // username + password accounts and sync
#include "selfhost_beacon.h"   // found by the app's Connect screen (UDP 8768)
#include "tmdb_key.h"          // the owner's own TMDb key (never PEK's)

#ifndef PEK_SERVER_VERSION
#define PEK_SERVER_VERSION "dev"
#endif

namespace fs = std::filesystem;

#ifdef __ANDROID__
static constexpr int kDefaultPort = 8090;   // PEK TV on the same phone runs its own server on 8080
#else
static constexpr int kDefaultPort = 8080;
#endif

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
    int port = kDefaultPort;
    std::string bind = "0.0.0.0";
    std::string name;
    std::vector<std::string> media;
    bool newKey = false, noScan = false, printKey = false, pair = false, help = false, version = false;
    std::string addUser, removeUser, setPassword, signOut, email;   // account commands (run, then exit)
    bool listUsers = false;
    std::string tmdbKey;   // --tmdb-key <key | off> (run, then exit)
    bool tmdbKeySet = false;
    bool noUpdateCheck = false, checkUpdate = false, update = false, yes = false;   // update check (never automatic)
    std::string subsKey, subsUser;   // --subtitles-key <key | off> / --subtitles-user <name> (run, then exit)
    int rescanMinutes = 60;
};

static void usage() {
    std::cout <<
        "PEK Server " PEK_SERVER_VERSION " - your own PEK TV server\n\n"
        "  pek-server [options]\n\n"
        "  --add-media <folder>   add a movie / show / music folder (can be repeated; or PEK_MEDIA=/a:/b)\n"
        "  --data <folder>        where the server keeps its library and settings (or PEK_DATA)\n"
        "                         default: /var/lib/pek-server when run as root, else ~/.local/share/pek-server\n"
        "  --port <number>        port to listen on (default " + std::to_string(kDefaultPort) + ", or PEK_PORT)\n"
        "  --local-only           answer this machine only (no other device can connect)\n"
        "  --new-key              make a new access key (every paired device must pair again)\n"
        "  --print-key            print the access key and exit\n"
        "  --pair                 get a 6-digit code from the running server to pair a TV / phone (works 10 minutes)\n"
        "  --name <text>          the name devices show for this server (default: the machine's name, or PEK_NAME)\n"
        "\n  Accounts (people sign in with these; history, resume points and favorites sync between their devices):\n"
        "  --add-user <name>      make an account; asks for the password (or PEK_PASSWORD). The first one is the owner\n"
        "  --email <address>      with --add-user: lets them sign in with their email too\n"
        "  --set-password <name>  give an account a new password (signs it out everywhere)\n"
        "  --sign-out <name>      sign an account out on every device (the account and its data stay)\n"
        "  --remove-user <name>   delete an account and everything it synced\n"
        "  --list-users           show the accounts\n\n"
        "  Titles, posters and plots from TMDb need your own free TMDb key (" + std::string(pektmdb::kSignUp) + "):\n"
        "  --tmdb-key <key>       save and test your key (or TMDB_API_KEY); --tmdb-key off removes it. Restart after.\n"
        "                         Without a key, only your own .nfo files and pictures are used.\n"
        "  Subtitle search needs your own free OpenSubtitles API key (" + std::string(peksubs::own::kSignUp) + "):\n"
        "  --subtitles-key <key>  save and test it (or OPENSUBTITLES_API_KEY); --subtitles-key off removes it and the login\n"
        "  --subtitles-user <name> optional: your OpenSubtitles account, for more downloads a day (asks for the password)\n\n"
        "  --rescan-minutes <n>   look for new files every n minutes, 0 = never (default 60)\n"
        "  --no-scan              do not scan at start-up\n"
        "  Updates (PEK Server only checks; it never updates by itself):\n"
        "  --check-update         say whether a newer PEK Server is out\n"
        "  --update [--yes]       download, check and install the newest version, after asking (Linux service: run with sudo)\n"
        "  --no-update-check      do not look for new versions (or PEK_NO_UPDATE_CHECK=1)\n\n"
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
        else if (a == "--pair") o.pair = true;
        else if (a == "--name") { if (!next(v)) return false; o.name = trim(v); }
        else if (a == "--add-user") { if (!next(v)) return false; o.addUser = trim(v); }
        else if (a == "--remove-user") { if (!next(v)) return false; o.removeUser = trim(v); }
        else if (a == "--set-password") { if (!next(v)) return false; o.setPassword = trim(v); }
        else if (a == "--sign-out") { if (!next(v)) return false; o.signOut = trim(v); }
        else if (a == "--email") { if (!next(v)) return false; o.email = trim(v); }
        else if (a == "--list-users") o.listUsers = true;
        else if (a == "--subtitles-key") { if (!next(v)) return false; o.subsKey = trim(v); if (o.subsKey.empty()) o.subsKey = "off"; }
        else if (a == "--subtitles-user") { if (!next(v)) return false; o.subsUser = trim(v); }
        else if (a == "--no-update-check") o.noUpdateCheck = true;
        else if (a == "--check-update") o.checkUpdate = true;
        else if (a == "--update") o.update = true;
        else if (a == "--yes" || a == "-y") o.yes = true;
        else if (a == "--tmdb-key") { if (!next(v)) return false; o.tmdbKey = trim(v); o.tmdbKeySet = true; }
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

// The id devices remember this server by (its address can change): made once, kept in <data>/server-id.txt.
static std::string loadOrMakeId(const fs::path& file) {
    {
        std::ifstream in(file);
        std::string k;
        if (in && std::getline(in, k)) { k = trim(k); if (k.size() >= 8) return k; }
    }
    const std::string k = randomHex(8);
    if (!k.empty()) { std::ofstream out(file, std::ios::trunc); out << k << "\n"; }
    return k;
}

static std::string machineName() {
#ifdef __ANDROID__
    // Android's host name is just "localhost": the phone's model ("Pixel 7", "SHIELD Android TV") says more.
    char model[PROP_VALUE_MAX] = {};
    if (__system_property_get("ro.product.model", model) > 0 && model[0]) return std::string(model) + " (Termux)";
#endif
    char h[256] = {};
    if (gethostname(h, sizeof h - 1) == 0 && h[0]) return h;
    return "PEK Server";
}

// pek-server --pair: asks the server already running on this machine for a new code (loopback needs no key).
static int askForPairingCode(int port) {
    httplib::Client c("127.0.0.1", port);
    c.set_connection_timeout(3, 0);
    c.set_read_timeout(5, 0);
    auto r = c.Post("/api/pair/new", "", "application/x-www-form-urlencoded");
    if (!r) {
        std::cerr << "PEK Server is not running on port " << port << " (start it first, or pass --port)." << std::endl;
        return 1;
    }
    if (r->status != 200) {
        std::cerr << "The server said HTTP " << r->status << ". Is it an older PEK Server without pairing codes?" << std::endl;
        return 1;
    }
    const std::string& b = r->body;
    const size_t at = b.find("\"code\": \"");
    const std::string code = at == std::string::npos ? std::string() : b.substr(at + 9, 6);
    if (code.size() != 6) { std::cerr << "Unexpected answer: " << b << std::endl; return 1; }
    std::cout << "\nPairing code:  " << pekself::spaced(code) << "\n\n"
              << "In PEK TV open Settings > Library > Connect to a server, pick this server and type the code.\n"
              << "It works for " << pekself::kCodeMinutes << " minutes, for one device.\n" << std::endl;
    return 0;
}

// A password typed at the terminal without showing it (PEK_PASSWORD wins, for scripts and Docker).
static std::string readSecret(const char* prompt) {
    std::cout << prompt << std::flush;
    termios old{};
    const bool tty = isatty(STDIN_FILENO) && tcgetattr(STDIN_FILENO, &old) == 0;
    if (tty) { termios t = old; t.c_lflag &= ~static_cast<tcflag_t>(ECHO); tcsetattr(STDIN_FILENO, TCSANOW, &t); }
    std::string s;
    std::getline(std::cin, s);
    if (tty) { tcsetattr(STDIN_FILENO, TCSANOW, &old); std::cout << std::endl; }
    while (!s.empty() && (s.back() == '\r' || s.back() == '\n')) s.pop_back();
    return s;
}
static std::string newPassword() {
    const std::string fromEnv = envOr("PEK_PASSWORD");
    if (!fromEnv.empty()) return fromEnv;
    const std::string a = readSecret("Password (8 or more characters): ");
    const std::string b = readSecret("The same password again: ");
    if (a != b) { std::cerr << "The two passwords are not the same." << std::endl; return {}; }
    return a;
}

/// --add-user / --set-password / --remove-user / --list-users. Returns the exit code.
static int accountCommand(const Options& opt) {
    if (!pekacct::open(opt.dataDir + "/accounts.db")) return 1;
    std::string err;
    if (opt.listUsers) {
        const auto users = pekacct::listUsers();
        if (users.empty()) std::cout << "No accounts yet. Make one:  pek-server --add-user <name>" << std::endl;
        for (const auto& u : users)
            std::cout << "  " << u.username << (u.email.empty() ? "" : "  <" + u.email + ">") << (u.owner ? "  (owner)" : "")
                      << "  - signed in on " << u.sessions << " device(s)" << std::endl;
        return 0;
    }
    if (!opt.addUser.empty()) {
        const std::string pw = newPassword();
        if (pw.empty()) return 1;
        err = pekacct::addUser(opt.addUser, pw, opt.email);
        if (err.empty()) std::cout << "Account " << opt.addUser << " made. In PEK TV: Settings > Account > Sign in." << std::endl;
    } else if (!opt.setPassword.empty()) {
        const std::string pw = newPassword();
        if (pw.empty()) return 1;
        err = pekacct::setPassword(opt.setPassword, pw);
        if (err.empty()) std::cout << "New password set for " << opt.setPassword << "; it was signed out on every device." << std::endl;
    } else if (!opt.signOut.empty()) {
        err = pekacct::signOutUser(opt.signOut);
        if (err.empty()) std::cout << opt.signOut << " is signed out on every device; PEK TV tells them so. They can sign in again." << std::endl;
    } else if (!opt.removeUser.empty()) {
        err = pekacct::removeUser(opt.removeUser);
        if (err.empty()) std::cout << "Account " << opt.removeUser << " and everything it synced are deleted." << std::endl;
    }
    if (!err.empty()) { std::cerr << err << std::endl; return 1; }
    return 0;
}

/// --check-update / --update. Never runs on its own: the owner asks for it, and --update asks again before changing anything.
static int updateCommand(const Options& opt) {
    const fs::path here = exeDir();
    std::error_code ec;
    if (fs::exists(here / "cacert.pem", ec)) setenv("SSL_CERT_FILE", (here / "cacert.pem").c_str(), 0);
    pekupdate::setCurrent(PEK_SERVER_VERSION);
    bool ok = false;
    const std::string v = pekupdate::checkNow(&ok);
    if (!ok) { std::cerr << "Could not read the newest version from GitHub (no internet, or nothing published yet)." << std::endl; return 1; }
    if (v.empty()) { std::cout << "PEK Server " PEK_SERVER_VERSION " is the newest version." << std::endl; return 0; }
    std::cout << "PEK Server " << v << " is available (this is " PEK_SERVER_VERSION ")." << std::endl;
    if (!opt.update) { std::cout << pekupdate::howTo() << std::endl; return 0; }
    const std::string p = pekupdate::platform();
    if (p == "docker") { std::cout << pekupdate::howTo() << std::endl; return 0; }
    std::string cmd;
#ifdef __ANDROID__
    cmd = "curl -fsSL '" + pekupdate::base() + "/install-termux.sh' | PEK_BASE='" + pekupdate::base() + "' bash";
#else
    const bool service = here == fs::path("/opt/pek-server");
    if (service && geteuid() != 0) { std::cerr << "Run it as root:  sudo /opt/pek-server/pek-server --update" << std::endl; return 1; }
    if (!service && access(here.c_str(), W_OK) != 0) { std::cerr << "This folder cannot be written to: " << here.string() << std::endl; return 1; }
    cmd = "curl -fsSL '" + pekupdate::base() + "/install-linux.sh' | PEK_BASE='" + pekupdate::base() + "' bash" + (service ? std::string() : " -s -- --into '" + here.string() + "'");
#endif
    if (!opt.yes) {
        std::cout << "Update now? Your library, accounts and settings are kept. [y/N] " << std::flush;
        std::string a;
        std::getline(std::cin, a);
        if (a != "y" && a != "Y" && a != "yes") { std::cout << "Nothing was changed." << std::endl; return 0; }
    }
    // exec, not system(): the installer stops the running server by its path, and must not find this process.
    execlp("bash", "bash", "-c", cmd.c_str(), static_cast<char*>(nullptr));
    std::cerr << "Could not start bash: " << std::strerror(errno) << std::endl;
    return 1;
}

static std::string defaultDataDir() {
#ifndef __ANDROID__
    if (geteuid() == 0) return "/var/lib/pek-server";   // Termux (even with su) keeps everything in its home folder
#endif
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
    if (const std::string p = envOr("PEK_PORT"); !p.empty() && opt.port == kDefaultPort) { const int n = atoi(p.c_str()); if (n >= 1 && n <= 65535) opt.port = n; }
    if (const std::string b = envOr("PEK_BIND"); !b.empty() && opt.bind == "0.0.0.0") opt.bind = b;
    if (opt.name.empty()) opt.name = envOr("PEK_NAME", machineName());
    if (opt.pair) return askForPairingCode(opt.port);   // talks to the running server; touches nothing here
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
    if (opt.listUsers || !opt.addUser.empty() || !opt.removeUser.empty() || !opt.setPassword.empty() || !opt.signOut.empty())
        return accountCommand(opt);   // works whether the server is running or not (SQLite keeps them apart)
    if (opt.checkUpdate || opt.update) return updateCommand(opt);   // no log, no server
    if (opt.tmdbKeySet)   // no log, no server: test and save the key
        return pektmdb::command(opt.dataDir, opt.tmdbKey, (exeDir() / "cacert.pem").string(), std::cout, std::cerr);
    if (!opt.subsKey.empty() || !opt.subsUser.empty()) {   // no log, no server: test and save the OpenSubtitles key / login
        if (fs::exists(exeDir() / "cacert.pem")) setenv("SSL_CERT_FILE", (exeDir() / "cacert.pem").c_str(), 0);
        std::string pw;
        if (!opt.subsUser.empty()) { pw = envOr("PEK_PASSWORD"); if (pw.empty()) pw = readSecret("OpenSubtitles password: "); }
        const int rc = peksubs::own::command(opt.dataDir, opt.subsKey, opt.subsUser, pw, std::cout, std::cerr);
        ownerOnly(fs::path(peksubs::own::fileIn(opt.dataDir)));
        return rc;
    }

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
#ifdef __ANDROID__
    else if (!onPath("ffprobe")) std::cout << "[warning] ffprobe not found: the library scan cannot read file details. Run:  pkg install ffmpeg" << std::endl;
#else
    else if (!onPath("ffprobe")) std::cout << "[warning] ffprobe not found (next to pek-server or on PATH): the library scan cannot read file details. Install ffmpeg." << std::endl;
#endif

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
        pekself::Info si;
        si.key = key;
        si.name = opt.name;
        si.id = loadOrMakeId(fs::path(opt.dataDir) / "server-id.txt");
        si.version = PEK_SERVER_VERSION;
        si.port = opt.port;
        pekacct::open(opt.dataDir + "/accounts.db");   // accounts + sync (/v1/...); logs why when it cannot
        pekself::enable(si);   // before PekServer::start: it registers /api/server/info and /api/pair when this is on
    }
    pektmdb::setKey(pektmdb::load(opt.dataDir));
    peksubs::own::set(peksubs::own::load(opt.dataDir));
    pekupdate::setCurrent(PEK_SERVER_VERSION);
    if (!opt.noUpdateCheck) pekupdate::start(PEK_SERVER_VERSION, []() { return g_stop != 0; });   // only looks; never updates   // the owner's own OpenSubtitles key: PEK's shared account is never used here   // the owner's own key, or none: PEK's TMDb proxy is never used here
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
#ifdef __ANDROID__
    // Termux cannot see the phone's shared storage (/storage/emulated/0, /sdcard, SD cards) until termux-setup-storage was run once.
    for (const auto& m : opt.media) {
        if ((m.rfind("/storage/", 0) == 0 || m.rfind("/sdcard", 0) == 0) && access(m.c_str(), R_OK) != 0) {
            std::cerr << "Cannot read " << m << ": run  termux-setup-storage  once and allow access to files, then start again." << std::endl;
            break;
        }
    }
#endif
    if (scanner->getMediaDirs().empty() && isatty(STDIN_FILENO)) {
#ifdef __ANDROID__
        std::cout << "\nNo media folders yet. Type the folder that holds your movies / shows / music\n"
                     "(for example /storage/emulated/0/Movies; run termux-setup-storage first),\n"
                     "or press Enter to add one later with --add-media: " << std::flush;
#else
        std::cout << "\nNo media folders yet. Type the folder that holds your movies / shows / music\n"
                     "(for example /srv/movies), or press Enter to add one later with --add-media: " << std::flush;
#endif
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
    info << "PEK Server " PEK_SERVER_VERSION " (\"" << opt.name << "\") is running.\n\n";
    if (remote) {
        const auto addrs = lanAddresses();
        info << "Connect your devices to one of these addresses:\n";
        if (addrs.empty()) info << "  (no network connection found)\n";
        for (const auto& a : addrs) info << "  http://" << a.second << ":" << port << "    (" << a.first << ")\n";
        if (fs::exists("/.dockerenv", ec)) info << "  Running in Docker: use the address of the machine Docker runs on, not the one above.\n";
#ifdef __ANDROID__
        info << "  Keep this phone on Wi-Fi and plugged in. So Android does not stop the server: run  termux-wake-lock  and turn off\n"
                "  battery optimisation for Termux (Android settings > Apps > Termux > Battery > Unrestricted).\n";
#endif
        pekself::startBeacon([]() { return g_stop != 0; });
        const std::string code = pekself::newCode();
        info << "\nPairing code (for one TV / phone, works " << pekself::kCodeMinutes << " minutes):  " << pekself::spaced(code) << "\n"
             << "  In PEK TV: Settings > Library > Connect to a server. Need another code later? Run  pek-server --pair\n";
        if (pekacct::isOn()) {
            const long long n = pekacct::userCount();
            if (n == 0) info << "\nAccounts: none yet. Make one so people can sign in and sync:  pek-server --add-user <name>\n";
            else info << "\nAccounts: " << n << " (pek-server --list-users). People sign in with them in Settings > Account.\n";
        }
        info << "\nAccess key (typing this instead of a code also works):\n  " << key << "\n"
             << "\nAnyone with this key can use your library - keep it private.\n"
             << "To test from a browser on another device, open  http://<address>:" << port << "/api/movies?token=" << key << "\n";
    } else {
        info << "Local only: http://127.0.0.1:" << port << "  (no other device can connect)\n";
    }
    if (pektmdb::key().empty())
        info << "\nTMDb: no key, so posters and titles come only from your own .nfo files and pictures.\n"
             << "  Get a free key at " << pektmdb::kSignUp << " then run  pek-server --tmdb-key <key>\n";
    else info << "\nTMDb: using your own key.\n";
    if (!peksubs::own::hasKey())
        info << "Subtitles: no OpenSubtitles key, so subtitle search is off. Free key: " << peksubs::own::kSignUp << "  then: pek-server --subtitles-key <key>\n";
    else info << "Subtitles: using your own OpenSubtitles key" << (peksubs::own::get().user.empty() ? "" : " and account") << ".\n";
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
