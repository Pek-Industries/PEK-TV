#include "pek_display.h"

#include <cstdio>
#include <vector>

#include "pek_refresh.h"

namespace pek {

void DisplayRate::Apply(HWND window, double fps) {
  MONITORINFOEXW mi{};
  mi.cbSize = sizeof mi;
  if (!GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &mi)) return;
  const std::wstring device = mi.szDevice;
  if (changed_ && device != device_) Reset();   // the window moved to another screen: give the first one back

  DEVMODEW cur{};
  cur.dmSize = sizeof cur;
  if (!EnumDisplaySettingsExW(device.c_str(), ENUM_CURRENT_SETTINGS, &cur, 0)) return;

  // The rates this screen offers at its current size and colour depth (whole hertz; Windows does not list 23.976 separately).
  std::vector<int> rates;
  DEVMODEW m{};
  m.dmSize = sizeof m;
  for (DWORD i = 0; EnumDisplaySettingsExW(device.c_str(), i, &m, 0); i++) {
    if (m.dmPelsWidth != cur.dmPelsWidth || m.dmPelsHeight != cur.dmPelsHeight || m.dmBitsPerPel != cur.dmBitsPerPel) continue;
    if (m.dmDisplayOrientation != cur.dmDisplayOrientation) continue;
    if (m.dmDisplayFlags & DM_INTERLACED) continue;
    rates.push_back(static_cast<int>(m.dmDisplayFrequency));
  }

  const int hz = PickRefreshHz(fps, static_cast<int>(cur.dmDisplayFrequency), rates);
  if (hz <= 0) return;

  DEVMODEW want = cur;
  want.dmDisplayFrequency = static_cast<DWORD>(hz);
  want.dmFields |= DM_DISPLAYFREQUENCY;
  if (ChangeDisplaySettingsExW(device.c_str(), &want, nullptr, CDS_TEST, nullptr) != DISP_CHANGE_SUCCESSFUL) return;
  if (ChangeDisplaySettingsExW(device.c_str(), &want, nullptr, CDS_FULLSCREEN, nullptr) == DISP_CHANGE_SUCCESSFUL) {
    device_ = device;
    changed_ = true;
    fprintf(stderr, "PEK refresh rate: video %.3f fps -> %d Hz\n", fps, hz);
  }
}

void DisplayRate::Reset() {
  if (!changed_) return;
  changed_ = false;
  ChangeDisplaySettingsExW(device_.c_str(), nullptr, nullptr, 0, nullptr);   // the mode saved in Windows
  fprintf(stderr, "PEK refresh rate: back to the Windows setting\n");
}

}  // namespace pek
