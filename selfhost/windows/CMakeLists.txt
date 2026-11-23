# PEK Server (self-hosted, Windows): the same C++ server as the apps (backend/), as a stand-alone program with no window.
# Built with the MSYS2 clang toolchain (CLANG64 for x64, CLANGARM64 for ARM64), exactly like windows/backend/CMakeLists.txt.
#   cmake -S selfhost/windows -B build/selfhost -G Ninja -DCMAKE_BUILD_TYPE=Release [-DPEK_SERVER_VERSION=2.2.8]
cmake_minimum_required(VERSION 3.18)
project(pek_selfhost C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(BACKEND ${CMAKE_CURRENT_SOURCE_DIR}/../../backend)
set(COMPAT  ${CMAKE_CURRENT_SOURCE_DIR}/../../windows/backend/compat)
set(PEK_SERVER_VERSION "dev" CACHE STRING "Version printed at start-up")

find_package(OpenSSL REQUIRED)
find_package(SQLite3 REQUIRED)

add_executable(pek-server
    main.cpp
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
target_include_directories(pek-server PRIVATE ${BACKEND} ${COMPAT})
target_compile_definitions(pek-server PRIVATE CPPHTTPLIB_OPENSSL_SUPPORT _WIN32_WINNT=0x0A00 NOMINMAX WIN32_LEAN_AND_MEAN
    PEK_SERVER_VERSION="${PEK_SERVER_VERSION}")
target_compile_options(pek-server PRIVATE -include ${COMPAT}/pek_posix.h -Wno-deprecated-declarations)

# The pinned official plugin-signing keys, same parsing as windows/backend/CMakeLists.txt (server.cpp needs PEK_OFFICIAL_KEYS).
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
target_compile_definitions(pek-server PRIVATE PEK_OFFICIAL_KEYS="${PEK_KEYS}")

# UTF-8 as the process code page (file names with accents / other alphabets), through the same manifest the app uses.
# If the toolchain has no resource compiler the program still builds; it then warns at start-up when the code page is not UTF-8.
include(CheckLanguage)
check_language(RC)
if(CMAKE_RC_COMPILER)
    enable_language(RC)
    configure_file(pek-server.rc.in ${CMAKE_BINARY_DIR}/pek-server.rc @ONLY)
    target_sources(pek-server PRIVATE ${CMAKE_BINARY_DIR}/pek-server.rc)
    message(STATUS "PEK: UTF-8 manifest embedded")
else()
    message(WARNING "PEK: no resource compiler found, building without the UTF-8 manifest")
endif()

if(TARGET SQLite3::SQLite3)
    set(PEK_SQLITE_TARGET SQLite3::SQLite3)   # newer CMake name
else()
    set(PEK_SQLITE_TARGET SQLite::SQLite3)
endif()
target_link_libraries(pek-server PRIVATE OpenSSL::SSL OpenSSL::Crypto ${PEK_SQLITE_TARGET} ws2_32 iphlpapi crypt32 bcrypt)
# libc++ is linked in; OpenSSL and SQLite stay DLLs (collect-deps.sh ships them next to the exe). -municode: the program starts at wmain (UTF-16 arguments).
target_link_options(pek-server PRIVATE -static -municode)
