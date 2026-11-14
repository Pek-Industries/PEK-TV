// Force-included into every backend source when the server is built for Windows (windows/backend/CMakeLists.txt).
// Gives the POSIX-only calls the shared backend uses a Windows body, without touching the shared sources.
// Everything here is a function or a rename: nothing that could clash with a standard header.
#pragma once
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdio.h>

// setenv / timegm / strptime are not in the Windows C library: renamed so a real declaration (if any) cannot clash.
#define setenv pek_setenv
#define timegm pek_timegm
#define strptime pek_strptime

static inline int pek_setenv(const char* k, const char* v, int overwrite) {
    if (!overwrite && getenv(k)) return 0;
    return _putenv_s(k, v);
}
static inline time_t pek_timegm(struct tm* t) { return _mkgmtime(t); }

// Only the one format the backend uses: "Tue, 05 Nov 2024 10:00:00" (an HTTP Last-Modified date without the zone).
static inline char* pek_strptime(const char* s, const char* fmt, struct tm* t) {
    (void)fmt;
    static const char* const mon[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
    char wd[8] = {0}, mo[8] = {0};
    int d = 0, y = 0, h = 0, mi = 0, sec = 0, n = 0;
    if (sscanf(s, "%3[A-Za-z], %d %3[A-Za-z] %d %d:%d:%d%n", wd, &d, mo, &y, &h, &mi, &sec, &n) < 7) return nullptr;
    int m = -1;
    for (int i = 0; i < 12; i++) if (_strnicmp(mo, mon[i], 3) == 0) m = i;
    if (m < 0) return nullptr;
    memset(t, 0, sizeof *t);
    t->tm_mday = d; t->tm_mon = m; t->tm_year = y - 1900; t->tm_hour = h; t->tm_min = mi; t->tm_sec = sec;
    return const_cast<char*>(s + n);
}
#endif
