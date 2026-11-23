# PEK Server (self-hosted, Linux): the same C++ server as the apps (backend/), as a stand-alone program with no window.
#   cmake -S selfhost/linux -B build/selfhost-linux -G Ninja -DCMAKE_BUILD_TYPE=Release [-DPEK_STATIC=ON] [-DPEK_SERVER_VERSION=2.2.8]
# PEK_STATIC=ON makes a fully static program (use it on Alpine / musl: one file that runs on any Linux distribution). See Dockerfile.
cmake_minimum_required(VERSION 3.18)
project(pek_selfhost C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(BACKEND ${CMAKE_CURRENT_SOURCE_DIR}/../../backend)
set(PEK_SERVER_VERSION "dev" CACHE STRING "Version printed at start-up")
option(PEK_STATIC "Fully static program (Alpine / musl)" OFF)

if(PEK_STATIC)
    set(CMAKE_FIND_LIBRARY_SUFFIXES .a)
    set(OPENSSL_USE_STATIC_LIBS ON)
endif()
find_package(OpenSSL REQUIRED)
find_package(SQLite3 REQUIRED)
find_package(Threads REQUIRED)

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
target_include_directories(pek-server PRIVATE ${BACKEND})
target_compile_definitions(pek-server PRIVATE CPPHTTPLIB_OPENSSL_SUPPORT _FILE_OFFSET_BITS=64 PEK_SERVER_VERSION="${PEK_SERVER_VERSION}")
target_compile_options(pek-server PRIVATE -Wno-deprecated-declarations)

# The pinned official plugin-signing keys, same parsing as the Windows / Android builds (server.cpp needs PEK_OFFICIAL_KEYS).
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

if(TARGET SQLite3::SQLite3)
    set(PEK_SQLITE_TARGET SQLite3::SQLite3)   # newer CMake name
else()
    set(PEK_SQLITE_TARGET SQLite::SQLite3)
endif()
target_link_libraries(pek-server PRIVATE OpenSSL::SSL OpenSSL::Crypto ${PEK_SQLITE_TARGET} Threads::Threads ${CMAKE_DL_LIBS})
target_link_options(pek-server PRIVATE -s)   # strip: a smaller download
if(PEK_STATIC)
    target_link_options(pek-server PRIVATE -static)
endif()
