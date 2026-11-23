// Self-hosted PEK Server: accounts (username + password) and the household sync that PEK Cloud does for everyone else.
// Header-only, like selfhost.h. Off in the apps: only the stand-alone server calls pekacct::open().
//
// The server answers the same /v1 calls the app sends to PEK Cloud (flutter_ui/lib/src/cloud.dart), so the app's sign-in, profiles
// and sync code works unchanged against it:
//   POST /v1/auth/login     {email: <username or email>, password}  -> {ok, token, username, email, plan, entitled, key}
//                           Open (no access key needed): a device that is not paired yet can sign in instead of typing a pairing
//                           code, and gets the access key with its session. 10 wrong passwords from one address = 15 minutes' wait.
//   POST /v1/auth/logout    ends this session                     POST /v1/auth/confirm  {password}: is it right?
//   GET  /v1/me             who is signed in, plan "self-hosted" (everything included)
//   POST /v1/profiles/sync  {profiles:[...]} -> every profile of the account (newest change wins per profile)
//   POST /v1/sync           {profile, since, history, progress, favorites, settings, skins, ratings}
//                           -> what changed since the cursor, 2000 items a page. Last writer wins per item (by "updated").
//   DELETE /v1/account      deletes the account and its data (not the server owner's account)
//   any other /v1 route     404 not_on_server (plugin backup, Discord, news ... belong to PEK Cloud)
// Everything except login needs the access key (X-Pek-Token, checked by server.cpp) AND "Authorization: Bearer <session>".
// A session the owner ended answers 401 with why, so the app can tell the person: "account_removed" (--remove-user),
// "password_changed" (--set-password) or "signed_out_by_owner" (--sign-out). Any other unknown session: "bad_session".
//
// Accounts are made on the server: pek-server --add-user <name> (the first one is the owner). The data lives in <data>/accounts.db.
// Unlike the library database it is never thrown away when it cannot be read: the server refuses to start accounts instead.
#ifndef PEK_ACCOUNTS_H
#define PEK_ACCOUNTS_H

#include <sqlite3.h>
#include <openssl/evp.h>
#include <openssl/rand.h>

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <functional>
#include <iostream>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "httplib.h"
#include "subtitles.h"   // peksubs::J / parseJson / jesc: the small JSON reader the server already has

namespace pekacct {

using peksubs::J;

// ---------------------------------------------------------------- small helpers

inline long long nowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
}

inline std::string hex(const unsigned char* p, size_t n) {
    static const char* d = "0123456789abcdef";
    std::string o;
    o.reserve(n * 2);
    for (size_t i = 0; i < n; ++i) { o += d[p[i] >> 4]; o += d[p[i] & 15]; }
    return o;
}

inline std::string randomHex(size_t bytes) {
    std::vector<unsigned char> b(bytes);
    if (RAND_bytes(b.data(), static_cast<int>(b.size())) != 1) return {};
    return hex(b.data(), b.size());
}

inline std::string sha256Hex(const std::string& s) {
    unsigned char out[EVP_MAX_MD_SIZE];
    unsigned int len = 0;
    if (EVP_Digest(s.data(), s.size(), out, &len, EVP_sha256(), nullptr) != 1) return {};
    return hex(out, len);
}

inline constexpr int kIterations = 210000;   // PBKDF2-HMAC-SHA256, OWASP's 2023 figure

inline std::string hashPassword(const std::string& password, const std::string& saltHex, int iterations) {
    unsigned char out[32];
    if (PKCS5_PBKDF2_HMAC(password.data(), static_cast<int>(password.size()), reinterpret_cast<const unsigned char*>(saltHex.data()),
                          static_cast<int>(saltHex.size()), iterations, EVP_sha256(), sizeof out, out) != 1)
        return {};
    return hex(out, sizeof out);
}

inline bool sameText(const std::string& a, const std::string& b) {   // no early exit
    if (a.size() != b.size()) return false;
    unsigned char d = 0;
    for (size_t i = 0; i < a.size(); ++i) d |= static_cast<unsigned char>(a[i] ^ b[i]);
    return d == 0;
}

