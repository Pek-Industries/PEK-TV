// PEK Server for Windows: the self-hosted edition. The same C++ server the apps run inside themselves (backend/), as a program
// of its own that keeps your library and streams it to other devices. No window: it prints to the console and to server.log.
//
//   pek-server.exe                       start (first run asks for a media folder)
//   pek-server.exe --add-media D:\Movies add a folder, then start
//   pek-server.exe --pair                ask the running server for a 6-digit code to pair a TV / phone with
//   pek-server.exe --add-user alice      make an account (asks for the password; the first account is the owner)
//   pek-server.exe --help
//
// Remote access is the server's own PEK_BIND / PEK_TOKEN mechanism (backend/server.cpp): every request from another device must carry
// the access key. The key is made once and kept in <data folder>\access-key.txt, so paired devices stay paired across restarts.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <bcrypt.h>
#include <stdio.h>
#include <stdlib.h>
#include <algorithm>
#include <atomic>
#include <chrono>
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

#ifndef PEK_SERVER_VERSION
#define PEK_SERVER_VERSION "dev"
#endif

namespace fs = std::filesystem;

static std::atomic<bool> g_stop{false};
static BOOL WINAPI onCtrl(DWORD) { g_stop = true; return TRUE; }

// ---- text helpers ------------------------------------------------------------------------------------------------------------
static std::string toUtf8(const std::wstring& w) {
    if (w.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    std::string s(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), n, nullptr, nullptr);
    return s;
}
static std::wstring toWide(const std::string& s) {
    if (s.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
    return w;
}
static fs::path pathOf(const std::string& utf8) { return fs::path(toWide(utf8)); }
static std::string trim(std::string s) {
    auto bad = [](char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '"'; };
    while (!s.empty() && bad(s.back())) s.pop_back();
    size_t i = 0;
    while (i < s.size() && bad(s[i])) ++i;
    return s.substr(i);
}

// ---- log: everything the server prints goes to the console AND to <data>\server.log --------------------------------------------
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
    std::vector<unsigned char> b(bytes);
    if (BCryptGenRandom(nullptr, b.data(), static_cast<ULONG>(b.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) return {};
    static const char* hex = "0123456789abcdef";
    std::string out;
    for (unsigned char c : b) { out += hex[c >> 4]; out += hex[c & 15]; }
    return out;
}
static bool goodKey(const std::string& k) {
    if (k.size() < 24) return false;
    for (char c : k) if (!isalnum(static_cast<unsigned char>(c))) return false;
    return true;
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
    std::ofstream out(file, std::ios::trunc);
    out << k << "\n";
    made = true;
    return k;
}

// ---- network helpers ---------------------------------------------------------------------------------------------------------
// Is something already listening on the port (or has Windows reserved it)? Checked with the strictest bind before anything starts.
static bool portTaken(const std::string& bindAddr, int port) {
    SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == INVALID_SOCKET) return false;
    BOOL excl = TRUE;
    setsockopt(sock, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char*>(&excl), sizeof excl);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(static_cast<u_short>(port));
    if (inet_pton(AF_INET, bindAddr.c_str(), &a.sin_addr) != 1) a.sin_addr.s_addr = htonl(INADDR_ANY);
    bool taken = false;
    if (bind(sock, reinterpret_cast<sockaddr*>(&a), sizeof a) == SOCKET_ERROR) {
        const int e = WSAGetLastError();
        taken = (e == WSAEADDRINUSE || e == WSAEACCES);
    }
    closesocket(sock);
    return taken;
}

static bool waitForPort(int port, int timeoutMs) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (std::chrono::steady_clock::now() < end) {
        SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s != INVALID_SOCKET) {
            sockaddr_in a{};
            a.sin_family = AF_INET;
            a.sin_port = htons(static_cast<u_short>(port));
            inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
            const bool ok = connect(s, reinterpret_cast<sockaddr*>(&a), sizeof a) == 0;
            closesocket(s);
            if (ok) return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }
    return false;
}

