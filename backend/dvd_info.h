#ifndef PEK_DVD_INFO_H
#define PEK_DVD_INFO_H

// DVD-Video discs: finding them in the library and reading what is on them.
//
// A disc can be a folder (the one that holds VIDEO_TS/, or VIDEO_TS/ itself) or a .iso image. This file does the two things the
// library needs, without any native DVD library:
//   * isDiscFolder() / isDiscIso()   - "is this a DVD?"   (the scanner turns one into a single library entry)
//   * probe()                        - titles (number, length, chapters, angles), the longest title, and whether the disc has
//                                      its own menu
// Playing is done by libmpv (android/app/libs/libmpv-release.aar, built with libdvdnav / libdvdread / libdvdcss): it is given
// Info::device as dvd-device and "dvd://<title>" as the file (MpvController.kt).
//
// Header only on purpose: no CMakeLists.txt / dev.sh change, and backend/dvd_test.cpp builds on its own.
// Everything is read with std::ifstream and bounded sizes; nothing here throws.

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>
#include <system_error>
#include <vector>

namespace dvd {

struct Title {
    int n = 0;          // 1-based, the number mpv's dvd://N takes (the disc's own title table)
    int vts = 0;        // title set (VTS_nn_*) the title lives in
    int ttn = 0;        // title number inside that title set
    int chapters = 0;
    int angles = 1;
    int seconds = 0;    // 0 = the disc did not say
};

struct Info {
    bool ok = false;               // a DVD-Video disc
    bool iso = false;
    bool detailsKnown = false;     // false: it is a DVD but its tables could not be read (the title list is empty)
    std::string device;            // what libmpv's dvd-device gets: the folder that holds VIDEO_TS, or the .iso file
    std::string label;             // volume label of an .iso ("" for a folder)
    bool hasMenu = false;          // the disc has its own main menu (VIDEO_TS.VOB is there and the disc says it has menu pages)
    bool hasTitleMenus = false;    // at least one title set has its own menu (the per-feature "audio / subtitles / scenes" menus)
    int main = 0;                  // the longest title (1-based), 0 = unknown
    std::vector<Title> titles;
};

namespace detail {

inline std::string lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

inline uint32_t be32(const std::string& d, size_t o) {
    if (o + 4 > d.size()) return 0;
    return (uint32_t(uint8_t(d[o])) << 24) | (uint32_t(uint8_t(d[o + 1])) << 16) | (uint32_t(uint8_t(d[o + 2])) << 8) | uint32_t(uint8_t(d[o + 3]));
}
inline uint32_t be16(const std::string& d, size_t o) {
    if (o + 2 > d.size()) return 0;
    return (uint32_t(uint8_t(d[o])) << 8) | uint32_t(uint8_t(d[o + 1]));
}
inline uint32_t u8(const std::string& d, size_t o) { return o < d.size() ? uint8_t(d[o]) : 0; }
inline uint32_t le32(const std::string& d, size_t o) {
    if (o + 4 > d.size()) return 0;
    return uint32_t(uint8_t(d[o])) | (uint32_t(uint8_t(d[o + 1])) << 8) | (uint32_t(uint8_t(d[o + 2])) << 16) | (uint32_t(uint8_t(d[o + 3])) << 24);
}
inline int bcd(uint32_t b) { return int((b >> 4) & 0xF) * 10 + int(b & 0xF); }

constexpr size_t kSector = 2048;
constexpr uint64_t kMaxIfo = 4u << 20;     // an IFO is a few hundred KB at most; refuse anything silly

// One file of the disc's VIDEO_TS: where its bytes are.
struct FileRef {
    uint64_t size = 0;
    std::string path;       // folder disc: the real file
    uint64_t offset = 0;    // iso: byte position inside the image
    bool exists = false;
};

// The files of VIDEO_TS (lower-case name -> file), for a folder or an image. Read-only, filled by openFolder() / openIso().
struct Disc {
    bool iso = false;
    std::string device;
    std::string image;                       // iso: the image file
    std::string label;
    std::map<std::string, FileRef> files;

    const FileRef* find(const std::string& name) const {
        auto it = files.find(lower(name));
        return it == files.end() ? nullptr : &it->second;
    }

