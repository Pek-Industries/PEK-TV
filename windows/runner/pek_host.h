// The Windows host: everything FlutterHostActivity.kt, Boot.kt and the other Kotlin files do on Android, behind the same
// `pek/*` platform channels the Flutter UI calls (flutter_ui/lib/src). See WINDOWS.md.
#pragma once
#include <flutter/plugin_registrar_windows.h>
#include <windows.h>

namespace pek {

// Registers every channel, starts the C++ server (pek_server.dll) and the Python plugin host on a worker thread.
// [top] is the main window (dialogs, closing).
void StartHost(flutter::PluginRegistrarWindows* registrar, HWND top);

// Stops the Python host and the player. Safe to call more than once.
void StopHost();

}  // namespace pek
