#ifndef PEK_PART_NAMES_H
#define PEK_PART_NAMES_H

// A movie split over several files ("Gone With the Wind (1939) - Disk1.mkv", "... - Disk2.mkv"): the file-name rule.
// The scanner groups files whose names differ only by this marker (media_scanner.cpp, MediaScanner::groupParts).

#include <regex>
#include <string>

namespace partname {

// "Gone With the Wind (1939) {imdb-tt0031381} - Disk1" -> base "Gone With the Wind (1939) {imdb-tt0031381}", part 1.
// The marker (cd / dvd / disc / disk / part / pt + a number) has to END the name and follow a separator, so "Part Two (2024)",
// "Harry Potter and the Deathly Hallows - Part 1 (2010)" and "Script 1" are not taken for parts.
inline bool split(const std::string& stem, std::string& base, int& part) {
    static const std::regex re(R"(^(.*?)[\s._\-\[\(]+(?:cd|dvd|dis[ck]|part|pt)[\s._\-]*0*([1-9][0-9]?)[\s\]\)]*$)",
                               std::regex::icase);
    std::smatch m;
    if (!std::regex_match(stem, m, re)) return false;
    base = m[1].str();
    while (!base.empty() && (base.back() == ' ' || base.back() == '.' || base.back() == '_' || base.back() == '-')) base.pop_back();
    if (base.empty()) return false;
    try { part = std::stoi(m[2].str()); } catch (...) { return false; }
    return part >= 1;
}

} // namespace partname

#endif
