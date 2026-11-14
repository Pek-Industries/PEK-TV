# The PEK TV server (backend/) built as pek_server.dll for Windows: the counterpart of android/app/src/main/cpp/CMakeLists.txt.
# Built with the MSYS2 clang toolchain (CLANG64 for x64, CLANGARM64 for ARM64), the same compiler family the Android NDK uses,
# so the shared backend sources compile as they are. See WINDOWS.md and .github/workflows/build_windows.yml.
#   cmake -S windows/backend -B build/backend -G Ninja -DCMAKE_BUILD_TYPE=Release [-DPEK_TORRENT=ON]
cmake_minimum_required(VERSION 3.18)
project(pek_server C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(BACKEND ${CMAKE_CURRENT_SOURCE_DIR}/../../backend)
set(COMPAT  ${CMAKE_CURRENT_SOURCE_DIR}/compat)

find_package(OpenSSL REQUIRED)
find_package(SQLite3 REQUIRED)

add_library(pek_server SHARED
    dll_entry.cpp
    ${BACKEND}/server.cpp
    ${BACKEND}/media_scanner.cpp
    ${BACKEND}/playback.cpp
    ${BACKEND}/music.cpp
    ${BACKEND}/music_tags.cpp
    ${BACKEND}/discovery.cpp
    ${BACKEND}/vfs.cpp
    ${BACKEND}/vfs_ftp.cpp
    ${BACKEND}/vfs_http.cpp
    ${BACKEND}/torrent.cpp
    ${BACKEND}/torrent_routes.cpp
)
set_target_properties(pek_server PROPERTIES PREFIX "")
target_include_directories(pek_server PRIVATE ${BACKEND} ${COMPAT})
target_compile_definitions(pek_server PRIVATE CPPHTTPLIB_OPENSSL_SUPPORT _WIN32_WINNT=0x0A00 NOMINMAX WIN32_LEAN_AND_MEAN)
target_compile_options(pek_server PRIVATE -include ${COMPAT}/pek_posix.h -Wno-deprecated-declarations)

# The pinned official plugin-signing keys, same parsing as the Android build (backend/pek_official_keys.txt).
file(STRINGS ${BACKEND}/pek_official_keys.txt PEK_KEY_LINES REGEX "^[0-9a-fA-F][0-9a-fA-F]+")
set(PEK_KEYS "")
foreach(line ${PEK_KEY_LINES})
    string(REGEX MATCH "^[0-9a-fA-F]+" k "${line}")
    if(k MATCHES "^[0-9a-fA-F]{64}$")
        if(PEK_KEYS STREQUAL "")
            set(PEK_KEYS "${k}")
        else()
            set(PEK_KEYS "${PEK_KEYS},${k}")
        endif()
    endif()
endforeach()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${BACKEND}/pek_official_keys.txt)
target_compile_definitions(pek_server PRIVATE PEK_OFFICIAL_KEYS="${PEK_KEYS}")

target_link_libraries(pek_server PRIVATE OpenSSL::SSL OpenSSL::Crypto SQLite::SQLite3 ws2_32 iphlpapi crypt32 bcrypt)

# Torrent streaming (libtorrent-rasterbar from MSYS2). Off unless asked: the torrent routes still exist and say "not available".
option(PEK_TORRENT "Build in torrent streaming (libtorrent)" OFF)
if(PEK_TORRENT)
    find_package(LibtorrentRasterbar CONFIG REQUIRED)
    target_compile_definitions(pek_server PRIVATE PEK_TORRENT)
    target_link_libraries(pek_server PRIVATE LibtorrentRasterbar::torrent-rasterbar)
    message(STATUS "PEK: torrent streaming ON (libtorrent)")
else()
    message(STATUS "PEK: torrent streaming OFF")
endif()

# SMB (libsmb2) and NFS (libnfs) are not built on Windows yet: the app then says "no SMB support" / "no NFS support" for those
# network folder types, exactly as an Android build without those libraries does. FTP, WebDAV and DLNA work.

# One self-contained DLL: no libc++ / OpenSSL / SQLite DLLs to ship next to it.
target_link_options(pek_server PRIVATE -static)
