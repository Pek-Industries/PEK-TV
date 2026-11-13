// Picks the right TMDb entry out of a search answer, instead of taking the first result.
//
// Every candidate is scored on
//   - title similarity   (both the title and the original title; word overlap + edit distance, "The" / "&" / punctuation ignored)
//   - year               (exact = full marks, one year off = most marks, two or more off = none: files are often dated by a
//                         different release / premiere / festival year)
//   - runtime            (movies: the file's length against TMDb's runtime; needs the candidate's details)
//   - popularity         (a small weight: it only breaks ties between otherwise equal candidates)
//   - season / episode fit (shows: the episodes found in the SAME FOLDER vote on which series they belong to; a candidate
//                         that has fewer seasons, or fewer episodes in a season, than the folder holds is out)
// A part that cannot be judged (no year in the file name, no runtime known, details not loaded) leaves the sum: the other
// parts are scaled up to fill its place, so a missing fact neither helps nor hurts.
//
// No network and no JSON library in here: the caller hands over the search answer and a callback that loads details for the
// few candidates that are worth the request. Test: g++ -std=c++17 -o /tmp/tmdb_match_test tmdb_match_test.cpp && /tmp/tmdb_match_test
#ifndef TMDB_MATCH_H
#define TMDB_MATCH_H

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace tmdbmatch {

// ---- reading TMDb's JSON (just enough for search results and the /movie/<id> and /tv/<id> details) -----------------------

// The objects of the "results" array (or of any array named `arrayKey`), one string each. A brace counter that skips strings.
inline std::vector<std::string> splitArray(const std::string& body, const char* arrayKey = "results") {
    std::vector<std::string> out;
    size_t pos = body.find(std::string("\"") + arrayKey + "\"");
    if (pos == std::string::npos) return out;
    pos = body.find('[', pos);
    if (pos == std::string::npos) return out;
    int depth = 0;
    bool inStr = false;
    size_t start = 0;
    for (size_t i = pos + 1; i < body.size(); ++i) {
        const char c = body[i];
        if (inStr) { if (c == '\\') ++i; else if (c == '"') inStr = false; continue; }
        if (c == '"') inStr = true;
        else if (c == '{') { if (depth++ == 0) start = i; }
        else if (c == '}') { if (--depth == 0) out.push_back(body.substr(start, i - start + 1)); }
        else if (c == ']' && depth == 0) break;
    }
    return out;
}

// The position just after `"key":` (and any blanks), or npos.
inline size_t valueAt(const std::string& obj, const std::string& key) {
    const std::string needle = "\"" + key + "\"";
    size_t k = obj.find(needle);
    while (k != std::string::npos) {
        size_t c = k + needle.size();
        while (c < obj.size() && std::isspace(static_cast<unsigned char>(obj[c]))) ++c;
        if (c < obj.size() && obj[c] == ':') {
            ++c;
            while (c < obj.size() && std::isspace(static_cast<unsigned char>(obj[c]))) ++c;
            return c;
        }
        k = obj.find(needle, k + 1);
    }
    return std::string::npos;
}

// A string value ("" for a missing key or a null).
inline std::string strField(const std::string& obj, const std::string& key) {
    size_t i = valueAt(obj, key);
    if (i == std::string::npos || i >= obj.size() || obj[i] != '"') return "";
    std::string out;
    for (++i; i < obj.size() && obj[i] != '"'; ++i) {
        if (obj[i] == '\\' && i + 1 < obj.size()) {
            const char n = obj[++i];
            out += (n == 'n' || n == 't' || n == 'r') ? ' ' : n;
        } else out += obj[i];
    }
    return out;
}

// A number value; `missing` for a missing key or a null.
inline double numField(const std::string& obj, const std::string& key, double missing = -1) {
    const size_t i = valueAt(obj, key);
    if (i == std::string::npos || i >= obj.size()) return missing;
    const char c = obj[i];
    if (!(std::isdigit(static_cast<unsigned char>(c)) || c == '-')) return missing;
    return std::atof(obj.c_str() + i);
}

// ---- candidates ------------------------------------------------------------------------------------------------------------

struct Candidate {
    std::string id, title, original_title, overview, poster_path;
    int year = 0;                 // 0 = TMDb has no date
    double popularity = -1;       // -1 = not given
    int runtime = 0;              // minutes, 0 = unknown (movie details)
    bool have_seasons = false;    // true once the series details are loaded
    std::map<int, int> season_eps;// season number -> episode count (specials, season 0, included when TMDb lists them)
    std::string raw;              // the search object, as TMDb sent it
};

inline int yearOf(const std::string& date) {
    if (date.size() >= 4 && std::isdigit(static_cast<unsigned char>(date[0])) && std::isdigit(static_cast<unsigned char>(date[1])) &&
        std::isdigit(static_cast<unsigned char>(date[2])) && std::isdigit(static_cast<unsigned char>(date[3])))
        return std::atoi(date.substr(0, 4).c_str());
    return 0;
}

// One search-result object -> a candidate. Movies say title / release_date, shows name / first_air_date.
inline Candidate parseCandidate(const std::string& obj, bool movie) {
    Candidate c;
    const double id = numField(obj, "id", -1);
    if (id >= 0) c.id = std::to_string(static_cast<long long>(id));
    c.title = strField(obj, movie ? "title" : "name");
    c.original_title = strField(obj, movie ? "original_title" : "original_name");
    c.overview = strField(obj, "overview");
    c.poster_path = strField(obj, "poster_path");
    c.year = yearOf(strField(obj, movie ? "release_date" : "first_air_date"));
    c.popularity = numField(obj, "popularity", -1);
    c.raw = obj;
    return c;
}

inline std::vector<Candidate> parseCandidates(const std::string& body, bool movie) {
    std::vector<Candidate> out;
    for (const auto& obj : splitArray(body)) {
        Candidate c = parseCandidate(obj, movie);
        if (!c.id.empty() && !c.title.empty()) out.push_back(std::move(c));
    }
    return out;
}

// /movie/<id>: the runtime.
inline void applyMovieDetails(Candidate& c, const std::string& body) {
    const double r = numField(body, "runtime", 0);
    if (r > 0) c.runtime = static_cast<int>(r);
}

// /tv/<id>: how many seasons, and how many episodes in each.
inline void applyShowDetails(Candidate& c, const std::string& body) {
    std::map<int, int> eps;
    for (const auto& s : splitArray(body, "seasons")) {
        const double n = numField(s, "season_number", -1), e = numField(s, "episode_count", -1);
        if (n >= 0 && e >= 0) eps[static_cast<int>(n)] = static_cast<int>(e);
    }
    if (!eps.empty()) { c.season_eps = std::move(eps); c.have_seasons = true; }
}

// ---- the parts of the score ------------------------------------------------------------------------------------------------

// Lowercased words: letters, digits and any non-ASCII byte (so Cyrillic / CJK titles still compare); a leading "the / a / an"
// and "and" go, so "The Office", "Office" and "Law & Order" / "Law and Order" line up.
inline std::vector<std::string> words(const std::string& s) {
    std::vector<std::string> w;
    std::string cur;
    auto flush = [&]() { if (!cur.empty()) { w.push_back(cur); cur.clear(); } };
    for (unsigned char c : s) {
        if (std::isalnum(c) || c >= 0x80) cur += static_cast<char>(std::tolower(c));
        else flush();
    }
    flush();
    if (w.size() > 1 && (w[0] == "the" || w[0] == "a" || w[0] == "an")) w.erase(w.begin());
    w.erase(std::remove(w.begin(), w.end(), std::string("and")), w.end());
    return w;
}

inline std::string joined(const std::vector<std::string>& w) {
    std::string s;
    for (const auto& x : w) s += x;
    return s;
}

inline double editRatio(const std::string& a, const std::string& b) {
    if (a.empty() && b.empty()) return 1.0;
    const size_t n = a.size(), m = b.size();
    std::vector<size_t> prev(m + 1), cur(m + 1);
    for (size_t j = 0; j <= m; ++j) prev[j] = j;
    for (size_t i = 1; i <= n; ++i) {
        cur[0] = i;
        for (size_t j = 1; j <= m; ++j)
            cur[j] = std::min({prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0u : 1u)});
        std::swap(prev, cur);
    }
    return 1.0 - static_cast<double>(prev[m]) / static_cast<double>(std::max(n, m));
}

