// Included by hand (after the standard headers) at the top of discovery.cpp and vfs_ftp.cpp when building for Windows:
// maps the POSIX socket calls those two files make onto Winsock. Not force-included, because these are macros and would
// break standard headers that use the same words (close(), send(), ...).
#pragma once
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <errno.h>
#include <fcntl.h>

#ifndef O_NONBLOCK
#define O_NONBLOCK 0x40000
#endif
#ifndef F_GETFL
#define F_GETFL 3
#define F_SETFL 4
#endif
static inline int pek_fcntl_(int fd, int cmd, int arg) {
    if (cmd == F_GETFL) return 0;
    u_long on = (arg & O_NONBLOCK) ? 1 : 0;
    return ioctlsocket((SOCKET)fd, FIONBIO, &on);
}
// Winsock reports a connect that is still going as WSAEWOULDBLOCK; the code tests errno == EINPROGRESS.
static inline int pek_connect_(int fd, const struct sockaddr* a, int len) {
    int rc = ::connect((SOCKET)fd, a, len);
    if (rc != 0 && WSAGetLastError() == WSAEWOULDBLOCK) errno = EINPROGRESS;
    return rc;
}
static inline int pek_poll_(WSAPOLLFD* f, unsigned long n, int ms) { return WSAPoll(f, n, ms); }

#define fcntl(fd, cmd, arg) pek_fcntl_((fd), (cmd), (arg))
#define connect(s, a, l) pek_connect_((int)(s), (a), (int)(l))
#define poll(f, n, ms) pek_poll_((f), (unsigned long)(n), (ms))
#define close(fd) closesocket((SOCKET)(fd))
#define recv(s, b, l, f) recv((s), (char*)(b), (int)(l), (f))
#define send(s, b, l, f) send((s), (const char*)(b), (int)(l), (f))
#define sendto(s, b, l, f, a, al) sendto((s), (const char*)(b), (int)(l), (f), (a), (int)(al))
#define getsockopt(s, lv, o, v, n) getsockopt((s), (lv), (o), (char*)(v), (int*)(n))
#define setsockopt(s, lv, o, v, n) setsockopt((s), (lv), (o), (const char*)(v), (int)(n))
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif
#endif
