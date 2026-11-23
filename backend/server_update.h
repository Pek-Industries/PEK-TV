// Update check for the self-hosted PEK Server (header-only, like selfhost.h). It never updates by itself.
//
// Once a few minutes after start-up and then twice a day, the server reads one small text file from the server-latest release
// (server-version-<platform>.txt, written by the build workflows when they publish) and remembers whether a newer version is out.
// That is all: nothing is downloaded or replaced. The owner sees it in the start-up message / log and in PEK TV
// (/api/server/info answers "update":"<version>"), and updates when they choose:
//   Windows        double-click "Update PEK Server.bat"
//   Linux          sudo pek-server --update     (runs install-linux.sh from server-latest: download, checksum, install, restart)
//   Termux         pek-server --update          (runs install-termux.sh from server-latest)
//   Docker         rebuild / pull the image
// Turn the check off with --no-update-check or PEK_NO_UPDATE_CHECK=1. PEK_UPDATE_BASE points it at a mirror.
#ifndef PEK_SERVER_UPDATE_H
#define PEK_SERVER_UPDATE_H

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <functional>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "httplib.h"

namespace pekupdate {

inline constexpr const char* kRepo = "Pek-Industries/PEK-TV";

inline std::string base() {
    if (const char* e = std::getenv("PEK_UPDATE_BASE"); e && *e) return e;
    return std::string("https://github.com/") + kRepo + "/releases/download/server-latest";
}

/// "windows", "termux", "docker" or "linux": which build this is, and so how it is updated.
inline std::string platform() {
#if defined(_WIN32)
    return "windows";
#elif defined(__ANDROID__)
    return "termux";
#else
    std::error_code ec;
    if (std::filesystem::exists("/.dockerenv", ec)) return "docker";
    return "linux";
#endif
}

/// Which release file says the newest version for this build (Docker images are built from the Linux sources).
inline std::string versionFile() {
    const std::string p = platform();
    return "server-version-" + std::string(p == "docker" ? "linux" : p) + ".txt";
}

inline std::vector<long> parts(const std::string& v) {
    std::vector<long> out;
    std::stringstream ss(v);
    std::string x;
    while (std::getline(ss, x, '.')) {
        if (x.empty() || x.find_first_not_of("0123456789") != std::string::npos) return {};
        out.push_back(std::atol(x.c_str()));
    }
    return out;
}

/// a > b, for plain "2.2.10"-style versions. Anything else ("dev", empty) is never newer.
inline bool newer(const std::string& a, const std::string& b) {
    auto x = parts(a), y = parts(b);
    if (x.empty() || y.empty()) return false;
    while (x.size() < y.size()) x.push_back(0);
    while (y.size() < x.size()) y.push_back(0);
    return x > y;
}

struct State {
    std::mutex m;
    std::string current, latest;   // latest = "" until a check worked
    long long checkedAt = 0;       // unix seconds
    std::atomic<bool> started{false};
};
inline State& state() { static State s; return s; }

inline long long nowS() {
    return std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();
}

/// Asks the release for the newest version. "" when it cannot be read.
inline std::string fetchLatest() {
    std::string b = base();
    const size_t scheme = b.find("://");
    if (scheme == std::string::npos) return {};
    const size_t slash = b.find('/', scheme + 3);
    const std::string host = slash == std::string::npos ? b : b.substr(0, slash);
    const std::string path = (slash == std::string::npos ? std::string() : b.substr(slash)) + "/" + versionFile();
    httplib::Client c(host);
#ifdef CPPHTTPLIB_OPENSSL_SUPPORT
    const char* f = std::getenv("SSL_CERT_FILE");
    std::error_code ec;
    if (f && *f && std::filesystem::exists(std::filesystem::u8path(f), ec)) c.set_ca_cert_path(f);
#endif
    c.set_follow_location(true);   // GitHub answers with a redirect to its file host
    c.set_connection_timeout(10);
    c.set_read_timeout(15);
    auto r = c.Get(path, httplib::Headers{{"User-Agent", "PEK Server update check"}});
    if (!r || r->status != 200 || r->body.size() > 64) return {};
    std::string v = r->body;
    while (!v.empty() && (v.back() == '\n' || v.back() == '\r' || v.back() == ' ')) v.pop_back();
    return parts(v).empty() ? std::string() : v;
}

/// Checks now. Returns the newer version, or "" when this one is the newest (or the check failed: then `ok` is false).
inline std::string checkNow(bool* ok = nullptr) {
    const std::string latest = fetchLatest();
    if (ok) *ok = !latest.empty();
    State& s = state();
    std::lock_guard<std::mutex> lk(s.m);
    if (!latest.empty()) { s.latest = latest; s.checkedAt = nowS(); }
    return newer(s.latest, s.current) ? s.latest : std::string();
}

inline void setCurrent(const std::string& v) { std::lock_guard<std::mutex> lk(state().m); state().current = v; }

/// The newer version the last check found, or "".
inline std::string available() {
    State& s = state();
    std::lock_guard<std::mutex> lk(s.m);
    return newer(s.latest, s.current) ? s.latest : std::string();
}

inline bool disabledByEnv() {
    const char* e = std::getenv("PEK_NO_UPDATE_CHECK");
    return e && *e && std::string(e) != "0";
}

/// One sentence: how to update this build.
inline std::string howTo() {
    const std::string p = platform();
    if (p == "windows") return "Double-click \"Update PEK Server.bat\" in the PEK Server folder.";
    if (p == "termux") return "In Termux run:  pek-server --update";
    if (p == "docker") return "Rebuild the image (docker compose build --pull && docker compose up -d) or pull the new one.";
    return "Run  pek-server --update  (the service in /opt/pek-server: sudo /opt/pek-server/pek-server --update).";
}

/// Background check: a few minutes after start-up, then every 12 hours. Only ever reads the version file.
inline void start(const std::string& current, std::function<bool()> stopping) {
    setCurrent(current);
    if (parts(current).empty() || disabledByEnv() || state().started.exchange(true)) return;   // dev builds: nothing to compare
    std::thread([stopping, current]() {
        auto wait = [&](int seconds) {
            for (int i = 0; i < seconds && !stopping(); ++i) std::this_thread::sleep_for(std::chrono::seconds(1));
            return !stopping();
        };
        if (!wait(120)) return;
        std::string told;
        for (;;) {
            const std::string v = checkNow();
            if (!v.empty() && v != told) {
                told = v;
                std::cout << "[PEK Server] PEK Server " << v << " is available (this is " << current << "). Nothing changes until you update: "
                          << howTo() << std::endl;
            }
            if (!wait(12 * 3600)) return;
        }
    }).detach();
}

} // namespace pekupdate

#endif
