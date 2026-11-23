#pragma once
// ============================================================
// Automatic subtitle look-up
//
// The app does not talk to OpenSubtitles itself: one shared account lives in the cloud worker
// (/v1/subs/search and /v1/subs/get), so nobody needs their own key. This file is the
// local half: it forwards the page's requests to the worker and keeps the downloaded text so the player
// (mpv, or the <video> element) can load it from this device.
//
//   POST /api/subtitles/search   title, [year], [season], [episode], [lang], [file]
//        -> {"ok":true,"results":[{id,name,lang,downloads,hi,ai,trusted,score}, ...]}   best first
//   POST /api/subtitles/fetch    id
//        -> {"ok":true,"url":"/api/subtitles/cache/<id>.srt"}
//   GET  /api/subtitles/cache/<id>.srt      the subtitle as UTF-8 SubRip text
//
// The worker's address is the PEK_SUBS_URL environment variable, default the sync worker.
//
// The self-hosted PEK Server (built with PEK_SELFHOST_BUILD) never uses that worker or PEK's OpenSubtitles account: it asks
// api.opensubtitles.com directly with the owner's own free API key (and, optionally, their own OpenSubtitles login for a bigger
// daily download allowance). Set with  pek-server --subtitles-key <key>  /  --subtitles-user <name>, or the environment variables
// OPENSUBTITLES_API_KEY, OPENSUBTITLES_USER, OPENSUBTITLES_PASSWORD. Kept in <data>/opensubtitles.txt. Same routes, same answers.
// Downloaded subtitles are kept in memory only (a few at a time), so no storage permission is needed.
// ============================================================

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cctype>
#include <cmath>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include "httplib.h"

namespace peksubs {

// ---------------- a small JSON reader (the answers are small and well formed) ----------------

struct J {
    enum Type { Null, Bool, Num, Str, Arr, Obj } t = Null;
    bool b = false;
    double n = 0;
    std::string s;
    std::vector<J> a;
    std::vector<std::pair<std::string, J>> o;

    const J* get(const std::string& k) const {
        if (t != Obj) return nullptr;
        for (const auto& kv : o) if (kv.first == k) return &kv.second;
        return nullptr;
    }
    std::string str(const std::string& k, const std::string& def = "") const {
        const J* v = get(k);
        if (!v) return def;
        if (v->t == Str) return v->s;
        if (v->t == Num) { std::ostringstream os; os << static_cast<long long>(v->n); return os.str(); }
        return def;
    }
    double num(const std::string& k, double def = 0) const {
        const J* v = get(k);
        return (v && v->t == Num) ? v->n : def;
    }
    bool flag(const std::string& k) const {
        const J* v = get(k);
        return v && v->t == Bool && v->b;
    }
};

class Parser {
public:
    explicit Parser(const std::string& text) : p_(text.c_str()), end_(text.c_str() + text.size()) {}
    bool parse(J& out) { ws(); if (!value(out, 0)) return false; ws(); return true; }

private:
    const char* p_;
    const char* end_;

    void ws() { while (p_ < end_ && (*p_ == ' ' || *p_ == '\n' || *p_ == '\r' || *p_ == '\t')) ++p_; }

    static void putUtf8(std::string& o, unsigned cp) {
        if (cp < 0x80) o += static_cast<char>(cp);
        else if (cp < 0x800) { o += static_cast<char>(0xC0 | (cp >> 6)); o += static_cast<char>(0x80 | (cp & 0x3F)); }
        else if (cp < 0x10000) { o += static_cast<char>(0xE0 | (cp >> 12)); o += static_cast<char>(0x80 | ((cp >> 6) & 0x3F)); o += static_cast<char>(0x80 | (cp & 0x3F)); }
        else { o += static_cast<char>(0xF0 | (cp >> 18)); o += static_cast<char>(0x80 | ((cp >> 12) & 0x3F)); o += static_cast<char>(0x80 | ((cp >> 6) & 0x3F)); o += static_cast<char>(0x80 | (cp & 0x3F)); }
    }

