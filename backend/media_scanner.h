#ifndef MEDIA_SCANNER_H
#define MEDIA_SCANNER_H

#include <string>
#include <vector>
#include <mutex>
#include <cstdint>
#include <functional>
#include <map>
#include <chrono>
#include <atomic>
#include <memory>
#include "vfs.h"

namespace pekdb { class Db; }

enum class MediaKind {
    Movie,
    Episode,
    Unclassified   // neither container tags nor the filename/folder
                    // fallback could identify it — shown under "Unknown".
};

struct MediaEntry {
    std::string id;          // stable hash of path
    std::string path;
    std::string filename;
    uint64_t size_bytes = 0;
    int64_t mtime = 0;

    MediaKind kind = MediaKind::Unclassified;

    // Movie fields
    std::string title;
    int year = 0;

    // Episode fields
    std::string show_title;
    int season = 0;
    int episode = 0;

    // Runtime only (not persisted): a movie that is split over several files in one folder ("Movie (1999) - Disk1.mkv",
    // "Movie (1999) - Disk2.mkv"; also CD1 / Part 1 / Pt 1). part = 1, 2, ... for such a file (0 = an ordinary file) and
    // part_first = the id of its first part. Only the first part is listed as a movie; the player plays them one after the other.
    int part = 0;
    std::string part_first;

    // Runtime only (not persisted): true when kind/title/show came from
    // the filename/folder fallback rather than embedded tags. Used to
    // decide which entries are worth confirming against TMDb.
    bool guessed = false;
};

// Classifies video files in layers, cheapest and most reliable first:
//   1. Metadata embedded in the container (via ffprobe) — show /
//      season_number / episode_sort tags, or a title tag for movies.
//   2. Folder structure and cleaned-up filename — "Show/Season 3/",
//      S03E04, 3x04, "Movie Name (1999)" — only for files the tags
//      couldn't identify.
//   3. Optional TMDb confirmation of a *guessed* show name (see
//      setShowResolver) so "friends" becomes the official "Friends".
// Anything still unidentified comes back Unclassified ("Unknown").
//
// Media source folders are user-chosen at runtime (via the folder
// picker UI backed by listSubdirectories()/addMediaDir()) rather
// than hardcoded — persisted to sources_file_path so they survive a
// restart.
class MediaScanner {
public:
    // cache_file_path is where the old tab-separated cache lived (media_cache.tsv). The library now lives in a SQLite
    // database named library.db in the same folder; an old cache file is imported once, then renamed *.migrated.
    MediaScanner(std::string sources_file_path, std::string cache_file_path);
    ~MediaScanner();

    // Loads both the source folder list and the classified-file
    // cache from disk. Call once at startup.
    void loadFromDisk();

    // Walks the current source folders, runs ffprobe on new/changed
    // video files (by size+mtime), classifies each via container
    // tags, and persists the result. Safe to call repeatedly —
    // unchanged files are skipped without re-invoking ffprobe.
    // scan(true) is the light version used after adding a source: only the source folders that have no files in the
    // library yet are walked; every other folder keeps what it had. scan() (the Rescan button) walks everything.
    void scan(bool onlyNewSources = false);

    // True while any scan() is running or waiting for its turn (startup, /api/rescan, adding a source).
    bool isScanning() const { return active_scans_.load() > 0; }

    // Optional: maps a show name guessed from a filename/folder to the
    // official name (e.g. via TMDb). Return "" to keep the guess. Called
    // at most once per distinct guessed name per scan, on the scan thread,
    // so it may block on the network. The scanner itself stays network-free.
    using ShowResolver = std::function<std::string(const std::string&)>;
    void setShowResolver(ShowResolver resolver);

    // Called (on the scan thread, after the results are stored) at the end of every scan(). The music library uses it
    // to refresh itself; it must return quickly (start its own thread for anything slow).
    void setAfterScan(std::function<void()> callback);