    // Whole file into memory (IFO / BUP only). False = missing, empty or too big.
    bool read(const FileRef* f, std::string& out) const {
        out.clear();
        if (!f || !f->exists || f->size == 0 || f->size > kMaxIfo) return false;
        std::ifstream in(iso ? image : f->path, std::ios::binary);
        if (!in) return false;
        in.seekg(static_cast<std::streamoff>(iso ? f->offset : 0));
        out.resize(static_cast<size_t>(f->size));
        in.read(&out[0], static_cast<std::streamsize>(f->size));
        if (static_cast<uint64_t>(in.gcount()) != f->size) { out.clear(); return false; }
        return true;
    }
    // The IFO, or the BUP (backup copy) of it when the IFO is missing or damaged.
    bool readIfo(const std::string& base, std::string& out, const char* sig) const {
        const FileRef* f = find(base + ".ifo");
        if (read(f, out) && out.size() >= 0x100 && std::memcmp(out.data(), sig, std::strlen(sig)) == 0) return true;
        f = find(base + ".bup");
        return read(f, out) && out.size() >= 0x100 && std::memcmp(out.data(), sig, std::strlen(sig)) == 0;
    }
};

// ---------------------------------------------------------------- folders

// A directory entry whose name is `want` (any case: FAT / exFAT cards and rips often have video_ts), or "" when there is none.
inline std::string childNamed(const std::filesystem::path& dir, const std::string& want, bool wantDir) {
    std::error_code ec;
    std::filesystem::directory_iterator it(dir, std::filesystem::directory_options::skip_permission_denied, ec);
    if (ec) return "";
    for (std::filesystem::directory_iterator end; it != end; it.increment(ec)) {
        if (ec) break;
        std::error_code e2;
        const bool isDir = it->is_directory(e2);
        if (e2 || isDir != wantDir) continue;
        if (lower(it->path().filename().string()) == want) return it->path().string();
    }
    return "";
}

inline bool listVideoTs(const std::filesystem::path& vts, Disc& d) {
    std::error_code ec;
    std::filesystem::directory_iterator it(vts, std::filesystem::directory_options::skip_permission_denied, ec);
    if (ec) return false;
    for (std::filesystem::directory_iterator end; it != end; it.increment(ec)) {
        if (ec) break;
        std::error_code e2;
        if (!it->is_regular_file(e2) || e2) continue;
        FileRef f;
        f.path = it->path().string();
        f.size = std::filesystem::file_size(it->path(), e2);
        if (e2) continue;
        f.exists = true;
        d.files[lower(it->path().filename().string())] = f;
    }
    return d.find("video_ts.ifo") != nullptr || d.find("video_ts.bup") != nullptr;
}

// `dir` is the folder that holds VIDEO_TS, or VIDEO_TS itself (its files straight inside).
inline bool openFolder(const std::string& dir, Disc& d) {
    d = Disc();
    std::error_code ec;
    if (!std::filesystem::is_directory(dir, ec) || ec) return false;
    const std::string sub = childNamed(dir, "video_ts", true);
    if (!sub.empty()) {
        d.device = dir;
        return listVideoTs(sub, d);
    }
    d.device = dir;                     // the folder itself holds VIDEO_TS.IFO
    return listVideoTs(dir, d);
}

// ---------------------------------------------------------------- ISO 9660 (every DVD image has this "bridge" next to UDF)

struct IsoDirRec { std::string name; uint32_t lba = 0; uint32_t size = 0; bool dir = false; };

inline bool readAt(std::ifstream& in, uint64_t off, size_t n, std::string& out) {
    out.assign(n, '\0');
    in.clear();
    in.seekg(static_cast<std::streamoff>(off));
    in.read(&out[0], static_cast<std::streamsize>(n));
    return static_cast<size_t>(in.gcount()) == n;
}

inline bool isoList(std::ifstream& in, uint32_t lba, uint32_t size, std::vector<IsoDirRec>& out) {
    out.clear();
    if (size == 0 || size > (1u << 20)) return false;
    std::string d;
    if (!readAt(in, uint64_t(lba) * kSector, size, d)) return false;
    size_t pos = 0;
    while (pos < d.size()) {
        const uint32_t len = u8(d, pos);
        if (len == 0) { pos = (pos / kSector + 1) * kSector; continue; }          // records never cross a sector: padding
        if (len < 34 || pos + len > d.size()) break;
        IsoDirRec r;
        r.lba = le32(d, pos + 2);
        r.size = le32(d, pos + 10);
        r.dir = (u8(d, pos + 25) & 2) != 0;
        const uint32_t nlen = u8(d, pos + 32);
        if (33 + nlen <= len) {
            r.name = d.substr(pos + 33, nlen);
            const size_t semi = r.name.find(';');
            if (semi != std::string::npos) r.name.resize(semi);               // "VIDEO_TS.IFO;1"
            if (r.name.size() == 1 && (r.name[0] == '\0' || r.name[0] == '\1')) r.name.clear();   // "." and ".."
            if (!r.name.empty()) out.push_back(r);
        }
        pos += len;
    }
    return true;
}

inline bool openIso(const std::string& path, Disc& d) {
    d = Disc();
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    std::string pvd;
    if (!readAt(in, 16 * kSector, kSector, pvd)) return false;
    if (u8(pvd, 0) != 1 || std::memcmp(pvd.data() + 1, "CD001", 5) != 0) return false;
    std::string label = pvd.substr(40, 32);
    while (!label.empty() && (label.back() == ' ' || label.back() == '\0')) label.pop_back();

    const uint32_t rootLba = le32(pvd, 156 + 2), rootSize = le32(pvd, 156 + 10);
    std::vector<IsoDirRec> root;
    if (!isoList(in, rootLba, rootSize, root)) return false;
    const IsoDirRec* vts = nullptr;
    for (const auto& r : root) if (r.dir && lower(r.name) == "video_ts") { vts = &r; break; }
    if (!vts) return false;
    std::vector<IsoDirRec> files;
    if (!isoList(in, vts->lba, vts->size, files)) return false;
    d.iso = true;
    d.image = path;
    d.device = path;
    d.label = label;
    for (const auto& r : files) {
        if (r.dir) continue;
        FileRef f;
        f.size = r.size;
        f.offset = uint64_t(r.lba) * kSector;
        f.exists = true;
        d.files[lower(r.name)] = f;
    }
    return d.find("video_ts.ifo") != nullptr || d.find("video_ts.bup") != nullptr;
}

// ---------------------------------------------------------------- IFO tables

inline std::string two(int n) { return (n < 10 ? "0" : "") + std::to_string(n); }

// Playing time of a PGC (dvd_time_t at +4: BCD hour, minute, second, frame).
inline int pgcSeconds(const std::string& ifo, size_t pgc) {
    const int h = bcd(u8(ifo, pgc + 4)), m = bcd(u8(ifo, pgc + 5)), s = bcd(u8(ifo, pgc + 6));
    if (h > 99 || m > 59 || s > 59) return 0;
    return h * 3600 + m * 60 + s;
}

// What one title set's IFO says: how long each title is, and whether it has menus of its own.
struct VtsInfo {
    bool read = false;
    bool menuTables = false;               // VTSM_PGCI_UT is present
    std::map<int, int> secondsByTtn;       // title number (VTS_TTN) -> seconds
    std::map<int, int> chaptersByTtn;      // title number -> chapter count (from VTS_PTT_SRPT; the disc's title table wins when it has one)
    int longest = 0;
};

inline VtsInfo readVts(const Disc& d, int vts) {
    VtsInfo v;
    std::string ifo;
    if (!d.readIfo("vts_" + two(vts) + "_0", ifo, "DVDVIDEO-VTS")) return v;
    v.read = true;
    v.menuTables = be32(ifo, 0xD0) != 0;

    // VTS_PGCIT: every program chain of the set, each with its playing time.
    std::vector<int> pgcSecs;                           // index = PGC number - 1
    const uint32_t pgcitSec = be32(ifo, 0xCC);
    if (pgcitSec != 0) {
        const size_t base = size_t(pgcitSec) * kSector;
        if (base + 8 <= ifo.size()) {
            const uint32_t n = std::min<uint32_t>(be16(ifo, base), 512);
            for (uint32_t i = 0; i < n; ++i) {
                const size_t srp = base + 8 + size_t(i) * 8;
                if (srp + 8 > ifo.size()) break;
                const uint32_t entryId = u8(ifo, srp);
                const size_t pgc = base + be32(ifo, srp + 4);
                int secs = 0;
                if (pgc + 0x10 <= ifo.size()) secs = pgcSeconds(ifo, pgc);
                pgcSecs.push_back(secs);
                v.longest = std::max(v.longest, secs);
                // Entry PGC of title number (entryId & 0x7f): the simple way to name a title's chain ...
                if ((entryId & 0x80) && secs > 0) v.secondsByTtn[int(entryId & 0x7F)] = secs;
            }
        }
    }

    // ... and VTS_PTT_SRPT is how libdvdnav does it: title -> its first chapter -> the PGC that chapter is in. It wins when present.
    const uint32_t pttSec = be32(ifo, 0xC8);
    if (pttSec != 0) {
        const size_t base = size_t(pttSec) * kSector;
        if (base + 8 <= ifo.size()) {
            const uint32_t nTt = std::min<uint32_t>(be16(ifo, base), 99);
            const uint32_t lastByte = be32(ifo, base + 4);
            for (uint32_t t = 0; t < nTt; ++t) {
                if (base + 8 + size_t(t) * 4 + 4 > ifo.size()) break;
                const uint32_t off = be32(ifo, base + 8 + size_t(t) * 4);
                const size_t pos = base + off;
                if (off < 8 || pos + 4 > ifo.size()) continue;
                const uint32_t next = (t + 1 < nTt && base + 8 + size_t(t + 1) * 4 + 4 <= ifo.size())
                                          ? be32(ifo, base + 8 + size_t(t + 1) * 4) : lastByte + 1;
                if (next > off) v.chaptersByTtn[int(t) + 1] = int((next - off) / 4);
                const uint32_t pgcn = be16(ifo, pos);                    // 1-based
                if (pgcn >= 1 && pgcn <= pgcSecs.size() && pgcSecs[pgcn - 1] > 0) v.secondsByTtn[int(t) + 1] = pgcSecs[pgcn - 1];
            }
        }
    }
    return v;
}

inline bool parseDisc(const Disc& d, Info& out) {
    std::string vmg;
    if (!d.readIfo("video_ts", vmg, "DVDVIDEO-VMG")) return false;

    // Menu: the disc says it has menu pages (VMGM_PGCI_UT) AND the menu video is really there (rips often delete VIDEO_TS.VOB).
    const FileRef* menuVob = d.find("video_ts.vob");
    out.hasMenu = be32(vmg, 0xC8) != 0 && menuVob && menuVob->size > 0;

    const uint32_t ttSec = be32(vmg, 0xC4);
    const size_t tt = size_t(ttSec) * kSector;
    const uint32_t nTitles = (ttSec != 0 && tt + 8 <= vmg.size()) ? std::min<uint32_t>(be16(vmg, tt), 99) : 0;
    const int nVts = int(std::min<uint32_t>(be16(vmg, 0x3E), 99));

    std::map<int, VtsInfo> sets;
    auto set = [&](int n) -> const VtsInfo& {
        auto it = sets.find(n);
        if (it == sets.end()) it = sets.emplace(n, readVts(d, n)).first;
        return it->second;
    };

    for (uint32_t i = 0; i < nTitles; ++i) {
        const size_t e = tt + 8 + size_t(i) * 12;
        if (e + 12 > vmg.size()) break;
        Title t;
        t.n = int(i) + 1;
        t.angles = std::max<int>(1, int(u8(vmg, e + 1)));
        t.chapters = int(be16(vmg, e + 2));
        t.vts = int(u8(vmg, e + 6));
        t.ttn = int(u8(vmg, e + 7));
        if (t.vts >= 1 && t.vts <= 99) {
            const VtsInfo& v = set(t.vts);
            auto it = v.secondsByTtn.find(t.ttn);
            t.seconds = it != v.secondsByTtn.end() ? it->second : 0;
            if (t.chapters <= 0) {
                auto ch = v.chaptersByTtn.find(t.ttn);
                if (ch != v.chaptersByTtn.end()) t.chapters = ch->second;
            }
        }
        out.titles.push_back(t);
    }

    for (int n = 1; n <= nVts; ++n) {
        const VtsInfo& v = set(n);
        const FileRef* vob = d.find("vts_" + two(n) + "_0.vob");
        if (v.read && v.menuTables && vob && vob->size > 0) { out.hasTitleMenus = true; break; }
    }

    int best = 0;
    for (const auto& t : out.titles) if (t.seconds > best) { best = t.seconds; out.main = t.n; }
    if (out.main == 0 && !out.titles.empty()) out.main = 1;
    return true;
}

inline Info probeDisc(const Disc& d) {
    Info out;
    out.ok = true;                         // the files are there: it is a DVD even if its tables are damaged
    out.iso = d.iso;
    out.device = d.device;
    out.label = d.label;
    out.detailsKnown = parseDisc(d, out);
    return out;
}

} // namespace detail

// ---------------------------------------------------------------- public

inline bool isIsoName(const std::string& path) {
    return detail::lower(std::filesystem::path(path).extension().string()) == ".iso";
}

// The folder that holds VIDEO_TS (or VIDEO_TS itself, files straight inside): a DVD-Video disc. One pass over the folder, so the
// scanner can ask this of every folder it walks.
inline bool isDiscFolder(const std::string& dir) {
    std::error_code ec;
    std::filesystem::directory_iterator it(dir, std::filesystem::directory_options::skip_permission_denied, ec);
    if (ec) return false;
    for (std::filesystem::directory_iterator end; it != end; it.increment(ec)) {
        if (ec) break;
        std::error_code e2;
        const std::string name = detail::lower(it->path().filename().string());
        if (name == "video_ts") {
            if (it->is_directory(e2) && !e2) {
                detail::Disc d;
                if (detail::listVideoTs(it->path(), d)) return true;
            }
        } else if (name == "video_ts.ifo" || name == "video_ts.bup") {
            if (it->is_regular_file(e2) && !e2) return true;
        }
    }
    return false;
}

// Size and modification time of the disc's VIDEO_TS.IFO (or .BUP): the scanner's "has this disc changed" stamp.
inline bool folderStamp(const std::string& dir, uint64_t& size, int64_t& mtime) {
    detail::Disc d;
    if (!detail::openFolder(dir, d)) return false;
    const detail::FileRef* f = d.find("video_ts.ifo");
    if (!f) f = d.find("video_ts.bup");
    if (!f) return false;
    size = f->size;
    std::error_code ec;
    const auto t = std::filesystem::last_write_time(f->path, ec);
    mtime = ec ? 0 : std::chrono::duration_cast<std::chrono::seconds>(t.time_since_epoch()).count();
    return true;
}

// A .iso that is a DVD-Video image (ISO 9660 side has VIDEO_TS/VIDEO_TS.IFO).
inline bool isDiscIso(const std::string& path) {
    if (!isIsoName(path)) return false;
    detail::Disc d;
    return detail::openIso(path, d);
}

// A disc of either kind, for a library path. ok == false: not a DVD (or not readable).
inline Info probe(const std::string& path) {
    detail::Disc d;
    std::error_code ec;
    if (std::filesystem::is_directory(path, ec) && !ec) {
        if (!detail::openFolder(path, d)) return Info();
    } else if (isIsoName(path)) {
        if (!detail::openIso(path, d)) return Info();
    } else {
        return Info();
    }
    return detail::probeDisc(d);
}

// True for a path the scanner made from a disc (a folder or an .iso): not a file ffprobe or an HTTP range read can use.
inline bool isDiscPath(const std::string& path) {
    std::error_code ec;
    if (std::filesystem::is_directory(path, ec) && !ec) return true;
    return isIsoName(path);
}

// What a title looks like in the picker, e.g. "1:52:30".
inline std::string clock(int seconds) {
    if (seconds <= 0) return "";
    const int h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60;
    std::string out = h > 0 ? std::to_string(h) + ":" + detail::two(m) : std::to_string(m);
    return out + ":" + detail::two(s);
}

inline std::string jsonEsc(const std::string& s) {
    std::string o;
    for (unsigned char c : s) {
        switch (c) {
            case '"': o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n"; break;
            case '\r': o += "\\r"; break;
            case '\t': o += "\\t"; break;
            default:
                if (c < 0x20) { char b[8]; std::snprintf(b, sizeof b, "\\u%04x", c); o += b; }
                else o += static_cast<char>(c);
        }
    }
    return o;
}

// {"dvd":true,"iso":false,"device":"...","label":"","detailsKnown":true,"hasMenu":true,"hasTitleMenus":true,"main":1,
//  "titles":[{"n":1,"vts":1,"ttn":1,"chapters":28,"angles":1,"seconds":6750}, ...]}      /  {"dvd":false}
inline std::string toJson(const Info& i) {
    if (!i.ok) return "{\"dvd\":false}";
    std::string j = "{\"dvd\":true,\"iso\":" + std::string(i.iso ? "true" : "false") +
                    ",\"device\":\"" + jsonEsc(i.device) + "\",\"label\":\"" + jsonEsc(i.label) +
                    "\",\"detailsKnown\":" + (i.detailsKnown ? "true" : "false") +
                    ",\"hasMenu\":" + (i.hasMenu ? "true" : "false") +
                    ",\"hasTitleMenus\":" + (i.hasTitleMenus ? "true" : "false") +
                    ",\"main\":" + std::to_string(i.main) + ",\"titles\":[";
    for (size_t k = 0; k < i.titles.size(); ++k) {
        const Title& t = i.titles[k];
        if (k) j += ",";
        j += "{\"n\":" + std::to_string(t.n) + ",\"vts\":" + std::to_string(t.vts) + ",\"ttn\":" + std::to_string(t.ttn) +
             ",\"chapters\":" + std::to_string(t.chapters) + ",\"angles\":" + std::to_string(t.angles) +
             ",\"seconds\":" + std::to_string(t.seconds) + "}";
    }
    return j + "]}";
}

} // namespace dvd

#endif
