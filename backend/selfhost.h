// Self-hosted PEK Server: what a new device needs to find the server and pair with it (header-only, like trailer.h).
//
// Only the stand-alone server (selfhost/linux, selfhost/windows) turns this on with pekself::enable(). In the apps it stays off:
// the routes below are not registered and nothing changes.
//
//   GET  /api/server/info   no key needed. Who this is: {"app":"pek-server","name","id","version","pairing":bool,"tmdb":bool,"subtitles":bool,
//                           "platform":"windows|linux|termux|docker","update":"<newer version>" or ""}. The app's
//                           Connect screen calls it to check an address really is a PEK Server before asking for a code.
//   POST /api/pair          no key needed. Form field code=<6 digits>. Right code: {"ok":true,"key":"<access key>",...}, which the
//                           app keeps and sends as X-Pek-Token from then on. Wrong code: 403. A code works for 10 minutes and dies
//                           after 5 wrong tries, so it cannot be guessed (5 tries in a million per code).
//   /v1/...                 accounts (username + password) and the household sync, see accounts.h.
//   POST /api/pair/new      a new code. Only from the server's own machine (pek-server --pair) or from a device that already
//                           has the key (the app's "Pair another device"): the pre-routing handler in server.cpp asks for the key
//                           from every other address.
#ifndef PEK_SELFHOST_H
#define PEK_SELFHOST_H

#include <chrono>
#include <cstdio>
#include <iostream>
#include <mutex>
#include <random>
#include <string>

#include "httplib.h"
#include "accounts.h"   // username + password accounts and sync (self-hosted only)
#include "tmdb_key.h"   // the owner's own TMDb key
#include "server_update.h"   // "a newer PEK Server is out" (never updates by itself)

