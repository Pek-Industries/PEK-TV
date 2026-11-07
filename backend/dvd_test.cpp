// Self-contained test for dvd_info.h: builds small fake DVDs (a folder and an .iso, with real IFO / ISO 9660 layouts) in a temp
// folder and checks what dvd::probe() says.      g++ -std=c++17 -Wall -Wextra -o dvd_test dvd_test.cpp && ./dvd_test
#include "dvd_info.h"

#include <iostream>
#include <cstdlib>

namespace fs = std::filesystem;

static int g_fail = 0;
#define CHECK(c) do { if (!(c)) { ++g_fail; std::cout << "FAIL line " << __LINE__ << ": " #c << std::endl; } } while (0)

static void put16(std::string& b, size_t o, unsigned v) { b[o] = char(v >> 8); b[o + 1] = char(v); }
static void put32(std::string& b, size_t o, unsigned v) { put16(b, o, v >> 16); put16(b, o + 2, v & 0xFFFF); }
static unsigned bcdOf(int v) { return unsigned((v / 10) << 4 | (v % 10)); }

struct T { int vts, ttn, chapters, angles; };

static std::string makeVmg(const std::vector<T>& titles, int nVts, bool menuTables) {
    std::string b(4096, '\0');
    std::memcpy(&b[0], "DVDVIDEO-VMG", 12);
    put16(b, 0x3E, nVts);
    put32(b, 0xC4, 1);                      // TT_SRPT in sector 1
    put32(b, 0xC8, menuTables ? 2 : 0);     // VMGM_PGCI_UT (only the pointer matters here)
    put16(b, 2048, unsigned(titles.size()));
    for (size_t i = 0; i < titles.size(); ++i) {
        const size_t e = 2048 + 8 + i * 12;
        b[e] = 0x3C; b[e + 1] = char(titles[i].angles);
        put16(b, e + 2, titles[i].chapters);
        b[e + 6] = char(titles[i].vts); b[e + 7] = char(titles[i].ttn);
    }
    return b;
}

// secs[i] = playing time of title number i+1.  entryFlags: write the "entry PGC of title n" byte; ptt: write VTS_PTT_SRPT (title -> PGC).
static std::string makeVts(const std::vector<int>& secs, bool menuTables, int extraPgcSecs = 0, bool entryFlags = true, bool ptt = true) {
    std::string b(2048 * 4 + 0x400 + secs.size() * 0x100, '\0');
    std::memcpy(&b[0], "DVDVIDEO-VTS", 12);
    put32(b, 0xCC, 1);
    put32(b, 0xD0, menuTables ? 2 : 0);
    put32(b, 0xC8, ptt ? 3 : 0);
    const size_t base = 2048;
    const size_t total = secs.size() + (extraPgcSecs ? 1 : 0);
    put16(b, base, unsigned(total));
    for (size_t i = 0; i < total; ++i) {
        const bool extra = i >= secs.size();
        const size_t srp = base + 8 + i * 8, pgcOff = 8 + total * 8 + i * 0x100;
        b[srp] = (extra || !entryFlags) ? char(0x00) : char(0x80 | int(i + 1));
        put32(b, srp + 4, unsigned(pgcOff));
        const int s = extra ? extraPgcSecs : secs[i];
        const size_t pgc = base + pgcOff;
        b[pgc + 4] = char(bcdOf(s / 3600)); b[pgc + 5] = char(bcdOf((s % 3600) / 60)); b[pgc + 6] = char(bcdOf(s % 60)); b[pgc + 7] = char(0xC0);
    }
    if (ptt) {                                                  // VTS_PTT_SRPT in sector 3: title t has (t+1) chapters, the first one in PGC t+1
        const size_t pb = 3 * 2048;
        const size_t n = secs.size();
        put16(b, pb, unsigned(n));
        size_t off = 8 + n * 4;
        for (size_t t = 0; t < n; ++t) {
            put32(b, pb + 8 + t * 4, unsigned(off));
            for (size_t c = 0; c <= t; ++c) { put16(b, pb + off + c * 4, unsigned(t + 1)); put16(b, pb + off + c * 4 + 2, unsigned(c + 1)); }
            off += (t + 1) * 4;
        }
        put32(b, pb + 4, unsigned(off - 1));
    }
    return b;
}