/// 3 to 32 letters, digits, dot, dash or underscore.
inline bool validUsername(const std::string& u) {
    if (u.size() < 3 || u.size() > 32) return false;
    for (unsigned char c : u) if (!(std::isalnum(c) || c == '.' || c == '-' || c == '_')) return false;
    return true;
}
inline bool validPassword(const std::string& p) { return p.size() >= 8 && p.size() <= 200; }

inline std::string lower(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

/// A JSON value back to text (the sync store keeps each item's "data" as it came, re-serialized).
inline void dump(const J& v, std::string& o) {
    switch (v.t) {
        case J::Null: o += "null"; break;
        case J::Bool: o += v.b ? "true" : "false"; break;
        case J::Num: {
            char b[40];
            if (std::isfinite(v.n) && std::floor(v.n) == v.n && std::fabs(v.n) < 9.007199254740992e15)
                std::snprintf(b, sizeof b, "%lld", static_cast<long long>(v.n));
            else if (std::isfinite(v.n))
                std::snprintf(b, sizeof b, "%.17g", v.n);
            else
                std::snprintf(b, sizeof b, "0");
            o += b;
            break;
        }
        case J::Str: o += '"'; o += peksubs::jesc(v.s); o += '"'; break;
        case J::Arr:
            o += '[';
            for (size_t i = 0; i < v.a.size(); ++i) { if (i) o += ','; dump(v.a[i], o); }
            o += ']';
            break;
        case J::Obj:
            o += '{';
            for (size_t i = 0; i < v.o.size(); ++i) {
                if (i) o += ',';
                o += '"'; o += peksubs::jesc(v.o[i].first); o += "\":";
                dump(v.o[i].second, o);
            }
            o += '}';
            break;
    }
}
inline std::string dump(const J& v) { std::string o; dump(v, o); return o; }

inline long long asInt(const J* v) {
    if (!v) return 0;
    if (v->t == J::Num) return static_cast<long long>(v->n);
    if (v->t == J::Bool) return v->b ? 1 : 0;
    if (v->t == J::Str) return std::atoll(v->s.c_str());
    return 0;
}

// ---------------------------------------------------------------- the database

class Db {
public:
    sqlite3* h = nullptr;
    std::mutex m;   // one writer at a time (a sync is several statements that must land together)

    ~Db() { if (h) sqlite3_close(h); }

    bool exec(const char* sql) {
        char* err = nullptr;
        if (sqlite3_exec(h, sql, nullptr, nullptr, &err) != SQLITE_OK) {
            std::cerr << "[accounts] SQL failed: " << (err ? err : "?") << std::endl;
            if (err) sqlite3_free(err);
            return false;
        }
        return true;
    }
};

/// One prepared statement; bind 1-based, read 0-based.
class St {
public:
    St(Db& db, const char* sql) {
        if (sqlite3_prepare_v2(db.h, sql, -1, &s_, nullptr) != SQLITE_OK) {
            std::cerr << "[accounts] cannot prepare: " << sqlite3_errmsg(db.h) << std::endl;
            s_ = nullptr;
        }
    }
    ~St() { if (s_) sqlite3_finalize(s_); }
    St& bind(int i, const std::string& v) { if (s_) sqlite3_bind_text(s_, i, v.data(), static_cast<int>(v.size()), SQLITE_TRANSIENT); return *this; }
    St& bind(int i, long long v) { if (s_) sqlite3_bind_int64(s_, i, v); return *this; }
    bool row() { return s_ && sqlite3_step(s_) == SQLITE_ROW; }
    bool run() { if (!s_) return false; const int rc = sqlite3_step(s_); return rc == SQLITE_DONE || rc == SQLITE_ROW; }
    void reset() { if (s_) { sqlite3_reset(s_); sqlite3_clear_bindings(s_); } }
    long long i(int c) { return sqlite3_column_int64(s_, c); }
    std::string s(int c) {
        const unsigned char* t = sqlite3_column_text(s_, c);
        return t ? std::string(reinterpret_cast<const char*>(t), static_cast<size_t>(sqlite3_column_bytes(s_, c))) : std::string();
    }
    bool ok() const { return s_ != nullptr; }
private:
    sqlite3_stmt* s_ = nullptr;
};

inline Db*& dbPtr() {
    static Db* d = nullptr;
    return d;
}

inline const char* kSchema = R"SQL(
CREATE TABLE IF NOT EXISTS users(
  id INTEGER PRIMARY KEY,
  username TEXT NOT NULL UNIQUE COLLATE NOCASE,
  email TEXT NOT NULL DEFAULT '',
  salt TEXT NOT NULL,
  hash TEXT NOT NULL,
  iterations INTEGER NOT NULL,
  owner INTEGER NOT NULL DEFAULT 0,
  created INTEGER NOT NULL,
  seq INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS sessions(
  token TEXT PRIMARY KEY,
  user INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device TEXT NOT NULL DEFAULT '',
  created INTEGER NOT NULL,
  seen INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS profiles(
  user INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  json TEXT NOT NULL,
  updated INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(user, id)
);
CREATE TABLE IF NOT EXISTS items(
  user INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  profile TEXT NOT NULL,
  kind TEXT NOT NULL,
  key TEXT NOT NULL,
  data TEXT NOT NULL,
  updated INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  seq INTEGER NOT NULL,
  PRIMARY KEY(user, profile, kind, key)
);
CREATE INDEX IF NOT EXISTS items_seq ON items(user, profile, seq);
CREATE TABLE IF NOT EXISTS ended(
  token TEXT PRIMARY KEY,
  reason TEXT NOT NULL,
  at INTEGER NOT NULL
);
)SQL";

/// Opens <dataDir>/accounts.db. A file that cannot be read is NOT replaced (it holds people's accounts): accounts stay off and the
/// reason is logged, the library keeps working.
inline bool open(const std::string& path) {
    auto* d = new Db();
    if (sqlite3_open_v2(path.c_str(), &d->h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nullptr) != SQLITE_OK) {
        std::cerr << "[accounts] cannot open " << path << ": " << (d->h ? sqlite3_errmsg(d->h) : "?") << " - accounts are OFF" << std::endl;
        delete d;
        return false;
    }
    sqlite3_busy_timeout(d->h, 5000);
    if (!d->exec("PRAGMA foreign_keys=ON") || !d->exec(kSchema)) {
        std::cerr << "[accounts] " << path << " could not be read or set up - accounts are OFF (the file was left as it is)" << std::endl;
        delete d;
        return false;
    }
    {   // why a session ended is only needed until its device has come back once; half a year is plenty
        St q(*d, "DELETE FROM ended WHERE at < ?");
        q.bind(1, nowMs() - 180LL * 24 * 3600 * 1000);
        q.run();
    }
    dbPtr() = d;
    return true;
}

/// Ends every session of [user] and remembers [reason] for each, so its devices learn why. Call with d.m held.
inline void endSessions(Db& d, long long user, const std::string& reason) {
    St keep(d, "INSERT OR REPLACE INTO ended(token, reason, at) SELECT token, ?, ? FROM sessions WHERE user = ?");
    keep.bind(1, reason).bind(2, nowMs()).bind(3, user);
    keep.run();
    St del(d, "DELETE FROM sessions WHERE user = ?");
    del.bind(1, user);
    del.run();
}

inline long long userId(Db& d, const std::string& username) {
    St q(d, "SELECT id FROM users WHERE username = ?");
    q.bind(1, username);
    return q.row() ? q.i(0) : 0;
}

inline bool isOn() { return dbPtr() != nullptr; }

inline long long userCount() {
    Db* d = dbPtr();
    if (!d) return 0;
    St q(*d, "SELECT count(*) FROM users");
    return q.row() ? q.i(0) : 0;
}

// ---------------------------------------------------------------- managing accounts (pek-server --add-user etc.)

struct UserRow {
    long long id = 0;
    std::string username, email;
    bool owner = false;
    long long created = 0, sessions = 0;
};

inline std::vector<UserRow> listUsers() {
    std::vector<UserRow> out;
    Db* d = dbPtr();
    if (!d) return out;
    St q(*d, "SELECT u.id, u.username, u.email, u.owner, u.created, (SELECT count(*) FROM sessions s WHERE s.user = u.id) FROM users u ORDER BY u.id");
    while (q.row()) out.push_back({q.i(0), q.s(1), q.s(2), q.i(3) != 0, q.i(4), q.i(5)});
    return out;
}

/// "" = done, else the reason in words.
inline std::string addUser(const std::string& username, const std::string& password, const std::string& email = "") {
    Db* d = dbPtr();
    if (!d) return "Accounts are not available (see the log).";
    if (!validUsername(username)) return "A username is 3 to 32 letters, digits, dots, dashes or underscores.";
    if (!validPassword(password)) return "Use a password of at least 8 characters.";
    std::lock_guard<std::mutex> lk(d->m);
    {
        St q(*d, "SELECT 1 FROM users WHERE username = ?");
        q.bind(1, username);
        if (q.row()) return "There is already an account called " + username + ".";
    }
    const bool first = userCount() == 0;
    const std::string salt = randomHex(16);
    const std::string hash = hashPassword(password, salt, kIterations);
    if (salt.empty() || hash.empty()) return "Could not make a password hash.";
    St q(*d, "INSERT INTO users(username, email, salt, hash, iterations, owner, created) VALUES(?,?,?,?,?,?,?)");
    q.bind(1, username).bind(2, lower(email)).bind(3, salt).bind(4, hash).bind(5, static_cast<long long>(kIterations)).bind(6, first ? 1LL : 0LL).bind(7, nowMs());
    return q.run() ? "" : std::string("Could not save the account: ") + sqlite3_errmsg(d->h);
}

/// Sets a new password and signs the account out everywhere.
inline std::string setPassword(const std::string& username, const std::string& password) {
    Db* d = dbPtr();
    if (!d) return "Accounts are not available (see the log).";
    if (!validPassword(password)) return "Use a password of at least 8 characters.";
    std::lock_guard<std::mutex> lk(d->m);
    const std::string salt = randomHex(16);
    const std::string hash = hashPassword(password, salt, kIterations);
    St q(*d, "UPDATE users SET salt = ?, hash = ?, iterations = ? WHERE username = ?");
    q.bind(1, salt).bind(2, hash).bind(3, static_cast<long long>(kIterations)).bind(4, username);
    if (!q.run() || sqlite3_changes(d->h) == 0) return "There is no account called " + username + ".";
    endSessions(*d, userId(*d, username), "password_changed");
    return "";
}

/// Signs the account out on every device (pek-server --sign-out); the account and its data stay.
inline std::string signOutUser(const std::string& username) {
    Db* d = dbPtr();
    if (!d) return "Accounts are not available (see the log).";
    std::lock_guard<std::mutex> lk(d->m);
    const long long id = userId(*d, username);
    if (id == 0) return "There is no account called " + username + ".";
    endSessions(*d, id, "signed_out_by_owner");
    return "";
}

/// Removes the account with all its profiles and synced data; its devices are signed out at once.
inline std::string removeUser(const std::string& username) {
    Db* d = dbPtr();
    if (!d) return "Accounts are not available (see the log).";
    std::lock_guard<std::mutex> lk(d->m);
    const long long id = userId(*d, username);
    if (id == 0) return "There is no account called " + username + ".";
    endSessions(*d, id, "account_removed");
    St q(*d, "DELETE FROM users WHERE username = ?");
    q.bind(1, username);
    if (!q.run() || sqlite3_changes(d->h) == 0) return "There is no account called " + username + ".";
    return "";
}

// ---------------------------------------------------------------- sessions

struct Who {
    long long user = 0;
    std::string username, email;
    bool owner = false;
};

/// [why] is set when there is no such session: the reason the owner ended it, or "bad_session".
inline bool lookupSession(const httplib::Request& req, Who& who, std::string& tokenHash, std::string& why) {
    why = "bad_session";
    Db* d = dbPtr();
    if (!d) return false;
    const std::string auth = req.get_header_value("Authorization");
    if (auth.rfind("Bearer ", 0) != 0 || auth.size() < 7 + 32) return false;
    tokenHash = sha256Hex(auth.substr(7));
    St q(*d, "SELECT u.id, u.username, u.email, u.owner FROM sessions s JOIN users u ON u.id = s.user WHERE s.token = ?");
    q.bind(1, tokenHash);
    if (!q.row()) {
        St e(*d, "SELECT reason FROM ended WHERE token = ?");
        e.bind(1, tokenHash);
        if (e.row()) why = e.s(0);
        return false;
    }
    who = {q.i(0), q.s(1), q.s(2), q.i(3) != 0};
    St t(*d, "UPDATE sessions SET seen = ? WHERE token = ?");
    t.bind(1, nowMs()).bind(2, tokenHash);
    t.run();
    return true;
}

// ---------------------------------------------------------------- login rate limit (per address)

struct Tries { int fails = 0; long long since = 0; };
inline std::mutex& triesMutex() { static std::mutex m; return m; }
inline std::map<std::string, Tries>& tries() { static std::map<std::string, Tries> t; return t; }
inline constexpr int kMaxFails = 10;
inline constexpr long long kWindowMs = 15LL * 60 * 1000;

/// Seconds to wait before this address may try again, 0 = go ahead.
inline long long waitFor(const std::string& addr) {
    std::lock_guard<std::mutex> lk(triesMutex());
    auto it = tries().find(addr);
    if (it == tries().end()) return 0;
    const long long left = it->second.since + kWindowMs - nowMs();
    if (left <= 0) { tries().erase(it); return 0; }
    return it->second.fails >= kMaxFails ? (left + 999) / 1000 : 0;
}
inline void failed(const std::string& addr) {
    std::lock_guard<std::mutex> lk(triesMutex());
    auto& t = tries()[addr];
    if (t.since == 0 || nowMs() - t.since > kWindowMs) t = {0, nowMs()};
    ++t.fails;
}
inline void succeeded(const std::string& addr) {
    std::lock_guard<std::mutex> lk(triesMutex());
    tries().erase(addr);
}

// ---------------------------------------------------------------- routes

inline void reply(httplib::Response& res, int status, const std::string& json) {
    res.status = status;
    res.set_content(json, "application/json");
}
inline void fail(httplib::Response& res, int status, const std::string& code) {
    reply(res, status, "{\"ok\": false, \"error\": \"" + peksubs::jesc(code) + "\"}");
}

inline std::string planFields() {
    return "\"plan\": \"self-hosted\", \"entitled\": true, \"until\": 0, \"since\": 0, \"lapse\": {\"state\": \"none\"}";
}

/// Login is open (no access key needed); every other /v1 route needs the key, checked in server.cpp.
inline bool isOpenRoute(const httplib::Request& req) {
    return isOn() && req.method == "POST" && req.path == "/v1/auth/login";
}

inline bool passwordMatches(Db& d, long long user, const std::string& password) {
    St q(d, "SELECT salt, hash, iterations FROM users WHERE id = ?");
    q.bind(1, user);
    if (!q.row()) return false;
    return sameText(hashPassword(password, q.s(0), static_cast<int>(q.i(2))), q.s(1));
}

// The kinds of item the app syncs, and how big one may be (the cloud's limits, a little roomier).
inline const std::vector<std::pair<std::string, size_t>>& kinds() {
    static const std::vector<std::pair<std::string, size_t>> k = {
        {"history", 4000}, {"progress", 4000}, {"favorites", 4000}, {"settings", 4000}, {"skins", 40000}, {"ratings", 4000}};
    return k;
}
inline constexpr int kPage = 2000;

/// [accessKey]: handed out with a session, so a device that signs in does not also need a pairing code.
inline void registerRoutes(httplib::Server& svr, const std::string& accessKey) {
    if (!isOn()) return;

    svr.Post("/v1/auth/login", [accessKey](const httplib::Request& req, httplib::Response& res) {
        Db& d = *dbPtr();
        const std::string addr = req.remote_addr;
        if (const long long w = waitFor(addr)) {
            reply(res, 429, "{\"ok\": false, \"error\": \"rate_limited\", \"retryAfter\": " + std::to_string(w) + "}");
            return;
        }
        J body;
        if (!peksubs::parseJson(req.body, body) || body.t != J::Obj) { fail(res, 400, "bad_request"); return; }
        const std::string id = body.str("email").empty() ? body.str("username") : body.str("email");
        const std::string password = body.str("password");
        long long user = 0;
        std::string username, email;
        {
            // username or email, case does not matter
            St q(d, "SELECT id, username, email FROM users WHERE username = ?1 OR (email <> '' AND email = lower(?1))");
            q.bind(1, id);
            if (q.row()) { user = q.i(0); username = q.s(1); email = q.s(2); }
        }
        if (user == 0 || password.empty() || !passwordMatches(d, user, password)) {
            if (user == 0) hashPassword(password, "0000000000000000", kIterations);   // same time whether the name exists or not
            failed(addr);
            std::cout << "[accounts] wrong sign-in for \"" << id << "\" from " << addr << std::endl;
            fail(res, 401, "bad_credentials");
            return;
        }
        succeeded(addr);
        const std::string token = randomHex(32);
        std::string device;
        if (const J* dev = body.get("device")) device = dev->t == J::Obj ? dev->str("name") : (dev->t == J::Str ? dev->s : "");
        if (device.size() > 80) device.resize(80);
        {
            std::lock_guard<std::mutex> lk(d.m);
            St q(d, "INSERT INTO sessions(token, user, device, created, seen) VALUES(?,?,?,?,?)");
            q.bind(1, sha256Hex(token)).bind(2, user).bind(3, device).bind(4, nowMs()).bind(5, nowMs());
            if (!q.run()) { fail(res, 500, "server"); return; }
        }
        std::cout << "[accounts] " << username << " signed in from " << addr << (device.empty() ? "" : " (" + device + ")") << std::endl;
        reply(res, 200, "{\"ok\": true, \"token\": \"" + token + "\", \"username\": \"" + peksubs::jesc(username) + "\", \"email\": \"" +
                            peksubs::jesc(email.empty() ? username : email) + "\", \"key\": \"" + peksubs::jesc(accessKey) + "\", " + planFields() + "}");
    });

    // Everything below: a signed-in session.
    auto guarded = [](std::function<void(const httplib::Request&, httplib::Response&, const Who&, const std::string&)> h) {
        return [h](const httplib::Request& req, httplib::Response& res) {
            Who who;
            std::string tok, why;
            if (!lookupSession(req, who, tok, why)) { fail(res, 401, why); return; }
            h(req, res, who, tok);
        };
    };

    svr.Post("/v1/auth/logout", guarded([](const httplib::Request&, httplib::Response& res, const Who&, const std::string& tok) {
        Db& d = *dbPtr();
        std::lock_guard<std::mutex> lk(d.m);
        St q(d, "DELETE FROM sessions WHERE token = ?");
        q.bind(1, tok);
        q.run();
        reply(res, 200, "{\"ok\": true}");
    }));

    svr.Post("/v1/auth/confirm", guarded([](const httplib::Request& req, httplib::Response& res, const Who& who, const std::string&) {
        J body;
        peksubs::parseJson(req.body, body);
        if (const long long w = waitFor(req.remote_addr)) {
            reply(res, 429, "{\"ok\": false, \"error\": \"rate_limited\", \"retryAfter\": " + std::to_string(w) + "}");
            return;
        }
        if (!passwordMatches(*dbPtr(), who.user, body.str("password"))) { failed(req.remote_addr); fail(res, 401, "bad_credentials"); return; }
        reply(res, 200, "{\"ok\": true}");
    }));

    svr.Get("/v1/me", guarded([](const httplib::Request&, httplib::Response& res, const Who& who, const std::string&) {
        reply(res, 200, "{\"ok\": true, \"username\": \"" + peksubs::jesc(who.username) + "\", \"email\": \"" +
                            peksubs::jesc(who.email.empty() ? who.username : who.email) + "\", \"owner\": " + (who.owner ? "true" : "false") + ", " + planFields() + "}");
    }));

    svr.Delete("/v1/account", guarded([](const httplib::Request&, httplib::Response& res, const Who& who, const std::string&) {
        if (who.owner) { fail(res, 403, "server_owner"); return; }   // the owner removes accounts on the server itself
        removeUser(who.username);
        std::cout << "[accounts] " << who.username << " deleted their account" << std::endl;
        reply(res, 200, "{\"ok\": true}");
    }));

    svr.Post("/v1/profiles/sync", guarded([](const httplib::Request& req, httplib::Response& res, const Who& who, const std::string&) {
        J body;
        if (!peksubs::parseJson(req.body, body) || body.t != J::Obj) { fail(res, 400, "bad_request"); return; }
        Db& d = *dbPtr();
        std::lock_guard<std::mutex> lk(d.m);
        d.exec("BEGIN IMMEDIATE");
        if (const J* list = body.get("profiles"); list && list->t == J::Arr) {
            St old(d, "SELECT updated FROM profiles WHERE user = ? AND id = ?");
            St put(d, "INSERT INTO profiles(user, id, json, updated, deleted) VALUES(?,?,?,?,?) "
                      "ON CONFLICT(user, id) DO UPDATE SET json = excluded.json, updated = excluded.updated, deleted = excluded.deleted");
            for (const J& p : list->a) {
                if (p.t != J::Obj) continue;
                const std::string id = p.str("id");
                const long long updated = asInt(p.get("updated"));
                if (id.empty() || id.size() > 40 || updated <= 0) continue;
                old.reset();
                old.bind(1, who.user).bind(2, id);
                if (old.row() && old.i(0) >= updated) continue;   // ours is as new or newer
                const std::string json = dump(p);
                if (json.size() > 20000) continue;
                put.reset();
                put.bind(1, who.user).bind(2, id).bind(3, json).bind(4, updated).bind(5, asInt(p.get("deleted")) ? 1LL : 0LL);
                put.run();
            }
        }
        d.exec("COMMIT");
        std::string out = "{\"ok\": true, \"profiles\": [";
        St all(d, "SELECT json FROM profiles WHERE user = ? ORDER BY id");
        all.bind(1, who.user);
        bool first = true;
        while (all.row()) { if (!first) out += ','; out += all.s(0); first = false; }
        out += "]}";
        reply(res, 200, out);
    }));

    svr.Post("/v1/sync", guarded([](const httplib::Request& req, httplib::Response& res, const Who& who, const std::string&) {
        J body;
        if (!peksubs::parseJson(req.body, body) || body.t != J::Obj) { fail(res, 400, "bad_request"); return; }
        const std::string profile = body.str("profile", "p1");
        if (profile.empty() || profile.size() > 40) { fail(res, 400, "bad_request"); return; }
        const long long since = std::max(0LL, asInt(body.get("since")));
        Db& d = *dbPtr();
        std::lock_guard<std::mutex> lk(d.m);
        {   // a profile removed on another device: the app keeps it if it is in use there and tries again (cloud.dart)
            St q(d, "SELECT deleted FROM profiles WHERE user = ? AND id = ?");
            q.bind(1, who.user).bind(2, profile);
            if (q.row() && q.i(0) != 0) { fail(res, 404, "unknown_profile"); return; }
        }
        d.exec("BEGIN IMMEDIATE");
        long long seq = 0;
        {
            St q(d, "SELECT seq FROM users WHERE id = ?");
            q.bind(1, who.user);
            if (q.row()) seq = q.i(0);
        }
        St old(d, "SELECT updated FROM items WHERE user = ? AND profile = ? AND kind = ? AND key = ?");
        St put(d, "INSERT INTO items(user, profile, kind, key, data, updated, deleted, seq) VALUES(?,?,?,?,?,?,?,?) "
                  "ON CONFLICT(user, profile, kind, key) DO UPDATE SET data = excluded.data, updated = excluded.updated, deleted = excluded.deleted, seq = excluded.seq");
        for (const auto& [kind, maxData] : kinds()) {
            const J* list = body.get(kind);
            if (!list || list->t != J::Arr) continue;
            for (const J& it : list->a) {
                if (it.t != J::Obj) continue;
                const std::string key = it.str("key");
                const long long updated = asInt(it.get("updated"));
                if (key.empty() || key.size() > 400 || updated <= 0) continue;
                const bool deleted = asInt(it.get("deleted")) != 0;
                const J* data = it.get("data");
                const std::string text = deleted || !data ? std::string("{}") : dump(*data);
                if (text.size() > maxData) continue;
                old.reset();
                old.bind(1, who.user).bind(2, profile).bind(3, kind).bind(4, key);
                if (old.row() && old.i(0) >= updated) continue;   // last writer wins
                put.reset();
                put.bind(1, who.user).bind(2, profile).bind(3, kind).bind(4, key).bind(5, text).bind(6, updated).bind(7, deleted ? 1LL : 0LL).bind(8, ++seq);
                put.run();
            }
        }
        {
            St q(d, "UPDATE users SET seq = ? WHERE id = ?");
            q.bind(1, seq).bind(2, who.user);
            q.run();
        }
        d.exec("COMMIT");

        // What changed since the cursor (this device's own pushes come back too; the app sees they are not newer and skips them).
        std::map<std::string, std::string> lists;
        for (const auto& k : kinds()) lists[k.first];
        St q(d, "SELECT kind, key, data, updated, deleted, seq FROM items WHERE user = ? AND profile = ? AND seq > ? ORDER BY seq LIMIT ?");
        q.bind(1, who.user).bind(2, profile).bind(3, since).bind(4, static_cast<long long>(kPage + 1));
        int n = 0;
        long long cursor = since;
        bool more = false;
        while (q.row()) {
            if (n == kPage) { more = true; break; }
            ++n;
            cursor = q.i(5);
            std::string& l = lists[q.s(0)];
            if (!l.empty()) l += ',';
            l += "{\"key\": \"" + peksubs::jesc(q.s(1)) + "\", \"data\": " + q.s(2) + ", \"updated\": " + std::to_string(q.i(3)) +
                 ", \"deleted\": " + std::to_string(q.i(4)) + "}";
        }
        std::string out = "{\"ok\": true, \"profile\": \"" + peksubs::jesc(profile) + "\", \"cursor\": " + std::to_string(cursor) +
                          ", \"more\": " + (more ? "true" : "false");
        for (const auto& [kind, text] : lists) out += ", \"" + kind + "\": [" + text + "]";
        out += "}";
        reply(res, 200, out);
    }));

    // Everything else PEK Cloud does (plugin backup, Discord, usage ...) is not part of a self-hosted server.
    svr.Get(R"(/v1/.*)", [](const httplib::Request&, httplib::Response& res) { fail(res, 404, "not_on_server"); });
    svr.Post(R"(/v1/.*)", [](const httplib::Request&, httplib::Response& res) { fail(res, 404, "not_on_server"); });
    svr.Delete(R"(/v1/.*)", [](const httplib::Request&, httplib::Response& res) { fail(res, 404, "not_on_server"); });
}

}  // namespace pekacct

#endif