    bool hex4(unsigned& v) {
        if (end_ - p_ < 4) return false;
        v = 0;
        for (int i = 0; i < 4; ++i) {
            char c = *p_++;
            v <<= 4;
            if (c >= '0' && c <= '9') v |= static_cast<unsigned>(c - '0');
            else if (c >= 'a' && c <= 'f') v |= static_cast<unsigned>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') v |= static_cast<unsigned>(c - 'A' + 10);
            else return false;
        }
        return true;
    }

    bool string(std::string& out) {
        if (p_ >= end_ || *p_ != '"') return false;
        ++p_;
        while (p_ < end_) {
            char c = *p_++;
            if (c == '"') return true;
            if (c != '\\') { out += c; continue; }
            if (p_ >= end_) return false;
            char e = *p_++;
            switch (e) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    unsigned cp;
                    if (!hex4(cp)) return false;
                    if (cp >= 0xD800 && cp < 0xDC00 && end_ - p_ >= 6 && p_[0] == '\\' && p_[1] == 'u') {
                        p_ += 2;
                        unsigned lo;
                        if (!hex4(lo)) return false;
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    }
                    putUtf8(out, cp);
                    break;
                }
                default: return false;
            }
        }
        return false;
    }

    bool value(J& v, int depth) {
        if (depth > 40 || p_ >= end_) return false;
        char c = *p_;
        if (c == '{') {
            ++p_; v.t = J::Obj; ws();
            if (p_ < end_ && *p_ == '}') { ++p_; return true; }
            for (;;) {
                ws();
                std::string k;
                if (!string(k)) return false;
                ws();
                if (p_ >= end_ || *p_++ != ':') return false;
                ws();
                J child;
                if (!value(child, depth + 1)) return false;
                v.o.emplace_back(std::move(k), std::move(child));
                ws();
                if (p_ >= end_) return false;
                if (*p_ == ',') { ++p_; continue; }
                if (*p_ == '}') { ++p_; return true; }
                return false;
            }
        }
        if (c == '[') {
            ++p_; v.t = J::Arr; ws();
            if (p_ < end_ && *p_ == ']') { ++p_; return true; }
            for (;;) {
                ws();
                J child;
                if (!value(child, depth + 1)) return false;
                v.a.push_back(std::move(child));
                ws();
                if (p_ >= end_) return false;
                if (*p_ == ',') { ++p_; continue; }
                if (*p_ == ']') { ++p_; return true; }
                return false;
            }
        }
        if (c == '"') { v.t = J::Str; return string(v.s); }
        if (end_ - p_ >= 4 && std::string(p_, 4) == "true") { p_ += 4; v.t = J::Bool; v.b = true; return true; }
        if (end_ - p_ >= 5 && std::string(p_, 5) == "false") { p_ += 5; v.t = J::Bool; v.b = false; return true; }
        if (end_ - p_ >= 4 && std::string(p_, 4) == "null") { p_ += 4; v.t = J::Null; return true; }
        char* e = nullptr;
        double d = std::strtod(p_, &e);
        if (e == p_) return false;
        p_ = e; v.t = J::Num; v.n = d;
        return true;
    }
};

inline bool parseJson(const std::string& text, J& out) { Parser p(text); return p.parse(out); }

// ---------------- helpers ----------------

inline std::string jesc(const std::string& s) {
    std::string o;
    o.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"': o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n"; break;
            case '\r': o += "\\r"; break;
            case '\t': o += "\\t"; break;
            default:
                if (c < 0x20) o += ' ';
                else o += static_cast<char>(c);
        }
    }
    return o;
}

inline void fail(httplib::Response& res, int status, const std::string& msg) {
    res.status = status;
    res.set_header("Cache-Control", "no-store");
    res.set_content("{\"ok\": false, \"error\": \"" + jesc(msg) + "\"}", "application/json");
}