    // --- Source folder management (the picker UI) ---
    // Validates the path is a real directory, adds it, and persists
    // the source list. Does NOT scan automatically — call scan()
    // afterward (typically in a background thread) if you want the
    // new folder picked up immediately.
    bool addMediaDir(const std::string& path);
    bool removeMediaDir(const std::string& path);
    std::vector<std::string> getMediaDirs();

    // Lists immediate subdirectories of dir_path, alphabetically,
    // skipping hidden (dotfile) folders — the data behind the
    // folder-picker screen. Returns false if dir_path doesn't exist
    // or isn't a directory.
    static bool listSubdirectories(const std::string& dir_path, std::vector<std::string>& out);

    // --- Results ---
    std::vector<MediaEntry> getMovies();
    std::vector<MediaEntry> getEpisodes();          // flat
    std::vector<MediaEntry> getUnclassified();      // the "Unknown" category
    bool findById(const std::string& id, MediaEntry& out);

    // The ids of every file of a movie that is split over several files, in playing order; empty for an ordinary file.
    // Any one of the ids can be asked about.
    std::vector<std::string> partsOf(const std::string& id);

    // --- What the user's own files say about a title (NFO plot + artwork next to the video) ---
    // Works for local folders and network sources (SMB, NFS, FTP, WebDAV, UPnP) alike. The detail screens and the
    // poster grid prefer these over a TMDb lookup; TMDb is only asked for whatever is still missing.
    //   NFO:      "<video>.nfo", "movie.nfo" (movie alone in its folder), "tvshow.nfo" (show folder)
    //   Movie art:   <video>-poster.jpg, <video>.jpg, then poster / folder / cover .jpg (movie alone in its folder)
    //   Show art:    poster / folder / cover / show .jpg in the show folder
    //   Episode art: <video>-thumb.jpg, <video>.jpg           (.jpg, .jpeg, .png and .webp are all accepted)
    // Results are remembered for a couple of minutes, and forgotten at every scan.
    struct Local {
        std::string title;   // the NFO <title>: the episode name for an episode, the show name for a show
        std::string plot;    // <plot>, or <outline> when there is no plot; "" = none
        std::string art;     // path or network URL of an image file; "" = none. Only ever read by readArtwork().
    };
    Local localMovie(const MediaEntry& entry);

    /// Called by the poster / synopsis / episode lookups. The background NFO reader (indexMetadata) waits a moment between
    /// batches while these are arriving, so a screenful of posters is answered before the reader takes the disk / network again.
    void noteInteractive() { last_interactive_ms_ = nowSteadyMs(); }
    Local localEpisode(const std::string& show, int season, int episode);
    Local localShow(const std::string& show);
    // Reads the image named by Local::art (local or network). False = too big / unreadable.
    static bool readArtwork(const std::string& art, std::string& bytes, std::string& mime);