// This PC's usable IPv4 addresses on the home network (adapter up, not loopback, not 169.254.x.x self-assigned).
static std::vector<std::pair<std::string, std::string>> lanAddresses() {   // {adapter name, address}
    std::vector<std::pair<std::string, std::string>> out;
    ULONG size = 16 * 1024;
    std::vector<unsigned char> buf(size);
    auto* list = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buf.data());
    const ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
    ULONG rc = GetAdaptersAddresses(AF_INET, flags, nullptr, list, &size);
    if (rc == ERROR_BUFFER_OVERFLOW) {
        buf.resize(size);
        list = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buf.data());
        rc = GetAdaptersAddresses(AF_INET, flags, nullptr, list, &size);
    }
    if (rc != NO_ERROR) return out;
    for (auto* a = list; a; a = a->Next) {
        if (a->OperStatus != IfOperStatusUp || a->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
        for (auto* u = a->FirstUnicastAddress; u; u = u->Next) {
            if (!u->Address.lpSockaddr || u->Address.lpSockaddr->sa_family != AF_INET) continue;
            char ip[INET_ADDRSTRLEN] = {};
            inet_ntop(AF_INET, &reinterpret_cast<sockaddr_in*>(u->Address.lpSockaddr)->sin_addr, ip, sizeof ip);
            const std::string s = ip;
            if (s.rfind("127.", 0) == 0 || s.rfind("169.254.", 0) == 0) continue;
            out.emplace_back(a->FriendlyName ? toUtf8(a->FriendlyName) : std::string("network"), s);
        }
    }
    return out;
}

// One line typed at the console, as UTF-8 (ReadConsoleW: file names with accents survive).
static bool stdinIsConsole() {
    DWORD m = 0;
    return GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), &m) != 0;
}
static std::string readLine() {
    wchar_t buf[2048];
    DWORD n = 0;
    if (!ReadConsoleW(GetStdHandle(STD_INPUT_HANDLE), buf, 2047, &n, nullptr)) return {};
    return trim(toUtf8(std::wstring(buf, n)));
}

// ---- command line ------------------------------------------------------------------------------------------------------------
struct Options {
    std::string dataDir;
    int port = 8080;
    std::string bind = "0.0.0.0";
    std::string name;
    std::vector<std::string> media;
    bool newKey = false, noScan = false, hideConsole = false, pair = false, help = false, version = false;
    std::string addUser, removeUser, setPassword, email;   // account commands (run, then exit)
    bool listUsers = false;
    int rescanMinutes = 60;
};

static void usage() {
    std::cout <<
        "PEK Server " PEK_SERVER_VERSION " - your own PEK TV server on this PC\n\n"
        "  pek-server.exe [options]\n\n"
        "  --add-media <folder>   add a movie / show / music folder (can be repeated)\n"
        "  --data <folder>        where the server keeps its library and settings\n"
        "                         (default: %LOCALAPPDATA%\\PEK Server)\n"
        "  --port <number>        port to listen on (default 8080)\n"
        "  --local-only           answer this PC only (no other device can connect)\n"
        "  --new-key              make a new access key (every paired device must pair again)\n"
        "  --pair                 get a 6-digit code from the running server to pair a TV / phone (works 10 minutes)\n"
        "  --name <text>          the name devices show for this server (default: this PC's name)\n"
        "\n  Accounts (people sign in with these; history, resume points and favorites sync between their devices):\n"
        "  --add-user <name>      make an account; asks for the password. The first one is the owner\n"
        "  --email <address>      with --add-user: lets them sign in with their email too\n"
        "  --set-password <name>  give an account a new password (signs it out everywhere)\n"
        "  --remove-user <name>   delete an account and everything it synced\n"
        "  --list-users           show the accounts\n\n"
        "  --rescan-minutes <n>   look for new files every n minutes, 0 = never (default 60)\n"
        "  --no-scan              do not scan at start-up\n"
        "  --hide-console         close the console window and run in the background\n"
        "  --version, --help\n";
}

