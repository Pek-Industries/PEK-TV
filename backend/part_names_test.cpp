// g++ -std=c++17 -Wall -Wextra -o part_names_test part_names_test.cpp && ./part_names_test
#include "part_names.h"
#include <iostream>

static int g_fail = 0;
static void yes(const std::string& stem, const std::string& wantBase, int wantPart) {
    std::string b; int p = 0;
    if (!partname::split(stem, b, p) || b != wantBase || p != wantPart) { ++g_fail; std::cout << "FAIL (should split): " << stem << " -> [" << b << "] " << p << std::endl; }
}
static void no(const std::string& stem) {
    std::string b; int p = 0;
    if (partname::split(stem, b, p)) { ++g_fail; std::cout << "FAIL (should NOT split): " << stem << " -> [" << b << "] " << p << std::endl; }
}

int main() {
    yes("Gone With the Wind (1939) {imdb-tt0031381} - Disk1", "Gone With the Wind (1939) {imdb-tt0031381}", 1);
    yes("Gone With the Wind (1939) {imdb-tt0031381} - Disk2", "Gone With the Wind (1939) {imdb-tt0031381}", 2);
    yes("Movie (1999) - Disc 1", "Movie (1999)", 1);
    yes("Movie.1999.CD2", "Movie.1999", 2);
    yes("Movie 1999 cd 01", "Movie 1999", 1);
    yes("Movie_1999_part3", "Movie_1999", 3);
    yes("Movie (1999) [Part 2]", "Movie (1999)", 2);
    yes("Movie (1999) (pt1)", "Movie (1999)", 1);
    yes("Movie (1999) DVD2", "Movie (1999)", 2);
    no("Movie (1999)");
    no("Dune Part Two (2024)");
    no("Harry Potter and the Deathly Hallows - Part 1 (2010)");
    no("Script 1");
    no("Abcd1");
    no("Disk1");                        // nothing before the marker: that is the whole name
    no("Movie - Part 0");
    no("Movie - Part 100");
    std::cout << (g_fail ? "FAILED" : "all part-name tests passed") << std::endl;
    return g_fail ? 1 : 0;
}
