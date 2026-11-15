// Refresh-rate matching on Windows (Android: MpvController.applyFrameRate). Switches the screen the PEK window is on to a mode whose
// rate suits the film (24 / 23.976 fps -> 24 Hz, 25 -> 50 Hz ...) and puts it back afterwards. Call it on the UI thread only.
#pragma once
#include <windows.h>

#include <string>

namespace pek {

class DisplayRate {
 public:
  ~DisplayRate() { Reset(); }

  // Switches the screen [window] is on for a video of [fps] frames per second. Does nothing when no mode fits or the screen already
  // runs at a good rate. Same size and colour depth, only the refresh rate changes. The change is temporary (CDS_FULLSCREEN): Windows
  // itself restores the normal rate if the app is closed or crashes without calling Reset().
  void Apply(HWND window, double fps);

  // Back to the rate the person set in Windows. Safe to call when nothing was changed.
  void Reset();

  bool Changed() const { return changed_; }

 private:
  std::wstring device_;   // "\\.\DISPLAY1" of the screen that was switched
  bool changed_ = false;
};

}  // namespace pek
