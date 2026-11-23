// The self-hosted PEK Server's own TMDb key (header-only, like selfhost.h).
//
// The apps (Android, Windows) look titles and posters up through PEK's TMDb proxy (tmdb.pekindustries.com), which holds PEK's key.
// The stand-alone PEK Server (selfhost/linux, selfhost/windows, selfhost/termux) is built with PEK_SELFHOST_BUILD and never uses
// that proxy: it talks to api.themoviedb.org directly with the owner's own free TMDb key. Without one it still works, but titles,
// posters and plots then come only from the owner's own files (.nfo, poster.jpg ...) and the names in the file names.
//
// Where the key comes from (first one wins):
//   TMDB_API_KEY            environment variable (Docker, systemd)
//   <data>/tmdb-key.txt     written by  pek-server --tmdb-key <key>  (or "Set TMDb key.bat" on Windows)
// Both kinds of TMDb key work: the 32-letter "API Key" (v3, sent as ?api_key=) and the long "API Read Access Token"
// (v4, starts with eyJ, sent as Authorization: Bearer).
#ifndef PEK_TMDB_KEY_H
#define PEK_TMDB_KEY_H

#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>

#include "httplib.h"

namespace pektmdb {

inline constexpr const char* kApiHost = "https://api.themoviedb.org";
inline constexpr const char* kImageBase = "https://image.tmdb.org/t/p/";
inline constexpr const char* kSignUp = "https://www.themoviedb.org/settings/api";
inline constexpr const char* kFile = "tmdb-key.txt";

struct State { std::mutex m; std::string key; };
inline State& state() { static State s; return s; }

inline void setKey(const std::string& k) { std::lock_guard<std::mutex> lk(state().m); state().key = k; }
inline std::string key() { std::lock_guard<std::mutex> lk(state().m); return state().key; }

inline std::string trimmed(std::string s) {
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back()))) s.pop_back();
    size_t i = 0;
    while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) ++i;
    return s.substr(i);
}

/// v4 read access token (a JWT, "eyJ..."): sent as a Bearer header. Otherwise a v3 key: sent as ?api_key=.
inline bool isBearer(const std::string& k) { return k.size() > 40; }

/// Looks like a TMDb key at all: 32 hex letters (v3) or a long eyJ... token (v4). Stops typos and pasted junk early.
inline bool plausible(const std::string& k) {
    if (k.size() == 32) {
        for (unsigned char c : k) if (!std::isxdigit(c)) return false;
        return true;
    }
    if (k.size() < 100 || k.size() > 2000 || k.compare(0, 3, "eyJ") != 0) return false;
    for (unsigned char c : k) if (!(std::isalnum(c) || c == '.' || c == '-' || c == '_')) return false;
    return true;
}

/// TMDb path (as the server writes it, e.g. "/search/movie?query=x") -> the path on api.themoviedb.org for this key.
inline std::string apiPath(const std::string& path, const std::string& k) {
    std::string p = "/3" + path;
    if (!isBearer(k)) p += std::string(path.find('?') == std::string::npos ? "?" : "&") + "api_key=" + k;
    return p;
}

inline void authorize(httplib::Client& c, const std::string& k) {
    if (isBearer(k)) c.set_bearer_token_auth(k);
}

inline std::string fileIn(const std::string& dataDir) { return dataDir + "/" + kFile; }

/// TMDB_API_KEY, else <data>/tmdb-key.txt, else "".
inline std::string load(const std::string& dataDir) {
    if (const char* e = std::getenv("TMDB_API_KEY")) { const std::string k = trimmed(e); if (!k.empty()) return k; }
    std::ifstream in(std::filesystem::u8path(fileIn(dataDir)));
    std::string k;
    if (in && std::getline(in, k)) return trimmed(k);
    return {};
}

/// Asks TMDb whether the key works. 0 = works, 1 = TMDb refused it, 2 = TMDb could not be reached.
inline int check(const std::string& k, const std::string& caFile = {}) {
    httplib::Client c(kApiHost);
#ifdef CPPHTTPLIB_OPENSSL_SUPPORT
    std::error_code ec;
    if (!caFile.empty() && std::filesystem::exists(std::filesystem::u8path(caFile), ec)) c.set_ca_cert_path(caFile.c_str());
#endif
    c.set_connection_timeout(8);
    c.set_read_timeout(10);
    authorize(c, k);
    auto r = c.Get(apiPath("/configuration", k).c_str());
    if (!r) return 2;
    if (r->status == 200) return 0;
    if (r->status == 401) return 1;
    return 2;
}

/// pek-server --tmdb-key <key | off>. Returns the exit code.
inline int command(const std::string& dataDir, const std::string& value, const std::string& caFile, std::ostream& out, std::ostream& err) {
    const std::string v = trimmed(value);
    const std::string file = fileIn(dataDir);
    std::error_code ec;
    if (v == "off" || v == "none" || v == "remove") {
        std::filesystem::remove(std::filesystem::u8path(file), ec);
        out << "TMDb key removed. After a restart, titles and posters come only from your own .nfo files and pictures." << std::endl;
        return 0;
    }
    if (!plausible(v)) {
        err << "That does not look like a TMDb key. Use the 32-letter \"API Key\" or the long \"API Read Access Token\" from\n  "
            << kSignUp << std::endl;
        return 1;
    }
    const int ok = check(v, caFile);
    if (ok == 1) { err << "TMDb refused that key. Copy it again from " << kSignUp << std::endl; return 1; }
    {
        std::ofstream o(std::filesystem::u8path(file), std::ios::trunc);
        if (!o) { err << "Could not write " << file << std::endl; return 1; }
        o << v << "\n";
    }
    if (ok == 2) out << "TMDb could not be reached to test the key right now; it was saved anyway." << std::endl;
    else out << "Your TMDb key works and is saved." << std::endl;
    out << "Restart PEK Server to use it." << std::endl;
    return 0;
}

} // namespace pektmdb

#endif