static void write(const fs::path& p, const std::string& data) {
    fs::create_directories(p.parent_path());
    std::ofstream(p, std::ios::binary) << data;
}

// A test disc: 2 title sets. Title 1 = 1:52:30 (28 chapters), title 2 = 5:10 (a trailer), title 3 = 0:42:00 in set 2.
static std::vector<std::pair<std::string, std::string>> discFiles(bool menuVob, bool menuTables = true) {
    std::vector<std::pair<std::string, std::string>> f;
    f.push_back({"VIDEO_TS.IFO", makeVmg({{1, 1, 28, 1}, {1, 2, 3, 1}, {2, 1, 8, 2}}, 2, menuTables)});
    f.push_back({"VIDEO_TS.BUP", makeVmg({{1, 1, 28, 1}, {1, 2, 3, 1}, {2, 1, 8, 2}}, 2, menuTables)});
    if (menuVob) f.push_back({"VIDEO_TS.VOB", std::string(5000, 'M')});
    f.push_back({"VTS_01_0.IFO", makeVts({6750, 310}, true, 99999)});
    f.push_back({"VTS_01_0.VOB", std::string(3000, 'm')});
    f.push_back({"VTS_01_1.VOB", std::string(9000, 'v')});
    f.push_back({"VTS_02_0.IFO", makeVts({2520}, false)});
    f.push_back({"VTS_02_1.VOB", std::string(7000, 'v')});
    return f;
}

// ISO 9660 writer: PVD at sector 16, root dir, VIDEO_TS dir, then the file data.
static void dirRec(std::string& out, const std::string& name, unsigned lba, unsigned size, bool dir) {
    const size_t nlen = name.size();
    size_t len = 33 + nlen; if (len % 2) ++len;
    std::string r(len, '\0');
    r[0] = char(len);
    for (int i = 0; i < 4; ++i) { r[2 + i] = char(lba >> (8 * i)); r[6 + i] = char(lba >> (24 - 8 * i)); r[10 + i] = char(size >> (8 * i)); r[14 + i] = char(size >> (24 - 8 * i)); }
    r[25] = dir ? 2 : 0; r[28] = 1; r[31] = 1; r[32] = char(nlen);
    std::memcpy(&r[33], name.data(), nlen);
    out += r;
}
static void makeIso(const fs::path& iso, const std::vector<std::pair<std::string, std::string>>& files, bool withVideoTs, const std::string& label) {
    std::string img(20 * 2048, '\0');
    const unsigned rootLba = 18, vtsLba = 19;
    std::string pvd(2048, '\0');
    pvd[0] = 1; std::memcpy(&pvd[1], "CD001", 5); pvd[6] = 1;
    std::string lab = label; lab.resize(32, ' ');
    std::memcpy(&pvd[40], lab.data(), 32);
    std::string rootRec;
    dirRec(rootRec, std::string(1, '\0'), rootLba, 2048, true);
    std::memcpy(&pvd[156], rootRec.data(), std::min<size_t>(34, rootRec.size()));
    std::memcpy(&img[16 * 2048], pvd.data(), 2048);
    std::string term(2048, '\0'); term[0] = char(255); std::memcpy(&term[1], "CD001", 5); term[6] = 1;
    std::memcpy(&img[17 * 2048], term.data(), 2048);

    std::string root, vts, data;
    dirRec(root, std::string(1, '\0'), rootLba, 2048, true);
    dirRec(root, std::string(1, '\1'), rootLba, 2048, true);
    if (withVideoTs) dirRec(root, "VIDEO_TS", vtsLba, 2048, true); else dirRec(root, "OTHER", vtsLba, 2048, true);
    dirRec(vts, std::string(1, '\0'), vtsLba, 2048, true);
    dirRec(vts, std::string(1, '\1'), rootLba, 2048, true);
    unsigned lba = 20;
    for (const auto& f : files) {
        const unsigned secs = unsigned((f.second.size() + 2047) / 2048);
        dirRec(vts, f.first + ";1", lba, unsigned(f.second.size()), false);
        std::string padded = f.second; padded.resize(size_t(secs) * 2048, '\0');
        data += padded;
        lba += secs;
    }
    root.resize(2048, '\0'); vts.resize(2048, '\0');
    std::memcpy(&img[18 * 2048], root.data(), 2048);
    std::memcpy(&img[19 * 2048], vts.data(), 2048);
    img += data;
    write(iso, img);
}