inline std::string lower(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

// Words of a release name / title, lower case (used to rank candidates against the playing file).
inline std::set<std::string> words(const std::string& s) {
    std::set<std::string> out;
    std::string cur;
    for (unsigned char ch : s) {
        if (std::isalnum(ch)) cur += static_cast<char>(std::tolower(ch));
        else { if (cur.size() > 1) out.insert(cur); cur.clear(); }
    }
    if (cur.size() > 1) out.insert(cur);
    return out;
}

#ifdef CPPHTTPLIB_OPENSSL_SUPPORT
inline void applyCa(httplib::SSLClient& c) {
    const char* f = std::getenv("SSL_CERT_FILE");
    const char* d = std::getenv("SSL_CERT_DIR");
    bool hasF = f && *f, hasD = d && *d;
    if (hasF || hasD) c.set_ca_cert_path(hasF ? f : "", hasD ? d : "");
}

#ifndef PEK_SELFHOST_BUILD   // the self-hosted server never talks to PEK's shared subtitle service (see own:: below)
// Where the shared subtitle service lives: https://host[:port]
inline bool workerHost(std::string& host, int& port) {
    const char* env = std::getenv("PEK_SUBS_URL");
    std::string u = (env && *env) ? env : "https://api.pekindustries.com";
    const std::string pre = "https://";
    if (u.compare(0, pre.size(), pre) != 0) return false;
    u = u.substr(pre.size());
    while (!u.empty() && u.back() == '/') u.pop_back();
    port = 443;
    size_t colon = u.find(':');
    if (colon != std::string::npos) { port = std::atoi(u.c_str() + colon + 1); u = u.substr(0, colon); }
    if (u.empty() || port <= 0 || port > 65535) return false;
    for (unsigned char c : u) if (!(std::isalnum(c) || c == '.' || c == '-')) return false;
    host = u;
    return true;
}

// POST a small JSON body to the worker. Returns false (and fills msg) when it cannot be reached.
inline bool workerPost(const std::string& path, const std::string& body, int& status, std::string& answer, std::string& msg) {
    std::string host; int port;
    if (!workerHost(host, port)) { msg = "The subtitle service address is not valid."; return false; }
    httplib::SSLClient cli(host, port);
    applyCa(cli);
    cli.set_connection_timeout(8);
    cli.set_read_timeout(25);
    cli.set_follow_location(true);
    auto r = cli.Post(path, httplib::Headers{{"User-Agent", "PEK-TV-subtitles"}, {"Accept", "application/json"}}, body, "application/json");
    if (!r) { msg = "Couldn't reach the subtitle service (" + httplib::to_string(r.error()) + ")."; return false; }
    status = r->status;
    answer = r->body;
    return true;
}
#endif  // !PEK_SELFHOST_BUILD
#endif  // CPPHTTPLIB_OPENSSL_SUPPORT


#if defined(CPPHTTPLIB_OPENSSL_SUPPORT) && defined(PEK_SELFHOST_BUILD)
// ---------------- self-hosted: the owner's own OpenSubtitles key ----------------
namespace own {

inline constexpr const char* kHost = "api.opensubtitles.com";
inline constexpr const char* kSignUp = "https://www.opensubtitles.com/en/consumers";
inline constexpr const char* kFile = "opensubtitles.txt";

struct Creds { std::string key, user, pass; };
struct State {
    std::mutex m;
    Creds c;
    std::string token, tokenHost;   // from /login; tokenHost is where downloads go (VIP accounts get their own host)
    long long tokenUntil = 0;
};
inline State& state() { static State s; return s; }
inline long long nowS() {
    return std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();
}
inline std::string trim(std::string v) {
    while (!v.empty() && std::isspace(static_cast<unsigned char>(v.back()))) v.pop_back();
    size_t i = 0; while (i < v.size() && std::isspace(static_cast<unsigned char>(v[i]))) ++i;
    return v.substr(i);
}
inline std::string envS(const char* n) { const char* e = std::getenv(n); return e ? trim(e) : std::string(); }
inline std::string fileIn(const std::string& dataDir) { return dataDir + "/" + kFile; }

/// <data>/opensubtitles.txt (line 1 key, 2 user, 3 password), then the environment variables win.
inline Creds load(const std::string& dataDir) {
    Creds c;
    std::ifstream in(std::filesystem::u8path(fileIn(dataDir)));
    if (in) { std::getline(in, c.key); std::getline(in, c.user); std::getline(in, c.pass); }
    c.key = trim(c.key); c.user = trim(c.user); c.pass = trim(c.pass);
    if (!envS("OPENSUBTITLES_API_KEY").empty()) c.key = envS("OPENSUBTITLES_API_KEY");
    if (!envS("OPENSUBTITLES_USER").empty()) { c.user = envS("OPENSUBTITLES_USER"); c.pass = envS("OPENSUBTITLES_PASSWORD"); }
    return c;
}
inline bool save(const std::string& dataDir, const Creds& c) {
    std::ofstream o(std::filesystem::u8path(fileIn(dataDir)), std::ios::trunc);
    if (!o) return false;
    o << c.key << "\n" << c.user << "\n" << c.pass << "\n";
    return true;
}
inline void set(const Creds& c) { std::lock_guard<std::mutex> lk(state().m); state().c = c; state().token.clear(); }
inline Creds get() { std::lock_guard<std::mutex> lk(state().m); return state().c; }
inline bool hasKey() { return !get().key.empty(); }

inline httplib::Headers headers(const std::string& key, const std::string& token = {}) {
    httplib::Headers h{{"Api-Key", key}, {"User-Agent", "PEK Server v" PEK_SERVER_VERSION}, {"Accept", "application/json"}};
    if (!token.empty()) h.emplace("Authorization", "Bearer " + token);
    return h;
}
inline std::unique_ptr<httplib::SSLClient> client(const std::string& host, int readTimeout = 20) {
    auto c = std::make_unique<httplib::SSLClient>(host, 443);
    applyCa(*c);
    c->set_connection_timeout(8);
    c->set_read_timeout(readTimeout);
    c->set_follow_location(true);
    return c;
}

/// Logs in with the owner's OpenSubtitles account. 0 = ok, 1 = refused, 2 = unreachable.
inline int login(const Creds& c, std::string& token, std::string& host, std::string& msg) {
    auto cli = client(kHost);
    auto r = cli->Post("/api/v1/login", headers(c.key),
                       "{\"username\":\"" + jesc(c.user) + "\",\"password\":\"" + jesc(c.pass) + "\"}", "application/json");
    if (!r) { msg = "Couldn't reach OpenSubtitles."; return 2; }
    J j;
    if (r->status != 200 || !parseJson(r->body, j) || j.str("token").empty()) {
        msg = r->status == 401 ? "OpenSubtitles refused that user name or password." : "OpenSubtitles login failed (HTTP " + std::to_string(r->status) + ").";
        return r->status == 401 || r->status == 403 ? 1 : 2;
    }
    token = j.str("token");
    host = j.str("base_url");
    if (host.empty() || host.find('/') != std::string::npos) host = kHost;
    return 0;
}

/// A login token when an account is set (kept ~a day), else "" (downloads then count against the key's anonymous allowance).
inline void session(const Creds& c, std::string& token, std::string& host) {
    token.clear(); host = kHost;
    if (c.user.empty()) return;
    {
        std::lock_guard<std::mutex> lk(state().m);
        if (!state().token.empty() && nowS() < state().tokenUntil) { token = state().token; host = state().tokenHost; return; }
    }
    std::string msg;
    if (login(c, token, host, msg) != 0) {
        std::cout << "[PEK Server] OpenSubtitles: " << msg << " Downloads use the key's own allowance." << std::endl;
        token.clear(); host = kHost;
        return;
    }
    std::lock_guard<std::mutex> lk(state().m);
    state().token = token; state().tokenHost = host; state().tokenUntil = nowS() + 20 * 3600;
}

inline std::string noKeyMsg() {
    return std::string("Subtitle search on this server needs the owner's own free OpenSubtitles API key (") + kSignUp +
           "). Set it with  pek-server --subtitles-key <key>  and restart the server.";
}

/// GET /api/v1/subtitles, ranked the same way as the shared service: release words like the playing file's, then trust and downloads.
inline bool search(const Creds& c, const std::string& title, int year, int season, int episode, std::string lang,
                   const std::string& file, std::string& out, int& status, std::string& msg) {
    lang = lower(lang);
    std::string langs;
    for (unsigned char ch : lang) if (std::isalnum(ch) || ch == ',' || ch == '-') langs += static_cast<char>(ch);
    if (langs.empty()) langs = "en";
    // OpenSubtitles wants the parameters sorted and lower case (anything else costs a redirect).
    std::string q = "/api/v1/subtitles?";
    if (episode > 0) q += "episode_number=" + std::to_string(episode) + "&";
    q += "languages=" + httplib::encode_uri_component(langs) + "&query=" + httplib::encode_uri_component(lower(title));
    if (season > 0) q += "&season_number=" + std::to_string(season);
    if (year > 0 && season <= 0) q += "&year=" + std::to_string(year);
    auto cli = client(kHost);
    auto r = cli->Get(q, headers(c.key));
    if (!r) { status = 502; msg = "Couldn't reach OpenSubtitles."; return false; }
    if (r->status == 401 || r->status == 403) { status = 502; msg = "OpenSubtitles refused this server's API key. Set it again with  pek-server --subtitles-key <key>"; return false; }
    if (r->status == 429) { status = 429; msg = "OpenSubtitles says too many searches right now. Try again in a minute."; return false; }
    J j;
    if (r->status != 200 || !parseJson(r->body, j)) { status = 502; msg = "OpenSubtitles answered HTTP " + std::to_string(r->status) + "."; return false; }
    const J* data = j.get("data");
    const std::set<std::string> want = words(file);
    struct Row { std::string id, name, lang; long long downloads; bool hi, ai, trusted; double score; };
    std::vector<Row> rows;
    if (data && data->t == J::Arr) {
        for (const J& d : data->a) {
            const J* a = d.get("attributes");
            if (!a) continue;
            const J* files = a->get("files");
            if (!files || files->t != J::Arr || files->a.empty()) continue;
            Row row;
            row.id = files->a[0].str("file_id");
            if (row.id.empty() || row.id.size() > 12) continue;
            row.name = a->str("release");
            if (row.name.empty()) row.name = files->a[0].str("file_name");
            row.lang = a->str("language");
            row.downloads = static_cast<long long>(a->num("download_count"));
            row.hi = a->flag("hearing_impaired");
            row.ai = a->flag("ai_translated") || a->flag("machine_translated");
            row.trusted = a->flag("from_trusted");
            double match = 0;
            if (!want.empty()) {
                const auto have = words(row.name);
                int same = 0;
                for (const auto& w : want) if (have.count(w)) ++same;
                match = static_cast<double>(same) / want.size();
            }
            row.score = match * 100 + std::log10(1.0 + row.downloads) * 5 + (row.trusted ? 5 : 0) - (row.ai ? 15 : 0) - (row.hi ? 2 : 0);
            rows.push_back(std::move(row));
        }
    }
    std::stable_sort(rows.begin(), rows.end(), [](const Row& x, const Row& y) { return x.score > y.score; });
    if (rows.size() > 40) rows.resize(40);
    out = "{\"ok\": true, \"results\": [";
    for (size_t i = 0; i < rows.size(); ++i) {
        const Row& w = rows[i];
        std::ostringstream sc; sc << std::round(w.score * 10) / 10;
        out += std::string(i ? "," : "") + "{\"id\":\"" + w.id + "\",\"name\":\"" + jesc(w.name) + "\",\"lang\":\"" + jesc(w.lang) +
               "\",\"downloads\":" + std::to_string(w.downloads) + ",\"hi\":" + (w.hi ? "true" : "false") + ",\"ai\":" +
               (w.ai ? "true" : "false") + ",\"trusted\":" + (w.trusted ? "true" : "false") + ",\"score\":" + sc.str() + "}";
    }
    out += "]}";
    return true;
}

/// POST /api/v1/download, then the file itself from the link it gives.
inline bool fetch(const Creds& c, const std::string& id, std::string& text, int& status, std::string& msg) {
    std::string token, host;
    session(c, token, host);
    auto cli = client(host);
    auto r = cli->Post("/api/v1/download", headers(c.key, token), "{\"file_id\":" + id + "}", "application/json");
    if (!r) { status = 502; msg = "Couldn't reach OpenSubtitles."; return false; }
    J j;
    parseJson(r->body, j);
    if (r->status == 406 || r->status == 429) {
        status = 429;
        msg = "This server's OpenSubtitles download allowance for today is used up" +
              std::string(c.user.empty() ? ". A free OpenSubtitles account gives more: pek-server --subtitles-user <name>" : ".");
        return false;
    }
    if (r->status == 401 || r->status == 403) { status = 502; msg = "OpenSubtitles refused this server's API key or login."; return false; }
    const std::string link = j.str("link");
    if (r->status != 200 || link.compare(0, 8, "https://") != 0) { status = 502; msg = "OpenSubtitles did not give a download link."; return false; }
    const size_t slash = link.find('/', 8);
    const std::string lhost = link.substr(8, slash == std::string::npos ? std::string::npos : slash - 8);
    const std::string lpath = slash == std::string::npos ? "/" : link.substr(slash);
    if (lhost.empty() || lhost.find(':') != std::string::npos) { status = 502; msg = "OpenSubtitles gave an odd download link."; return false; }
    auto dl = client(lhost, 30);
    auto f = dl->Get(lpath, httplib::Headers{{"User-Agent", "PEK Server v" PEK_SERVER_VERSION}});
    if (!f || f->status != 200 || f->body.empty()) { status = 502; msg = "Couldn't download that subtitle."; return false; }
    text = f->body;
    return true;
}

/// pek-server --subtitles-key <key | off> / --subtitles-user <name> (password given). Returns the exit code.
inline int command(const std::string& dataDir, const std::string& keyArg, const std::string& user, const std::string& pass,
                   std::ostream& out, std::ostream& err) {
    Creds c = load(dataDir);
    if (!keyArg.empty()) {
        const std::string k = trim(keyArg);
        std::error_code ec;
        if (k == "off" || k == "none" || k == "remove") {
            std::filesystem::remove(std::filesystem::u8path(fileIn(dataDir)), ec);
            out << "OpenSubtitles key (and login) removed. Restart PEK Server." << std::endl;
            return 0;
        }
        if (k.size() < 16 || k.size() > 100) { err << "That does not look like an OpenSubtitles API key. Make one at " << kSignUp << std::endl; return 1; }
        auto cli = client(kHost);
        // A search needs a real key (infos/formats does not). A one-off query, so no cached answer can stand in for the key check.
        auto r = cli->Get("/api/v1/subtitles?languages=en&query=pekkeycheck" + std::to_string(nowS() % 100000), headers(k));
        if (r && (r->status == 401 || r->status == 403)) { err << "OpenSubtitles refused that key. Copy it again from " << kSignUp << std::endl; return 1; }
        if (!r || r->status != 200) out << "OpenSubtitles could not be reached to test the key right now; it is saved anyway." << std::endl;
        else out << "Your OpenSubtitles key works." << std::endl;
        c.key = k;
    }
    if (!user.empty()) {
        if (c.key.empty()) { err << "Set the API key first:  pek-server --subtitles-key <key>" << std::endl; return 1; }
        Creds t = c; t.user = trim(user); t.pass = pass;
        std::string token, host, msg;
        const int ok = login(t, token, host, msg);
        if (ok == 1) { err << msg << std::endl; return 1; }
        if (ok == 2) out << msg << " The login is saved anyway." << std::endl;
        else out << "Signed in to OpenSubtitles as " << t.user << "." << std::endl;
        c = t;
    }
    if (!save(dataDir, c)) { err << "Could not write " << fileIn(dataDir) << std::endl; return 1; }
    out << "Saved. Restart PEK Server to use it." << std::endl;
    return 0;
}

} // namespace own
#endif

// ---------------- text: make it UTF-8 SubRip ----------------

inline bool validUtf8(const std::string& s) {
    size_t i = 0, n = s.size();
    while (i < n) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        size_t len = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 0;
        if (!len || i + len > n) return false;
        for (size_t k = 1; k < len; ++k) if ((static_cast<unsigned char>(s[i + k]) & 0xC0) != 0x80) return false;
        i += len;
    }
    return true;
}

