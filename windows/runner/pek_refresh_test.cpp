// g++ -std=c++17 pek_refresh_test.cpp -o t && ./t
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "pek_refresh.h"

static int fails = 0;
#define CHECK(expr, want)                                                                      \
  do {                                                                                          \
    int got = (expr);                                                                           \
    if (got != (want)) { printf("FAIL line %d: %s = %d, wanted %d\n", __LINE__, #expr, got, want); fails++; } \
  } while (0)

int main() {
  using pek::PickRefreshHz;
  const std::vector<int> pc = {24, 30, 48, 50, 60, 72, 120};
  CHECK(PickRefreshHz(23.976, 60, pc), 24);     // film on a 60 Hz desktop -> 24
  CHECK(PickRefreshHz(24.0, 60, pc), 24);
  CHECK(PickRefreshHz(25.0, 60, pc), 50);       // PAL -> 50 (2 x 25)
  CHECK(PickRefreshHz(29.97, 60, pc), 0);       // 2 x 29.97 = 60: already right
  CHECK(PickRefreshHz(30.0, 60, pc), 0);
  CHECK(PickRefreshHz(59.94, 60, pc), 0);
  CHECK(PickRefreshHz(23.976, 24, pc), 0);      // already there
  CHECK(PickRefreshHz(23.976, 120, pc), 0);     // 5 x 24
  CHECK(PickRefreshHz(24.0, 60, {60}), 0);      // the screen has no 24 / 48 / 72 / 120 mode: nothing to switch to
  CHECK(PickRefreshHz(0.0, 60, pc), 0);
  CHECK(PickRefreshHz(-1.0, 60, pc), 0);
  CHECK(PickRefreshHz(1000.0, 60, pc), 0);
  CHECK(PickRefreshHz(25.0, 60, {0, 1, 60}), 0); // 0 / 1 = "default" rates are ignored
  CHECK(PickRefreshHz(24.0, 59, {23, 24, 59}), 24);
  CHECK(PickRefreshHz(23.976, 144, {24, 48, 60, 144}), 24);  // 144 is not a whole multiple of 24 within 5x
  if (fails) return 1;
  printf("pek_refresh: all checks passed\n");
  return 0;
}