// 0..1. 1.0 = the same title once punctuation, case, "The" and "&" are ignored.
inline double titleSimilarity(const std::string& a, const std::string& b) {
    const auto wa = words(a), wb = words(b);
    if (wa.empty() || wb.empty()) return 0;
    const std::string ja = joined(wa), jb = joined(wb);
    if (ja == jb) return 1.0;
    int shared = 0;
    std::vector<bool> used(wb.size(), false);
    for (const auto& x : wa)
        for (size_t j = 0; j < wb.size(); ++j)
            if (!used[j] && wb[j] == x) { used[j] = true; ++shared; break; }
    const double dice = 2.0 * shared / static_cast<double>(wa.size() + wb.size());
    double sim = 0.6 * dice + 0.4 * editRatio(ja, jb);
    // One title inside the other (\"Lioness\" / \"Special Ops: Lioness\", \"Shogun\" / \"Shogun 2024\"): files and folders often carry only
    // the short form or an extra tag. Every word of the shorter one has to be in the longer one, and it must be at least 5 letters
    // long (or 2 words), so a one-word title like \"Up\" does not match everything that has \"up\" in it.
    const bool aShort = wa.size() <= wb.size();
    const auto& sh = aShort ? wa : wb;
    const auto& lg = aShort ? wb : wa;
    if (shared == static_cast<int>(sh.size()) && (sh.size() >= 2 || joined(sh).size() >= 5)) sim = std::max(sim, 0.7);
    return sim;
}