static bool parseArgs(int argc, wchar_t** argv, Options& o) {
    for (int i = 1; i < argc; ++i) {
        const std::string a = toUtf8(argv[i]);
        auto next = [&](std::string& v) {
            if (i + 1 >= argc) { std::cerr << "Missing value after " << a << std::endl; return false; }
            v = toUtf8(argv[++i]);
            return true;
        };
        std::string v;
        if (a == "--help" || a == "-h" || a == "/?") o.help = true;
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
        else if (a == "--pair") o.pair = true;
        else if (a == "--name") { if (!next(v)) return false; o.name = trim(v); }
        else if (a == "--add-user") { if (!next(v)) return false; o.addUser = trim(v); }
        else if (a == "--remove-user") { if (!next(v)) return false; o.removeUser = trim(v); }
        else if (a == "--set-password") { if (!next(v)) return false; o.setPassword = trim(v); }
        else if (a == "--email") { if (!next(v)) return false; o.email = trim(v); }
        else if (a == "--list-users") o.listUsers = true;
        else if (a == "--no-scan") o.noScan = true;
        else if (a == "--hide-console") o.hideConsole = true;
        else if (a == "--rescan-minutes") { if (!next(v)) return false; o.rescanMinutes = (std::max)(0, atoi(v.c_str())); }
        else { std::cerr << "Unknown option: " << a << "  (try --help)" << std::endl; return false; }
    }
    return true;
}

static fs::path exeDir() {
    wchar_t p[MAX_PATH * 2] = {};
    GetModuleFileNameW(nullptr, p, static_cast<DWORD>(sizeof p / sizeof p[0]));
    return fs::path(p).parent_path();
}

// The id devices remember this server by (its address can change): made once, kept in <data>\server-id.txt.
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
    wchar_t n[MAX_COMPUTERNAME_LENGTH + 1] = {};
    DWORD len = MAX_COMPUTERNAME_LENGTH + 1;
    if (GetComputerNameW(n, &len) && len > 0) return toUtf8(std::wstring(n, len));
    return "PEK Server";
}

// pek-server.exe --pair: asks the server already running on this PC for a new code (loopback needs no key).
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
              << "In PEK TV open Settings > Library > Connect to a server, pick this PC and type the code.\n"
              << "It works for " << pekself::kCodeMinutes << " minutes, for one device.\n" << std::endl;
    return 0;
}

// A password typed at the console without showing it.
static std::string readSecret(const char* prompt) {
    std::cout << prompt << std::flush;
    HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
    DWORD mode = 0;
    const bool console = GetConsoleMode(in, &mode) != 0;
    if (console) SetConsoleMode(in, mode & ~static_cast<DWORD>(ENABLE_ECHO_INPUT));
    std::string s;
    if (console) {
        // Read as typed (readLine() trims spaces and quotes, which is right for folders but would change a password).
        wchar_t buf[512];
        DWORD n = 0;
        if (ReadConsoleW(in, buf, 511, &n, nullptr)) s = toUtf8(std::wstring(buf, n));
        SetConsoleMode(in, mode);
        std::cout << std::endl;
    } else {
        std::getline(std::cin, s);
    }
    while (!s.empty() && (s.back() == '\r' || s.back() == '\n')) s.pop_back();
    return s;
}
static std::string newPassword() {
    if (const char* e = std::getenv("PEK_PASSWORD"); e && *e) return e;
    const std::string a = readSecret("Password (8 or more characters): ");
    const std::string b = readSecret("The same password again: ");
    if (a != b) { std::cerr << "The two passwords are not the same." << std::endl; return {}; }
    return a;
}