namespace pekself {

struct Info {
    std::string key;       // the access key (PEK_TOKEN)
    std::string name;      // shown in the app: the machine's name unless PEK_NAME / --name says otherwise
    std::string id;        // stable random id kept in the data folder: the app recognises the server when its address changes
    std::string version;
    int port = 8080;
};

struct State {
    std::mutex m;
    bool enabled = false;
    Info info;
    std::string code;                                  // "" = no code open
    std::chrono::steady_clock::time_point expires{};
    int fails = 0;
};

inline State& state() {
    static State s;
    return s;
}

inline constexpr int kCodeMinutes = 10;
inline constexpr int kMaxFails = 5;

inline void enable(const Info& info) {
    State& s = state();
    std::lock_guard<std::mutex> lk(s.m);
    s.enabled = true;
    s.info = info;
}

inline bool enabled() {
    State& s = state();
    std::lock_guard<std::mutex> lk(s.m);
    return s.enabled;
}

inline Info info() {
    State& s = state();
    std::lock_guard<std::mutex> lk(s.m);
    return s.info;
}

/// Opens a new pairing code (replacing any open one) and returns it as 6 digits.
inline std::string newCode() {
    std::random_device rd;
    std::uniform_int_distribution<int> d(0, 999999);
    char buf[8];
    std::snprintf(buf, sizeof buf, "%06d", d(rd));
    State& s = state();
    std::lock_guard<std::mutex> lk(s.m);
    s.code = buf;
    s.fails = 0;
    s.expires = std::chrono::steady_clock::now() + std::chrono::minutes(kCodeMinutes);
    return s.code;
}

inline bool codeOpen(State& s) {   // call with s.m held
    if (s.code.empty()) return false;
    if (std::chrono::steady_clock::now() >= s.expires) { s.code.clear(); return false; }
    return true;
}

/// "123 456" for people to read.
inline std::string spaced(const std::string& code) {
    return code.size() == 6 ? code.substr(0, 3) + " " + code.substr(3) : code;
}

/// The routes that answer without the access key (the pre-routing handler in server.cpp lets these through).
inline bool isOpenRoute(const httplib::Request& req) {
    if (!enabled()) return false;
    return (req.method == "GET" && req.path == "/api/server/info") || (req.method == "POST" && req.path == "/api/pair") ||
           pekacct::isOpenRoute(req);
}

inline std::string esc(const std::string& v) {
    std::string o;
    for (unsigned char c : v) {
        if (c == '"' || c == '\\') { o += '\\'; o += static_cast<char>(c); }
        else if (c < 0x20) { char b[8]; std::snprintf(b, sizeof b, "\\u%04x", c); o += b; }
        else o += static_cast<char>(c);
    }
    return o;
}

inline std::string infoJson() {
    State& s = state();
    std::lock_guard<std::mutex> lk(s.m);
    return std::string("{\"app\": \"pek-server\", \"name\": \"") + esc(s.info.name) + "\", \"id\": \"" + esc(s.info.id) +
           "\", \"version\": \"" + esc(s.info.version) + "\", \"port\": " + std::to_string(s.info.port) +
           ", \"pairing\": " + (codeOpen(s) ? "true" : "false") +
           ", \"tmdb\": " + (pektmdb::key().empty() ? "false" : "true") +
           ", \"platform\": \"" + pekupdate::platform() + "\", \"update\": \"" + pekupdate::available() + "\"" +
#if defined(CPPHTTPLIB_OPENSSL_SUPPORT) && defined(PEK_SELFHOST_BUILD)
           ", \"subtitles\": " + (peksubs::own::hasKey() ? "true" : "false") +
#endif
           ", \"accounts\": " + (pekacct::userCount() > 0 ? "true" : "false") + "}";
}

inline void registerRoutes(httplib::Server& svr) {
    if (!enabled()) return;
    pekacct::registerRoutes(svr, info().key);   // /v1/...: accounts and sync, when pekacct::open() was called (accounts.h)

    svr.Get("/api/server/info", [](const httplib::Request&, httplib::Response& res) {
        res.set_content(infoJson(), "application/json");
    });

    svr.Post("/api/pair", [](const httplib::Request& req, httplib::Response& res) {
        std::string code = req.has_param("code") ? req.get_param_value("code") : std::string();
        std::string digits;
        for (char c : code) if (c >= '0' && c <= '9') digits += c;   // "123 456" and "123-456" are fine
        State& s = state();
        std::lock_guard<std::mutex> lk(s.m);
        if (!codeOpen(s)) {
            res.status = 410;
            res.set_content("{\"ok\": false, \"error\": \"No pairing code is open. Make a new one on the server (pek-server --pair).\"}", "application/json");
            return;
        }
        // Compare every digit (no early exit), like constantTimeEquals in server.cpp.
        unsigned diff = digits.size() == s.code.size() ? 0u : 1u;
        for (size_t i = 0; i < s.code.size(); ++i) diff |= static_cast<unsigned>((i < digits.size() ? digits[i] : 0) ^ s.code[i]);
        if (diff != 0) {
            if (++s.fails >= kMaxFails) {
                s.code.clear();
                res.status = 410;
                res.set_content("{\"ok\": false, \"error\": \"Too many wrong codes. Make a new one on the server.\"}", "application/json");
            } else {
                res.status = 403;
                res.set_content("{\"ok\": false, \"error\": \"That code is not right.\"}", "application/json");
            }
            return;
        }
        s.code.clear();   // one code, one device
        std::cout << "[pairing] a device paired from " << req.remote_addr << std::endl;
        res.set_content(std::string("{\"ok\": true, \"key\": \"") + esc(s.info.key) + "\", \"name\": \"" + esc(s.info.name) +
                            "\", \"id\": \"" + esc(s.info.id) + "\"}",
                        "application/json");
    });

    svr.Post("/api/pair/new", [](const httplib::Request& req, httplib::Response& res) {
        const std::string code = newCode();
        std::cout << "[pairing] new pairing code " << spaced(code) << " (asked from " << req.remote_addr << ", works for "
                  << kCodeMinutes << " minutes)" << std::endl;
        res.set_content("{\"ok\": true, \"code\": \"" + code + "\", \"minutes\": " + std::to_string(kCodeMinutes) + "}", "application/json");
    });
}

}  // namespace pekself

#endif
