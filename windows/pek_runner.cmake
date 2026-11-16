# Appended to the Flutter-generated windows/runner/CMakeLists.txt by windows/scripts/prepare-flutter-host.sh.
# Adds the PEK host (channels, server loader, Python host, libmpv player) to the runner.
target_sources(${BINARY_NAME} PRIVATE "pek_host.cpp" "pek_mpv.cpp" "pek_display.cpp" "pek_media.cpp" "pek_discord.cpp" "pek_navsound.cpp")
# The PEK sources are not held to the template's warnings-as-errors rule (/W4 /WX).
set_source_files_properties("pek_host.cpp" "pek_mpv.cpp" "pek_display.cpp" "pek_media.cpp" "pek_discord.cpp" "pek_navsound.cpp" PROPERTIES COMPILE_OPTIONS "/W3;/WX-;/utf-8")
# pek_media.cpp uses C++/WinRT (SystemMediaTransportControls: media keys and the now-playing tile); its headers want standard conformance.
set_source_files_properties("pek_media.cpp" PROPERTIES COMPILE_OPTIONS "/W3;/WX-;/utf-8;/permissive-")
# Newer MSVC (Visual Studio 18 on the runners) turns <experimental/coroutine>, which C++/WinRT pulls in under the template's C++17,
# into a hard error (STL1011). The error text itself names this switch.
set_source_files_properties("pek_media.cpp" PROPERTIES COMPILE_DEFINITIONS "_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS")
# pek_host.cpp / flutter_window.cpp use flutter::PluginRegistrarWindows. That class lives in the plugin wrapper library,
# which the template runner does not link (it only links flutter_wrapper_app), hence the unresolved PluginRegistrar symbols.
target_link_libraries(${BINARY_NAME} PRIVATE flutter_wrapper_plugin)
target_link_libraries(${BINARY_NAME} PRIVATE "bcrypt.lib" "shell32.lib" "ole32.lib" "sapi.lib" "advapi32.lib" "comdlg32.lib" "user32.lib" "gdi32.lib" "opengl32.lib" "windowsapp.lib" "winmm.lib")

# Discord Rich Presence (DISCORD.md). pek_discord.cpp is a no-op unless the Discord Social SDK for Windows is in windows/discord/
# (prepare-flutter-host.sh copies that folder next to this file as runner/discord/):
#   discord/include/discordpp.h + cdiscord.h    (the SDK's headers, the same for every CPU type; discordpp.h includes cdiscord.h)
#   discord/<x64|arm64>/discord_partner_sdk.lib  (import library)   discord/<x64|arm64>/discord_partner_sdk.dll  (shipped by stage-assets.sh)
# A CPU type without its own folder (e.g. arm64 when Discord ships no ARM64 build) just builds without Discord.
if(CMAKE_VS_PLATFORM_NAME STREQUAL "ARM64" OR CMAKE_SYSTEM_PROCESSOR MATCHES "ARM64|arm64|aarch64")
  set(PEK_DISCORD_ARCH "arm64")
else()
  set(PEK_DISCORD_ARCH "x64")
endif()
set(PEK_DISCORD_DIR "${CMAKE_CURRENT_SOURCE_DIR}/discord")
if(EXISTS "${PEK_DISCORD_DIR}/include/discordpp.h" AND EXISTS "${PEK_DISCORD_DIR}/include/cdiscord.h" AND EXISTS "${PEK_DISCORD_DIR}/${PEK_DISCORD_ARCH}/discord_partner_sdk.lib")
  target_compile_definitions(${BINARY_NAME} PRIVATE PEK_DISCORD_SDK)
  target_include_directories(${BINARY_NAME} PRIVATE "${PEK_DISCORD_DIR}/include")
  target_link_libraries(${BINARY_NAME} PRIVATE "${PEK_DISCORD_DIR}/${PEK_DISCORD_ARCH}/discord_partner_sdk.lib")
  message(STATUS "PEK: Discord Rich Presence ON (${PEK_DISCORD_ARCH})")
else()
  message(STATUS "PEK: Discord Rich Presence OFF (windows/discord/ has no SDK files for ${PEK_DISCORD_ARCH})")
endif()