// Year: exact 1.0, one off 0.7, further 0. Returns -1 when either year is unknown (the part drops out).
inline double yearScore(int want, int got) {
    if (want <= 0 || got <= 0) return -1;
    const int d = std::abs(want - got);
    return d == 0 ? 1.0 : d == 1 ? 0.7 : 0.0;
}

// Runtime (minutes): inside max(5 min, 8 %) = 1.0, then falling to 0 at max(25 min, 35 %). Extended cuts and credits make a
// file a bit longer than TMDb's number, so the band is generous. -1 when either is unknown.
inline double runtimeScore(int fileMin, int tmdbMin) {
    if (fileMin <= 0 || tmdbMin <= 0) return -1;
    const double d = std::abs(fileMin - tmdbMin);
    const double lo = std::max(5.0, 0.08 * tmdbMin), hi = std::max(25.0, 0.35 * tmdbMin);
    if (d <= lo) return 1.0;
    if (d >= hi) return 0.0;
    return 1.0 - (d - lo) / (hi - lo);
}

// Popularity: log scaled, 0 -> 0, about 100 -> 1. -1 when TMDb gave none.
inline double popularityScore(double p) {
    if (p < 0) return -1;
    return std::min(1.0, std::log10(1.0 + p) / 2.0);
}

// The episodes found next to each other (season, episode) vote: each one votes yes when the series has that season with at
// least that many episodes. Specials (season 0) are not counted: TMDb lists them unevenly. Returns the share of yes votes, or
// -1 when there is nothing to judge (series details not loaded, or no sibling in a numbered season).
inline double episodeFit(const std::vector<std::pair<int, int>>& siblings, const Candidate& c) {
    if (!c.have_seasons) return -1;
    int counted = 0, yes = 0;
    for (const auto& se : siblings) {
        if (se.first <= 0 || se.second <= 0) continue;
        ++counted;
        auto it = c.season_eps.find(se.first);
        if (it != c.season_eps.end() && se.second <= it->second) ++yes;
    }
    return counted == 0 ? -1 : static_cast<double>(yes) / counted;
}

// ---- scoring and picking ---------------------------------------------------------------------------------------------------

struct Query {
    bool movie = true;
    std::string title;
    int year = 0;                                   // 0 = the file / folder gives none
    int runtime = 0;                                // movies: the file's length in minutes, 0 = unknown
    std::string id_hint;                            // a {tmdb-N} tag in the folder name: names the exact entry
    std::vector<std::pair<int, int>> siblings;      // shows: (season, episode) of the episodes in the same folder
};

struct Score {
    double total = 0, title = 0, year = -1, runtime = -1, popularity = -1, fit = -1;
    bool usable = false;                            // clears the title bar and, for a show, the season / episode vote
};

