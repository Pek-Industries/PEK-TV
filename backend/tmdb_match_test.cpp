// g++ -std=c++17 -o /tmp/tmdb_match_test tmdb_match_test.cpp && /tmp/tmdb_match_test
#include "tmdb_match.h"
#include <cstdio>
using namespace tmdbmatch;
static int fails = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); ++fails; } } while (0)

static const char* kMovies =
 "{\"page\":1,\"results\":[\n"
 "{\"id\":111,\"title\":\"Dredd\",\"original_title\":\"Dredd\",\"release_date\":\"2012-09-07\",\"popularity\":40.5,\"overview\":\"Karl Urban \\\"judge\\\".\",\"poster_path\":\"/a.jpg\"},\n"
 "{\"id\":222,\"title\":\"Judge Dredd\",\"original_title\":\"Judge Dredd\",\"release_date\":\"1995-06-30\",\"popularity\":30.1,\"overview\":\"Stallone.\",\"poster_path\":null},\n"
 "{\"id\":333,\"title\":\"Dredd\",\"original_title\":\"Dredd\",\"release_date\":\"1998-01-01\",\"popularity\":1.2,\"overview\":\"Short.\",\"poster_path\":\"/c.jpg\"}\n"
 "]}";

int main() {
    // parsing
    auto c = parseCandidates(kMovies, true);
    CHECK(c.size() == 3 && c[0].id == "111" && c[0].year == 2012 && c[1].poster_path.empty() && c[0].overview == "Karl Urban \"judge\".");
    CHECK(c[0].popularity > 40 && c[0].popularity < 41);

    // title similarity
    CHECK(titleSimilarity("The Office", "Office") == 1.0);
    CHECK(titleSimilarity("Law & Order", "Law and Order") == 1.0);
    CHECK(titleSimilarity("Friends", "Friends: The Reunion") < 1.0 && titleSimilarity("Friends", "Friends: The Reunion") < kStrongTitle);   // usable, but the plain "Friends" wins whenever it is a candidate
    CHECK(titleSimilarity("Lioness", "Special Ops: Lioness") >= kMinTitle && titleSimilarity("Special Ops Lioness", "Special Ops: Lioness") == 1.0);
    CHECK(titleSimilarity("Dredd", "Judge Dredd") < 0.8);
    CHECK(titleSimilarity("Dredd", "Frozen") < 0.3);
    // year / runtime / popularity
    CHECK(yearScore(2012, 2012) == 1.0 && yearScore(2012, 2013) == 0.7 && yearScore(2012, 2011) == 0.7 && yearScore(2012, 2014) == 0.0 && yearScore(0, 2012) < 0);
    CHECK(runtimeScore(95, 95) == 1.0 && runtimeScore(100, 95) == 1.0 && runtimeScore(180, 95) == 0.0 && runtimeScore(0, 95) < 0);
    CHECK(popularityScore(0) == 0 && popularityScore(100) == 1.0 && popularityScore(10) > 0.4 && popularityScore(-1) < 0);

    auto noEnrich = [](Candidate&) {};

    // 1. year decides between two "Dredd"s that TMDb lists in popularity order
    { Query q; q.title = "Dredd"; q.year = 1998; auto v = c; int i = pick(q, v, noEnrich); CHECK(i == 2); }
    { Query q; q.title = "Dredd"; q.year = 2012; auto v = c; int i = pick(q, v, noEnrich); CHECK(i == 0); }
    // 2. one year off still matches (file dated by festival year); two years off does not beat nothing: it is rejected
    { Query q; q.title = "Dredd"; q.year = 2013; auto v = c; int i = pick(q, v, noEnrich); CHECK(i == 0); }
    // 3. a first result that is a different title is never taken
    { Query q; q.title = "Frozen"; auto v = c; CHECK(pick(q, v, noEnrich) < 0); }
    // 4. no year: popularity breaks the tie between the two exact "Dredd"
    { Query q; q.title = "Dredd"; auto v = c; CHECK(pick(q, v, noEnrich) == 0); }
    // 5. runtime separates two same-year same-title films
    {
        std::vector<Candidate> v = parseCandidates(
            "{\"results\":[{\"id\":1,\"title\":\"Heat\",\"release_date\":\"1986-01-01\",\"popularity\":9},"
            "{\"id\":2,\"title\":\"Heat\",\"release_date\":\"1986-05-01\",\"popularity\":2}]}", true);
        Query q; q.title = "Heat"; q.year = 1986; q.runtime = 104;
        int asked = 0;
        int i = pick(q, v, [&](Candidate& x) { ++asked; x.runtime = x.id == "1" ? 60 : 105; });
        CHECK(i == 1 && asked == 2);
        Query q2 = q; q2.runtime = 0; asked = 0;
        CHECK(pick(q2, v, [&](Candidate&) { ++asked; }) == 0 && asked == 0);   // no runtime to compare: no details requested
    }
    // 6. a {tmdb-N} tag wins outright
    { Query q; q.title = "Dredd"; q.year = 2012; q.id_hint = "333"; auto v = c; CHECK(pick(q, v, noEnrich) == 2); }

    // 7. shows: the folder's episodes vote
    auto shows = parseCandidates(
        "{\"results\":["
        "{\"id\":71365,\"name\":\"Battlestar Galactica\",\"first_air_date\":\"2004-12-08\",\"popularity\":60},"
        "{\"id\":1972,\"name\":\"Battlestar Galactica\",\"first_air_date\":\"1978-09-17\",\"popularity\":20},"
        "{\"id\":9,\"name\":\"Battlestar Galactica\",\"first_air_date\":\"2003-12-08\",\"popularity\":5}]}", false);
    auto details = [](Candidate& x) {
        if (x.id == "71365") applyShowDetails(x, "{\"seasons\":[{\"season_number\":0,\"episode_count\":9},{\"season_number\":1,\"episode_count\":13},"
                                                  "{\"season_number\":2,\"episode_count\":20},{\"season_number\":3,\"episode_count\":20},{\"season_number\":4,\"episode_count\":22}]}");
        else if (x.id == "1972") applyShowDetails(x, "{\"seasons\":[{\"season_number\":1,\"episode_count\":24}]}");
        else applyShowDetails(x, "{\"seasons\":[{\"season_number\":1,\"episode_count\":2}]}");
    };
    { Query q; q.movie = false; q.title = "Battlestar Galactica";
      for (int e = 1; e <= 20; ++e) q.siblings.push_back({3, e});           // season 3, 20 episodes: only the 2004 series has that
      auto v = shows; int i = pick(q, v, details); CHECK(i >= 0 && v[i].id == "71365"); }
    { Query q; q.movie = false; q.title = "Battlestar Galactica";
      for (int e = 1; e <= 24; ++e) q.siblings.push_back({1, e});           // one season of 24: the 1978 series
      auto v = shows; int i = pick(q, v, details); CHECK(i >= 0 && v[i].id == "1972"); }
    { Query q; q.movie = false; q.title = "Battlestar Galactica";
      q.siblings = {{9, 1}, {9, 2}, {9, 3}};                                // nine seasons: no candidate has them
      auto v = shows; CHECK(pick(q, v, details) >= 0); }   // an exact title is kept even when no season count fits (TMDb may not list the newest season yet)
    { Query q; q.movie = false; q.title = "Battlestar Galactica"; q.siblings = {{0, 1}, {1, 1}, {1, 2}};   // a special does not vote
      auto v = shows; int i = pick(q, v, details); CHECK(i >= 0); }
    // 8. a failed details request leaves the vote undecided, not failed
    { Query q; q.movie = false; q.title = "Battlestar Galactica"; q.year = 1978; q.siblings = {{1, 1}};
      auto v = shows; int i = pick(q, v, noEnrich); CHECK(i >= 0 && v[i].id == "1972"); }
    // 9. details parsing
    { Candidate x; applyMovieDetails(x, "{\"id\":1,\"runtime\":142,\"title\":\"x\"}"); CHECK(x.runtime == 142);
      Candidate y; applyMovieDetails(y, "{\"runtime\":null}"); CHECK(y.runtime == 0); }

    std::printf(fails ? "%d FAILED\n" : "all ok\n", fails);
    return fails ? 1 : 0;
}