/// --add-user / --set-password / --remove-user / --list-users. Returns the exit code.
static int accountCommand(const Options& opt) {
    if (!pekacct::open(toUtf8(pathOf(opt.dataDir + "/accounts.db").wstring()))) return 1;
    std::string err;
    if (opt.listUsers) {
        const auto users = pekacct::listUsers();
        if (users.empty()) std::cout << "No accounts yet. Make one:  pek-server.exe --add-user <name>   (or \"Add a user.bat\")" << std::endl;
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
    } else if (!opt.removeUser.empty()) {
        err = pekacct::removeUser(opt.removeUser);
        if (err.empty()) std::cout << "Account " << opt.removeUser << " and everything it synced are deleted." << std::endl;
    }
    if (!err.empty()) { std::cerr << err << std::endl; return 1; }
    return 0;
}

static std::string defaultDataDir() {
    const wchar_t* la = _wgetenv(L"LOCALAPPDATA");
    if (la && *la) return toUtf8((fs::path(la) / L"PEK Server").wstring());
    return toUtf8((exeDir() / L"data").wstring());
}

int wmain(int argc, wchar_t** argv) {
    SetConsoleOutputCP(CP_UTF8);
    Options opt;
    if (!parseArgs(argc, argv, opt)) return 2;
    if (opt.help) { usage(); return 0; }
    if (opt.version) { std::cout << "PEK Server " << PEK_SERVER_VERSION << std::endl; return 0; }

    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    if (opt.pair) return askForPairingCode(opt.port);   // talks to the running server; touches nothing here
    if (opt.name.empty()) opt.name = machineName();

    // ---- data folder + log ---------------------------------------------------------------------------------------------------
    if (opt.dataDir.empty()) opt.dataDir = defaultDataDir();
    std::error_code ec;
    fs::create_directories(pathOf(opt.dataDir), ec);
    fs::create_directories(pathOf(opt.dataDir + "/plugins"), ec);
    fs::create_directories(pathOf(opt.dataDir + "/skins"), ec);
    if (ec) { std::cerr << "Cannot create the data folder " << opt.dataDir << ": " << ec.message() << std::endl; return 1; }

    if (opt.listUsers || !opt.addUser.empty() || !opt.removeUser.empty() || !opt.setPassword.empty())
        return accountCommand(opt);   // works whether the server is running or not (SQLite keeps them apart)

    static std::ofstream logFile;
    const fs::path logPath = pathOf(opt.dataDir + "/server.log");
    if (fs::exists(logPath, ec) && fs::file_size(logPath, ec) > 5u * 1024 * 1024)
        fs::rename(logPath, pathOf(opt.dataDir + "/server.old.log"), ec);
    logFile.open(logPath, std::ios::app);
    static TeeBuf teeOut(std::cout.rdbuf(), logFile);
    static TeeBuf teeErr(std::cerr.rdbuf(), logFile);
    std::cout.rdbuf(&teeOut);
    std::cerr.rdbuf(&teeErr);

    std::cout << "==== PEK Server " << PEK_SERVER_VERSION << " starting ====" << std::endl;
    if (GetACP() != 65001)
        std::cout << "[warning] This build runs without the UTF-8 manifest: folders or files with accented letters may not be found." << std::endl;

    // ---- environment the server reads ----------------------------------------------------------------------------------------
    const fs::path here = exeDir();
    if (fs::exists(here / L"cacert.pem", ec)) _putenv_s("SSL_CERT_FILE", toUtf8((here / L"cacert.pem").wstring()).c_str());   // OpenSSL does not read the Windows certificate store
    if (fs::exists(here / L"ffprobe.exe", ec)) _putenv_s("PEK_FFPROBE", toUtf8((here / L"ffprobe.exe").wstring()).c_str());
    else std::cout << "[warning] ffprobe.exe not found next to pek-server.exe: the library scan will look for it on PATH." << std::endl;

    const bool remote = opt.bind != "127.0.0.1";
    std::string key;
    if (remote) {
        bool made = false;
        key = loadOrMakeKey(pathOf(opt.dataDir + "/access-key.txt"), opt.newKey, made);
        if (key.empty()) { std::cerr << "Could not make an access key." << std::endl; return 1; }
        if (made) std::cout << "A new access key was made." << std::endl;
        _putenv_s("PEK_TOKEN", key.c_str());
        pekself::Info si;
        si.key = key;
        si.name = opt.name;
        si.id = loadOrMakeId(pathOf(opt.dataDir + "/server-id.txt"));
        si.version = PEK_SERVER_VERSION;
        si.port = opt.port;
        pekacct::open(toUtf8(pathOf(opt.dataDir + "/accounts.db").wstring()));   // accounts + sync (/v1/...); logs why when it cannot
        pekself::enable(si);   // before PekServer::start: it registers /api/server/info and /api/pair when this is on
    }
    _putenv_s("PEK_BIND", opt.bind.c_str());

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
        if (scanner->addMediaDir(m)) std::cout << "Added media folder: " << m << std::endl;
        else std::cerr << "Not a folder, skipped: " << m << std::endl;
    }
    if (scanner->getMediaDirs().empty() && stdinIsConsole() && !opt.hideConsole) {
        std::cout << "\nNo media folders yet. Type the folder that holds your movies / shows / music\n"
                     "(for example D:\\Movies), or press Enter to add one later with --add-media: " << std::flush;
        const std::string m = readLine();
        if (!m.empty()) {
            if (scanner->addMediaDir(m)) std::cout << "Added media folder: " << m << std::endl;
            else std::cerr << "That is not a folder: " << m << std::endl;
        }
    }
    std::cout << "Media folders: " << scanner->getMediaDirs().size() << std::endl;

    SetConsoleCtrlHandler(onCtrl, TRUE);

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
        std::cerr << "The server did not come up. See " << opt.dataDir << "\\server.log" << std::endl;
        return 1;
    }

    // ---- how to connect ------------------------------------------------------------------------------------------------------
    std::ostringstream info;
    info << "PEK Server " PEK_SERVER_VERSION " (\"" << opt.name << "\") is running.\n\n";
    if (remote) {
        const auto addrs = lanAddresses();
        info << "Connect your devices to one of these addresses:\n";
        if (addrs.empty()) info << "  (no network connection found - connect this PC to your network)\n";
        for (const auto& a : addrs) info << "  http://" << a.second << ":" << port << "    (" << a.first << ")\n";
        pekself::startBeacon([]() { return g_stop.load(); });
        const std::string code = pekself::newCode();
        info << "\nPairing code (for one TV / phone, works " << pekself::kCodeMinutes << " minutes):  " << pekself::spaced(code) << "\n"
             << "  In PEK TV: Settings > Library > Connect to a server. Need another code later? Double-click \"Pair a device.bat\".\n";
        if (pekacct::isOn()) {
            const long long n = pekacct::userCount();
            if (n == 0) info << "\nAccounts: none yet. Double-click \"Add a user.bat\" so people can sign in and sync.\n";
            else info << "\nAccounts: " << n << " (pek-server.exe --list-users). People sign in with them in Settings > Account.\n";
        }
        info << "\nAccess key (typing this instead of a code also works):\n  " << key << "\n"
             << "\nAnyone with this key can use your library - keep it private.\n"
             << "To test from a browser on another device, open  http://<address>:" << port << "/api/movies?token=" << key << "\n"
             << "The first time, Windows may ask to allow network access: choose \"Private networks\".\n";
    } else {
        info << "Local only: http://127.0.0.1:" << port << "  (no other device can connect)\n";
    }
    info << "\nData folder: " << opt.dataDir << "\nLog:         " << opt.dataDir << "\\server.log\n";
    std::cout << "\n" << info.str() << std::endl;
    { std::ofstream p(pathOf(opt.dataDir + "/pairing.txt"), std::ios::trunc); p << info.str(); }

    if (opt.hideConsole) FreeConsole();
    else std::cout << "Press Ctrl+C (or close this window) to stop the server.\n" << std::endl;

    while (!g_stop) std::this_thread::sleep_for(std::chrono::milliseconds(500));
    std::cout << "PEK Server stopped." << std::endl;
    logFile.flush();
    ExitProcess(0);   // the server and scan threads are detached: end the process instead of unwinding under them
    return 0;
}