constexpr double kMinTitle = 0.5;     // below this the candidate is a different title, whatever else matches
constexpr double kMinTotal = 0.40;
constexpr double kMinFit = 0.4;       // share of the folder's episodes the series must be able to contain
constexpr double kStrongTitle = 0.85; // a title this close is accepted even when the year, runtime or season / episode numbers disagree

inline Score scoreCandidate(const Query& q, const Candidate& c) {
    Score s;
    s.title = std::max(titleSimilarity(q.title, c.title), c.original_title.empty() ? 0.0 : titleSimilarity(q.title, c.original_title));
    s.year = yearScore(q.year, c.year);
    s.runtime = q.movie ? runtimeScore(q.runtime, c.runtime) : -1;
    s.popularity = popularityScore(c.popularity);
    s.fit = q.movie ? -1 : episodeFit(q.siblings, c);

    struct Part { double v, w; };
    const Part parts[] = {
        {s.title, q.movie ? 0.55 : 0.45},
        {s.year, q.movie ? 0.20 : 0.15},
        {s.runtime, 0.15},
        {s.fit, 0.30},
        {s.popularity, 0.10},
    };
    double sum = 0, weight = 0;
    for (const auto& p : parts) if (p.v >= 0) { sum += p.v * p.w; weight += p.w; }
    s.total = weight > 0 ? sum / weight : 0;
    // A strong title match is not thrown out by the season / episode vote alone (absolute numbering, specials, a season TMDb has not
    // listed yet and the like make that vote unreliable); a weak title still needs it.
    const bool strong = s.title >= kStrongTitle;
    s.usable = s.title >= kMinTitle && (strong || s.total >= kMinTotal) && (strong || !(s.fit >= 0 && s.fit < kMinFit));
    return s;
}

// Index of the best candidate, or -1 when none is good enough (the caller then keeps what it had: a guessed name stays, a
// poster stays empty, and Fix match is there for the rest).
// `enrich(Candidate&)` loads the details (runtime / seasons) of one candidate; it is called only for the `topK` best by the
// details-free score, and only when the query has something to compare them with (a runtime, or sibling episodes).
// `scores` (optional) receives one Score per candidate, for logging.
template <class Enrich>
int pick(const Query& q, std::vector<Candidate>& cands, Enrich enrich, int topK = 3, std::vector<Score>* scores = nullptr) {
    if (scores) scores->assign(cands.size(), Score());
    if (!q.id_hint.empty())
        for (size_t i = 0; i < cands.size(); ++i)
            if (cands[i].id == q.id_hint) { if (scores) { (*scores)[i] = scoreCandidate(q, cands[i]); (*scores)[i].usable = true; } return static_cast<int>(i); }

    std::vector<int> order;
    for (size_t i = 0; i < cands.size(); ++i) {
        const Score s = scoreCandidate(q, cands[i]);
        if (scores) (*scores)[i] = s;
        if (s.title >= kMinTitle) order.push_back(static_cast<int>(i));
    }
    // popularity second: of two equal-looking candidates the better known one is the likelier file
    std::stable_sort(order.begin(), order.end(), [&](int a, int b) {
        const double ta = (scores ? (*scores)[a] : scoreCandidate(q, cands[a])).total, tb = (scores ? (*scores)[b] : scoreCandidate(q, cands[b])).total;
        if (std::abs(ta - tb) > 1e-9) return ta > tb;
        return cands[a].popularity > cands[b].popularity;
    });
    const bool needDetails = q.movie ? q.runtime > 0 : !q.siblings.empty();
    if (needDetails && order.size() > static_cast<size_t>(topK)) order.resize(static_cast<size_t>(topK));
    if (needDetails)
        for (int i : order) enrich(cands[static_cast<size_t>(i)]);

    int best = -1;
    double bestTotal = -1;
    for (int i : order) {
        const Score s = scoreCandidate(q, cands[static_cast<size_t>(i)]);
        if (scores) (*scores)[static_cast<size_t>(i)] = s;
        if (!s.usable) continue;
        const bool better = s.total > bestTotal + 1e-9 ||
            (std::abs(s.total - bestTotal) <= 1e-9 && best >= 0 && cands[static_cast<size_t>(i)].popularity > cands[static_cast<size_t>(best)].popularity);
        if (better) { best = i; bestTotal = s.total; }
    }
    return best;
}

}  // namespace tmdbmatch

#endif