    // --- Posters and synopses, looked up once and kept in the library database (table title_art) ---
    // The poster grid used to ask for every title's poster separately while the person scrolled (600 titles = 600 requests,
    // each reading the disk and/or asking TMDb). Now a background worker (server.cpp) looks every title up ONCE, in the
    // background, and stores the poster address + synopsis here; /api/movies and /api/shows send them along with the list, so
    // the grid needs no further requests and every later start is instant.
    struct Art { std::string poster, overview; };
    struct ArtJob { bool movie = true; std::string id; std::string title; int year = 0; bool refresh = false; bool aged = false; };   // aged: a TMDb poster that is simply old; it is checked again and only replaced when TMDb now says something different   // movie: id + title + year; show: title; refresh: already has a poster, its files changed
    static std::string artKey(bool movie, const std::string& idOrTitle);
    // key -> art, only titles that have a poster
    std::unordered_map<std::string, Art> artKnown();
    // Titles still to look up: never tried, tried without finding a poster more than a day ago, or already stored but marked
    // changed by artRecheck() (retried after 10 minutes when a try failed, e.g. offline). At most `limit`.
    std::vector<ArtJob> artPending(size_t limit);
    // Remembers a finished look-up (an empty poster = "tried, found nothing": asked again after a day).
    // `stamp` = localStamp() of the user's own files at that moment (what the poster / plot were taken from).
    void artStore(bool movie, const std::string& idOrTitle, const std::string& poster, const std::string& overview, const std::string& stamp);
    // Fix match: a title matched to a TMDb entry by hand. Its poster and synopsis are kept under the stamp "pin:<tmdb id>", which
    // the background worker, artRecheck() and every automatic artStore() leave alone, until artUnpin().
    struct Pin { std::string tmdb_id, name, poster, overview; int year = 0; };
    bool artPinned(bool movie, const std::string& idOrTitle, Pin& out);
    void artPin(bool movie, const std::string& idOrTitle, const Pin& pin);
    void artUnpin(bool movie, const std::string& idOrTitle);
    // A try that failed (offline ...) for a title that already has a poster: keeps the poster, asks again in 10 minutes.
    void artRetryLater(bool movie, const std::string& idOrTitle);
    // A re-check of an old TMDb poster found nothing different (or nothing at all): the stored poster stays, the next re-check is in 30 days.
    void artTouch(bool movie, const std::string& idOrTitle);
    // Like localStamp(), plus the title and year TMDb was asked about ("|t:" marks a title that was looked up on TMDb). A renamed
    // title, or a changed year, changes this stamp, so only that title is looked up again. Titles stored before this existed have no "|t:" and are left alone.
    static std::string tmdbStamp(const Local& local, const std::string& title, int year);
    // +1 whenever a stored poster or synopsis really changed (new, replaced or removed). The app watches it (/api/scan-status) and reads the lists again.
    int artChanges() const { return art_changes_.load(); }
    // What the user's own files say right now, as one short text: the artwork file (path, size, date) and a fingerprint of the
    // plot. A title whose stamp differs from the stored one has changed files (new poster.jpg, edited .nfo ...).
    static std::string localStamp(const Local& local);
    // Compares every stored title's current files with its stored stamp and marks the changed ones for a fresh look-up. Reads
    // the user's folders (not the internet); meant for the background worker, once after each scan.
    void artRecheck();
    int scanGeneration() const { return scan_generation_.load(); }   // +1 each time a scan finishes

    // --- Searching and browsing the library (SQLite) ---
    // What the NFO files say (genre, actors, directors, studio, collection, rating) is read after every scan and kept in
    // the database, so a search by actor, genre, year ... is one indexed query instead of a pass over every title.
    // Only titles with an NFO have those fields; the year and the title always work.
    struct SearchQuery {
        std::string type = "movies";       // "movies" or "shows"
        std::string q;                     // free text: every word must match a title, year, genre, actor, director, studio or collection
        std::string genre, actor, director, studio, collection;   // exact (case and accent insensitive) filters
        int year = 0;                      // exactly this year
        int decade = 0;                    // 1990 = 1990..1999
        std::string sort = "title";        // title | title_desc | year | year_asc | added | rating | runtime | runtime_asc
        int limit = 500;
        int offset = 0;
        // More filters. They read what the title's .nfo says (rating, runtime, mpaa); a title with no .nfo has none of these.
        std::string mpaa;                  // "PG-13" ... exact (case insensitive)
        double min_rating = 0;             // 0 = any; otherwise this or higher (0..10)
        int min_runtime = 0;               // minutes, 0 = no lower limit
        int max_runtime = 0;               // minutes, 0 = no upper limit
        int nfo = 0;                       // 0 = any, 1 = only titles that have a .nfo, 2 = only titles without one
    };
    // {"total":N,"movies":["<id>",...]}  or  {"total":N,"shows":["<show title>",...]}
    std::string searchJson(const SearchQuery& query);
    // {"indexing":{"done":a,"total":b},"genres":[{"name","count"}],"decades":[{"decade","count"}],"years":[{"year","count"}],
    //  "actors":[...],"directors":[...],"studios":[...]}   actorPrefix narrows the actor list (the picker's own search box).
    std::string facetsJson(const std::string& type, const std::string& actorPrefix, int limit);
    // Search-box drop-down: the best few titles for the free text in query.q (and any filter set on it), with their .nfo details.
    // type = "movies", "shows" or "both". The title is the .nfo's title when the title has one, else the file's.
    // {"items":[{"kind":"movie"|"show","id","title","year","rating","runtime","mpaa","studio","nfo":bool,"genres":[],"cast":[],
    //            "directors":[],"match":"Cast: Tom Hanks"}]}   "match" says why a title came up when its name is not what was typed.
    std::string suggestJson(const SearchQuery& query, const std::string& type, int limit);

private:
    struct SearchSql {
        bool shows = false;
        std::string from, where, order, key, year;
        std::vector<std::string> binds;
    };
    SearchSql buildSearchSql(const SearchQuery& query);
    std::string sources_file_path_;
    std::string cache_file_path_;
    std::vector<std::string> media_dirs_;
    std::vector<MediaEntry> entries_;
    std::mutex mutex_;
    ShowResolver show_resolver_;
    std::function<void()> after_scan_;
    std::map<std::string, std::string> resolved_names_;   // lowercase guess -> official name ("" = no match); only touched under scan_mutex_
    std::mutex local_mutex_;
    std::map<std::string, std::pair<std::chrono::steady_clock::time_point, Local>> local_cache_;   // "m:<id>" / "e:<show>|s|e" / "s:<show>"
    Local cachedLocal(const std::string& key, const std::function<Local()>& make);
    std::atomic<int> active_scans_{0};
    std::atomic<int> scan_generation_{0};
    std::atomic<int> art_changes_{0};
    std::mutex scan_mutex_;   // serializes scan() so overlapping scans (startup + POST /api/sources + /api/rescan) can't race on the cache file

