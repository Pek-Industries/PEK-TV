
#ifndef SERVER_H
#define SERVER_H

#include <string>
#include <vector>
#include <functional>
#include "media_scanner.h"

class PekServer {
public:
    // Declare start with the plugin data provider callback parameter,
    // plus the MediaScanner backing /api/movies, /api/shows, and
    // /api/movie-details.
    static void start(int port, const std::string& plugins_dir,
                       const std::string& skins_dir,
                       std::function<std::vector<std::string>()> get_plugins,
                       MediaScanner* scanner,
                       const std::string& localToken = "");
    // localToken: when not empty, EVERY request (loopback included) must carry it, as the X-Pek-Token header or the
    // pek_t query parameter (the second one is for players and image loaders that cannot set headers). The Android app
    // makes a fresh random one on each launch and gives it only to its own Flutter UI and Python host, so another app on
    // the phone that finds 127.0.0.1:8080 gets 401 from every route.

    // Looks up a TV show name on TMDb and returns the official title, or
    // "" if there is no TMDB_API_KEY, no network, or no close match.
    // Pass to MediaScanner::setShowResolver().
    static std::string resolveShowName(const std::string& guess);
};

#endif
