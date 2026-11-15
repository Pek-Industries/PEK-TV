# Appended to the Flutter-generated windows/runner/CMakeLists.txt by windows/scripts/prepare-flutter-host.sh.
# Adds the PEK host (channels, server loader, Python host, libmpv player) to the runner.
target_sources(${BINARY_NAME} PRIVATE "pek_host.cpp" "pek_mpv.cpp" "pek_display.cpp" "pek_media.cpp")
# The PEK sources are not held to the template's warnings-as-errors rule (/W4 /WX).
set_source_files_properties("pek_host.cpp" "pek_mpv.cpp" "pek_display.cpp" "pek_media.cpp" PROPERTIES COMPILE_OPTIONS "/W3;/WX-;/utf-8")
# pek_media.cpp uses C++/WinRT (SystemMediaTransportControls: media keys and the now-playing tile); its headers want standard conformance.
set_source_files_properties("pek_media.cpp" PROPERTIES COMPILE_OPTIONS "/W3;/WX-;/utf-8;/permissive-")
# pek_host.cpp / flutter_window.cpp use flutter::PluginRegistrarWindows. That class lives in the plugin wrapper library,
# which the template runner does not link (it only links flutter_wrapper_app), hence the unresolved PluginRegistrar symbols.
target_link_libraries(${BINARY_NAME} PRIVATE flutter_wrapper_plugin)
target_link_libraries(${BINARY_NAME} PRIVATE "bcrypt.lib" "shell32.lib" "ole32.lib" "sapi.lib" "advapi32.lib" "comdlg32.lib" "user32.lib" "gdi32.lib" "opengl32.lib" "windowsapp.lib")
