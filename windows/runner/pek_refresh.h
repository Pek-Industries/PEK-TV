// Which screen refresh rate suits a video? No Windows dependencies, so pek_refresh_test.cpp checks it on any machine:
//   g++ -std=c++17 pek_refresh_test.cpp -o t && ./t
// Android does the same job in MpvController.applyFrameRate (a mode whose rate is the video's rate times a whole number).
// Windows only lists WHOLE hertz (a 23.976 Hz mode shows up as 24, 59.94 as 60), so a mode is accepted when it is within about
// one percent of fps * n instead of the 0.2 percent Android uses.
#pragma once
#include <cmath>
#include <vector>

namespace pek {

// [fps]       the video's frame rate (container-fps from mpv)
// [currentHz] the rate the screen runs at now
// [modes]     the whole-hertz rates the screen offers at its current size
// Returns the rate to switch to, or 0 when there is nothing to do: the video has no usable rate, no mode matches, or the screen
// already runs at the best match.
inline int PickRefreshHz(double fps, int currentHz, const std::vector<int>& modes) {
  if (!(fps >= 10.0 && fps <= 120.0)) return 0;   // also rejects NaN and 0
  constexpr double kMaxRelErr = 0.012;            // whole-hertz rounding: 23.976 -> 24 is 0.1 %, 24 -> 25 is 4 %
  constexpr double kTie = 0.002;                  // errors this close are a tie: the smaller multiple wins (24 over 72)
  int best = 0, bestN = 0;
  double bestErr = 0;
  for (int hz : modes) {
    if (hz < 20) continue;                         // 0 / 1 mean "driver default" on Windows
    for (int n = 1; n <= 5; n++) {
      const double target = fps * n;
      const double err = std::fabs(hz - target) / target;
      if (err > kMaxRelErr) continue;
      const bool better = best == 0 || err < bestErr - kTie || (std::fabs(err - bestErr) <= kTie && n < bestN);
      if (better) { best = hz; bestErr = err; bestN = n; }
    }
  }
  if (best == 0 || best == currentHz) return 0;
  // The screen already runs at a whole multiple of the video's rate (30 fps on 60 Hz): leave it, a mode change blanks the screen.
  if (currentHz >= 20)
    for (int n = 1; n <= 5; n++)
      if (std::fabs(currentHz - fps * n) / (fps * n) <= kMaxRelErr) return 0;
  return best;
}

}  // namespace pek
