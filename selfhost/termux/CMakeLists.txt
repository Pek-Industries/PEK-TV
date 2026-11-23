# PEK Server for Android, run in Termux. Same program as selfhost/linux (main.cpp is shared; Android bits are under __ANDROID__),
# cross-compiled with the Android NDK so nobody builds anything on the phone. OpenSSL and SQLite are linked in, and libc++ is
# static, so the only thing it needs from the phone is Android's own libc. Used by selfhost/termux/build.sh:
#   cmake -S selfhost/termux -B build/termux-arm64-v8a -G Ninja \
#     -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=26 \
#     -DANDROID_STL=c++_static -DCMAKE_BUILD_TYPE=Release [-DPEK_SERVER_VERSION=2.2.8]
# Inputs made by the app's own scripts: android/openssl/<abi> (android/scripts/build-openssl.sh), android/sqlite (fetch-sqlite.sh).
cmake_minimum_required(VERSION 3.18)
project(pek_selfhost_termux C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT ANDROID)
    message(FATAL_ERROR "Configure this with the Android NDK toolchain (see the top of this file). For a PC or server use selfhost/linux.")
endif()

set(REPO ${CMAKE_CURRENT_SOURCE_DIR}/../..)
set(BACKEND ${REPO}/backend)
set(PEK_SERVER_VERSION "dev" CACHE STRING "Version printed at start-up")

set(OPENSSL_ROOT ${REPO}/android/openssl/${ANDROID_ABI})
if(NOT EXISTS ${OPENSSL_ROOT}/lib/libssl.a)
    message(FATAL_ERROR "OpenSSL for ${ANDROID_ABI} is missing: run android/scripts/build-openssl.sh")
endif()
set(SQLITE_DIR ${REPO}/android/sqlite)
if(NOT EXISTS ${SQLITE_DIR}/sqlite3.c)
    message(FATAL_ERROR "SQLite is missing: run android/scripts/fetch-sqlite.sh")
endif()

add_library(pek_sqlite STATIC ${SQLITE_DIR}/sqlite3.c)
target_include_directories(pek_sqlite PUBLIC ${SQLITE_DIR})
target_compile_definitions(pek_sqlite PRIVATE SQLITE_THREADSAFE=1 SQLITE_OMIT_LOAD_EXTENSION=1 SQLITE_DEFAULT_MEMSTATUS=0)

add_executable(pek-server
    ${CMAKE_CURRENT_SOURCE_DIR}/../linux/main.cpp
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
target_include_directories(pek-server PRIVATE ${BACKEND} ${OPENSSL_ROOT}/include)
target_compile_definitions(pek-server PRIVATE CPPHTTPLIB_OPENSSL_SUPPORT _FILE_OFFSET_BITS=64 PEK_SERVER_VERSION="${PEK_SERVER_VERSION}")
target_compile_options(pek-server PRIVATE -Wno-deprecated-declarations)

# The pinned official plugin-signing keys, same parsing as the other builds (server.cpp needs PEK_OFFICIAL_KEYS).
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

target_link_libraries(pek-server PRIVATE pek_sqlite ${OPENSSL_ROOT}/lib/libssl.a ${OPENSSL_ROOT}/lib/libcrypto.a log)
# -s: strip (smaller download). 16 KB pages: Android 15+ devices may use them; harmless elsewhere.
target_link_options(pek-server PRIVATE -s -Wl,-z,max-page-size=16384)
