# Appended to the Flutter-generated windows/runner/CMakeLists.txt by windows/scripts/prepare-flutter-host.sh.
# Adds the PEK host (channels, server loader, Python host, libmpv player) to the runner.
target_sources(${BINARY_NAME} PRIVATE "pek_host.cpp" "pek_mpv.cpp")
# The PEK sources are not held to the template's warnings-as-errors rule (/W4 /WX).
set_source_files_properties("pek_host.cpp" "pek_mpv.cpp" PROPERTIES COMPILE_OPTIONS "/W3;/WX-;/utf-8")
target_link_libraries(${BINARY_NAME} PRIVATE "bcrypt.lib" "shell32.lib" "ole32.lib" "sapi.lib" "advapi32.lib" "comdlg32.lib" "user32.lib")
