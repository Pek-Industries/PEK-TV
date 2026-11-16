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

# SMB (libsmb2) and NFS (libnfs) network folders, built from source like the Android build does (android/app/src/main/cpp/CMakeLists.txt).
# The CI workflow clones them to windows/libsmb2 and windows/libnfs. When a folder is missing, or the workflow's retry removed it
# because it would not build, that protocol is simply left out: the app then says "no SMB support" / "no NFS support" for it, exactly
# as an Android build without the library does. FTP, WebDAV and DLNA do not depend on either.
set(LIBSMB2_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../libsmb2)
set(LIBNFS_DIR  ${CMAKE_CURRENT_SOURCE_DIR}/../libnfs)

if(EXISTS ${LIBSMB2_DIR}/CMakeLists.txt)
    set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
    set(ENABLE_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(ENABLE_LIBKRB5 OFF CACHE BOOL "" FORCE)
    add_subdirectory(${LIBSMB2_DIR} libsmb2 EXCLUDE_FROM_ALL)
    # libsmb2 picks its Windows code with _WINDOWS in libsmb2.h and compat.c, but lib/compat.h also accepts __MINGW32__. Under MSYS2 clang
    # (which defines __MINGW32__ but not _WINDOWS) the headers disagreed: t_socket was both SOCKET and int, and compat.c lost smb2_random,
    # getpid_num and login_num. Defining _WINDOWS for the library, and for the one backend file that includes its header, makes them agree.
    target_compile_definitions(smb2 PRIVATE _WINDOWS)
    set_source_files_properties(${BACKEND}/vfs_smb.cpp PROPERTIES COMPILE_DEFINITIONS _WINDOWS)
    target_sources(pek_server PRIVATE ${BACKEND}/vfs_smb.cpp)
    target_include_directories(pek_server PRIVATE ${LIBSMB2_DIR}/include)
    target_compile_definitions(pek_server PRIVATE PEK_SMB)   # PEK_SMB_SHARE_ENUM stays off, as on Android
    target_link_libraries(pek_server PRIVATE smb2)
    message(STATUS "PEK: SMB support ON (libsmb2)")
else()
    message(STATUS "PEK: SMB support OFF (windows/libsmb2 not found)")
endif()

if(EXISTS ${LIBNFS_DIR}/CMakeLists.txt)
    set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
    set(ENABLE_TESTS OFF CACHE BOOL "" FORCE)
    set(ENABLE_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(ENABLE_UTILS OFF CACHE BOOL "" FORCE)
    set(ENABLE_DOCUMENTATION OFF CACHE BOOL "" FORCE)
    set(ENABLE_SHARED OFF CACHE BOOL "" FORCE)
    add_subdirectory(${LIBNFS_DIR} libnfs EXCLUDE_FROM_ALL)
    target_sources(pek_server PRIVATE ${BACKEND}/vfs_nfs.cpp)
    target_include_directories(pek_server PRIVATE ${LIBNFS_DIR}/include)
    # libnfs keeps libnfs-raw-mount.h etc. in mount/, nfs/, ... and only copies them under nfsc/ on install, so mirror them into a
    # generated nfsc/ folder (same trick as the Android build).
    file(GLOB_RECURSE LIBNFS_RAW_HDRS ${LIBNFS_DIR}/libnfs-raw-*.h ${LIBNFS_DIR}/*/libnfs-raw-*.h)
    file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/libnfs_inc/nfsc)
    foreach(h ${LIBNFS_RAW_HDRS})
        get_filename_component(hn ${h} NAME)
        if(NOT EXISTS ${LIBNFS_DIR}/include/nfsc/${hn})
            configure_file(${h} ${CMAKE_BINARY_DIR}/libnfs_inc/nfsc/${hn} COPYONLY)
        endif()
    endforeach()
    target_include_directories(pek_server PRIVATE ${CMAKE_BINARY_DIR}/libnfs_inc)
    target_compile_definitions(pek_server PRIVATE PEK_NFS)
    target_link_libraries(pek_server PRIVATE nfs)
    message(STATUS "PEK: NFS support ON (libnfs)")
else()
    message(STATUS "PEK: NFS support OFF (windows/libnfs not found)")
endif()

# One self-contained DLL: no libc++ / OpenSSL / SQLite DLLs to ship next to it.
target_link_options(pek_server PRIVATE -static)