    bool dirHasNomedia(const std::string& dir_path);
    bool isVideoFile(const std::string& extension);
    void scanDirectory(const std::string& dir_path, std::vector<MediaEntry>& found);

    // Network (smb://) sources. Returns false only when the share could not be
    // reached at all, so scan() can keep the old entries instead of wiping them
    // while a NAS is switched off. Files are classified from their names/folders
    // only (ffprobe can't open smb:// URLs).
    bool scanRemote(const std::string& root_url, std::vector<MediaEntry>& found);
    bool scanRemoteDir(vfs::Share& share, const vfs::Url& base, const std::string& rel,
                       std::vector<MediaEntry>& found, int depth);

    // Runs `ffprobe -show_format -print_format json` on the file and
    // fills in kind/title/year/show_title/season/episode from
    // whatever tags are present. Leaves kind == Unclassified if the
    // needed tags aren't there.
    static void probeAndClassify(MediaEntry& entry);

    // Fallback for files the tags couldn't identify (or tagged only with a
    // bare title but named like an episode): parses the filename and the
    // parent folders. media_roots are the user's source folders, never
    // treated as a show name. Sets entry.guessed on success.
    static void classifyFromFilename(MediaEntry& entry, const std::vector<std::string>& media_roots);

    // Works out MediaEntry::part / part_first for every movie in the list (run on each new list, before it is stored).
    static void groupParts(std::vector<MediaEntry>& list);

    static std::string makeId(const std::string& path);
    void persistSourcesToDisk();

    // ---- the library database (library.db) ----
    std::unique_ptr<pekdb::Db> db_;            // null = could not be opened: the app still works, it just rescans at every start
    std::string db_path_;
    std::atomic<int> index_done_{0}, index_total_{0};
    std::atomic<long long> last_interactive_ms_{0};
    static long long nowSteadyMs() {
        return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
    }
    void yieldToInteractive();                 // short pause (at most ~1.5 s) while poster lookups are being answered
    void openDb();                             // opens, creates the tables, imports an old media_cache.tsv once
    void persistToDb();                        // brings the media table in line with entries_ (one transaction)
    void indexMetadata();                      // reads NFO genres / people for titles that are new or whose NFO changed
};

#endif