// Old subtitle files are often Windows-1252. 0x80-0x9F differ from Latin-1; the rest map straight.
inline std::string fromCp1252(const std::string& s) {
    static const unsigned short hi[32] = {
        0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
        0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178};
    std::string o;
    o.reserve(s.size() + s.size() / 8);
    for (unsigned char c : s) {
        unsigned cp = c;
        if (c >= 0x80 && c < 0xA0) cp = hi[c - 0x80];
        if (cp < 0x80) o += static_cast<char>(cp);
        else if (cp < 0x800) { o += static_cast<char>(0xC0 | (cp >> 6)); o += static_cast<char>(0x80 | (cp & 0x3F)); }
        else { o += static_cast<char>(0xE0 | (cp >> 12)); o += static_cast<char>(0x80 | ((cp >> 6) & 0x3F)); o += static_cast<char>(0x80 | (cp & 0x3F)); }
    }
    return o;
}

inline std::string normalizeSubtitle(std::string s) {
    if (s.size() >= 3 && static_cast<unsigned char>(s[0]) == 0xEF && static_cast<unsigned char>(s[1]) == 0xBB && static_cast<unsigned char>(s[2]) == 0xBF) s.erase(0, 3);
    if (!validUtf8(s)) s = fromCp1252(s);
    return s;
}