int main() {
    const fs::path tmp = fs::temp_directory_path() / "pek_dvd_test";
    fs::remove_all(tmp);

    // 1. Folder disc with a menu
    {
        const fs::path root = tmp / "Movie (1999)";
        for (auto& f : discFiles(true)) write(root / "VIDEO_TS" / f.first, f.second);
        CHECK(dvd::isDiscFolder(root.string()));
        CHECK(dvd::isDiscPath(root.string()));
        dvd::Info i = dvd::probe(root.string());
        CHECK(i.ok && !i.iso && i.detailsKnown);
        CHECK(i.device == root.string());
        CHECK(i.hasMenu && i.hasTitleMenus);
        CHECK(i.titles.size() == 3);
        CHECK(i.main == 1);
        CHECK(i.titles[0].seconds == 6750 && i.titles[0].chapters == 28 && i.titles[0].vts == 1 && i.titles[0].ttn == 1);
        CHECK(i.titles[1].seconds == 310 && i.titles[1].ttn == 2);           // the 99999 s non-entry PGC must not leak in
        CHECK(i.titles[2].seconds == 2520 && i.titles[2].angles == 2 && i.titles[2].vts == 2);
        CHECK(dvd::clock(6750) == "1:52:30" && dvd::clock(310) == "5:10" && dvd::clock(0) == "");
        const std::string j = dvd::toJson(i);
        CHECK(j.find("\"hasMenu\":true") != std::string::npos && j.find("\"main\":1") != std::string::npos);
        std::cout << j << std::endl;
    }
    // 2. lower-case names (FAT / exFAT rips)
    {
        const fs::path root = tmp / "lower";
        for (auto& f : discFiles(true)) {
            std::string n = f.first; for (auto& c : n) c = char(std::tolower((unsigned char)c));
            write(root / "video_ts" / n, f.second);
        }
        dvd::Info i = dvd::probe(root.string());
        CHECK(i.ok && i.detailsKnown && i.hasMenu && i.titles.size() == 3 && i.main == 1);
    }
    // 3. the menu was stripped from the rip: tables still point at it, but VIDEO_TS.VOB is gone
    {
        const fs::path root = tmp / "nomenu";
        for (auto& f : discFiles(false)) write(root / "VIDEO_TS" / f.first, f.second);
        dvd::Info i = dvd::probe(root.string());
        CHECK(i.ok && i.detailsKnown && !i.hasMenu && i.titles.size() == 3);
    }
    // 3b. no menu tables at all
    {
        const fs::path root = tmp / "notables";
        for (auto& f : discFiles(true, false)) write(root / "VIDEO_TS" / f.first, f.second);
        CHECK(!dvd::probe(root.string()).hasMenu);
    }
    // 4. the folder IS VIDEO_TS (files straight inside)
    {
        const fs::path root = tmp / "VIDEO_TS";
        for (auto& f : discFiles(true)) write(root / f.first, f.second);
        dvd::Info i = dvd::probe(root.string());
        CHECK(i.ok && i.detailsKnown && i.device == root.string() && i.titles.size() == 3);
    }
    // 5. not a DVD
    {
        const fs::path root = tmp / "plain";
        write(root / "movie.mkv", "x");
        CHECK(!dvd::isDiscFolder(root.string()));
        CHECK(!dvd::probe(root.string()).ok);
        CHECK(dvd::toJson(dvd::probe(root.string())) == "{\"dvd\":false}");
        CHECK(!dvd::probe((root / "movie.mkv").string()).ok);
        CHECK(!dvd::isDiscPath((root / "movie.mkv").string()));
    }
    // 6. .iso with the same content
    {
        const fs::path iso = tmp / "Some Disc (2004).iso";
        makeIso(iso, discFiles(true), true, "SOME_DISC");
        CHECK(dvd::isIsoName(iso.string()) && dvd::isDiscIso(iso.string()) && dvd::isDiscPath(iso.string()));
        dvd::Info i = dvd::probe(iso.string());
        CHECK(i.ok && i.iso && i.detailsKnown);
        CHECK(i.device == iso.string() && i.label == "SOME_DISC");
        CHECK(i.hasMenu && i.hasTitleMenus && i.titles.size() == 3 && i.main == 1);
        CHECK(i.titles[0].seconds == 6750 && i.titles[2].seconds == 2520);
    }
    // 7. .iso that is not a DVD (a data disc), and a file that is not an ISO at all
    {
        const fs::path iso = tmp / "data.iso";
        makeIso(iso, discFiles(true), false, "DATA");
        CHECK(!dvd::isDiscIso(iso.string()) && !dvd::probe(iso.string()).ok);
        write(tmp / "fake.iso", std::string(100000, 'z'));
        CHECK(!dvd::isDiscIso((tmp / "fake.iso").string()));
        CHECK(!dvd::isDiscIso((tmp / "missing.iso").string()));
    }
    // 8. IFO damaged: still a DVD (so it can be played), tables unknown; and BUP rescues a damaged IFO
    {
        const fs::path root = tmp / "damaged";
        write(root / "VIDEO_TS" / "VIDEO_TS.IFO", std::string(3000, 'q'));
        write(root / "VIDEO_TS" / "VTS_01_1.VOB", std::string(100, 'v'));
        dvd::Info i = dvd::probe(root.string());
        CHECK(i.ok && !i.detailsKnown && i.titles.empty() && i.main == 0);
        const fs::path root2 = tmp / "bup";
        for (auto& f : discFiles(true)) write(root2 / "VIDEO_TS" / f.first, f.second);
        write(root2 / "VIDEO_TS" / "VIDEO_TS.IFO", std::string(3000, 'q'));
        dvd::Info j = dvd::probe(root2.string());
        CHECK(j.ok && j.detailsKnown && j.titles.size() == 3);
    }
    // 9. a single oversized / truncated table must not crash
    {
        const fs::path root = tmp / "truncated";
        std::string vmg = makeVmg({{1, 1, 5, 1}}, 1, true);
        put16(vmg, 2048, 99);                                  // claims 99 titles, holds 1
        vmg.resize(2048 + 8 + 12 * 3);                         // and is cut short
        write(root / "VIDEO_TS" / "VIDEO_TS.IFO", vmg);
        dvd::Info i = dvd::probe(root.string());
        CHECK(i.ok);
    }

    // 10. only one of the two ways to find a title's PGC is on the disc: both must give the same lengths
    for (int mode = 0; mode < 2; ++mode) {
        const fs::path root = tmp / (mode ? "ptt-only" : "entry-only");
        write(root / "VIDEO_TS" / "VIDEO_TS.IFO", makeVmg({{1, 1, 0, 1}, {1, 2, 0, 1}}, 1, false));
        write(root / "VIDEO_TS" / "VTS_01_0.IFO", makeVts({4000, 900}, false, 50000, /*entryFlags=*/mode == 0, /*ptt=*/mode == 1));
        dvd::Info i = dvd::probe(root.string());
        CHECK(i.ok && i.detailsKnown && i.titles.size() == 2);
        CHECK(i.titles[0].seconds == 4000 && i.titles[1].seconds == 900 && i.main == 1);
        CHECK(!i.hasMenu && !i.hasTitleMenus);
        if (mode == 1) CHECK(i.titles[0].chapters == 1 && i.titles[1].chapters == 2);   // the disc's title table said 0: counted from VTS_PTT_SRPT
    }

    fs::remove_all(tmp);
    std::cout << (g_fail ? "FAILED" : "all dvd tests passed") << std::endl;
    return g_fail ? 1 : 0;
}