// A few subtitles at a time, in memory.
inline std::mutex& cacheMu() { static std::mutex m; return m; }
inline std::map<std::string, std::string>& cacheMap() { static std::map<std::string, std::string> m; return m; }
inline std::deque<std::string>& cacheOrder() { static std::deque<std::string> d; return d; }
inline void cachePut(const std::string& id, const std::string& text) {
    std::lock_guard<std::mutex> lk(cacheMu());
    if (!cacheMap().count(id)) cacheOrder().push_back(id);
    cacheMap()[id] = text;
    while (cacheOrder().size() > 12) { cacheMap().erase(cacheOrder().front()); cacheOrder().pop_front(); }
}
inline bool cacheGet(const std::string& id, std::string& out) {
    std::lock_guard<std::mutex> lk(cacheMu());
    auto it = cacheMap().find(id);
    if (it == cacheMap().end()) return false;
    out = it->second;
    return true;
}

inline void registerSubtitleRoutes(httplib::Server& svr) {
#ifdef CPPHTTPLIB_OPENSSL_SUPPORT
    svr.Post("/api/subtitles/search", [](const httplib::Request& req, httplib::Response& res) {
        std::string title = req.get_param_value("title");
        if (title.empty() || title.size() > 200) { fail(res, 400, "No title to search for."); return; }
        std::string body = "{\"title\":\"" + jesc(title) + "\"";
        for (const char* k : {"year", "season", "episode"}) body += std::string(",\"") + k + "\":" + std::to_string(std::atoi(req.get_param_value(k).c_str()));
        body += ",\"lang\":\"" + jesc(req.get_param_value("lang").substr(0, 40)) + "\"";
        body += ",\"file\":\"" + jesc(req.get_param_value("file").substr(0, 300)) + "\"}";

        int status = 0; std::string answer, msg;
#ifdef PEK_SELFHOST_BUILD
        // Self-hosted: the owner's own OpenSubtitles key, never PEK's shared account.
        const own::Creds creds = own::get();
        if (creds.key.empty()) { fail(res, 503, own::noKeyMsg()); return; }
        if (!own::search(creds, title, std::atoi(req.get_param_value("year").c_str()), std::atoi(req.get_param_value("season").c_str()),
                         std::atoi(req.get_param_value("episode").c_str()), req.get_param_value("lang").substr(0, 40),
                         req.get_param_value("file").substr(0, 300), answer, status, msg)) { fail(res, status, msg); return; }
        (void)body;
        status = 200;
#else
        if (!workerPost("/v1/subs/search", body, status, answer, msg)) { fail(res, 502, msg); return; }
#endif
        J j;
        if (!parseJson(answer, j)) { fail(res, 502, "The subtitle service sent an answer that could not be read."); return; }
        if (status != 200 || j.t != J::Obj || j.flag("ok") == false) {
            std::string e = j.str("error");
            fail(res, status >= 400 ? status : 502, e.empty() ? "The subtitle service answered HTTP " + std::to_string(status) + "." : e);
            return;
        }
        res.set_header("Cache-Control", "no-store");
        res.set_content(answer, "application/json");     // already in the shape the page wants
    });

    svr.Post("/api/subtitles/fetch", [](const httplib::Request& req, httplib::Response& res) {
        std::string id = req.get_param_value("id");
        if (id.empty() || id.size() > 12 || !std::all_of(id.begin(), id.end(), [](unsigned char c) { return std::isdigit(c) != 0; })) {
            fail(res, 400, "Bad subtitle id.");
            return;
        }
        std::string have;
        if (!cacheGet(id, have)) {                       // not on this device yet: ask the service (free if anyone fetched it before)
            int status = 0; std::string answer, msg;
#ifdef PEK_SELFHOST_BUILD
            const own::Creds creds = own::get();
            if (creds.key.empty()) { fail(res, 503, own::noKeyMsg()); return; }
            std::string text;
            if (!own::fetch(creds, id, text, status, msg)) { fail(res, status, msg); return; }
            J j; j.t = J::Obj; j.o.emplace_back("ok", J{}); j.o.back().second.t = J::Bool; j.o.back().second.b = true;
            status = 200;
#else
            if (!workerPost("/v1/subs/get", "{\"id\":\"" + id + "\"}", status, answer, msg)) { fail(res, 502, msg); return; }
            J j;
            if (!parseJson(answer, j)) { fail(res, 502, "The subtitle service sent an answer that could not be read."); return; }
            std::string text = j.str("text");
#endif
            if (status != 200 || !j.flag("ok") || text.empty()) {
                std::string e = j.str("error");
                fail(res, status >= 400 ? status : 502, e.empty() ? "Couldn't get that subtitle." : e);
                return;
            }
            if (text.size() > 3 * 1024 * 1024) { fail(res, 502, "That subtitle file is too large."); return; }
            cachePut(id, normalizeSubtitle(text));
        }
        res.set_header("Cache-Control", "no-store");
        res.set_content("{\"ok\": true, \"url\": \"/api/subtitles/cache/" + id + ".srt\"}", "application/json");
    });

    svr.Get(R"(/api/subtitles/cache/(\d{1,12})\.srt)", [](const httplib::Request& req, httplib::Response& res) {
        std::string text;
        if (!cacheGet(req.matches[1].str(), text)) { res.status = 404; res.set_content("not found", "text/plain"); return; }
        res.set_header("Cache-Control", "no-store");
        res.set_content(text, "application/x-subrip; charset=utf-8");
    });
#else
    svr.Post("/api/subtitles/search", [](const httplib::Request&, httplib::Response& res) {
        res.status = 501;
        res.set_content("{\"ok\": false, \"error\": \"This build has no HTTPS support, so it can't look up subtitles.\"}", "application/json");
    });
#endif
}

}  // namespace peksubs
