// Self-hosted PEK Server: answers "is there a PEK Server here?" on the local network, so the app's Connect screen lists it without
// anyone typing an address. Header-only; included only by the stand-alone server (selfhost/linux, selfhost/windows).
//
// The app broadcasts the text "PEK_DISCOVER 1" to UDP port 8768. The server answers the sender, unicast, with the same JSON as
// GET /api/server/info (name, id, version, HTTP port). No key is sent; pairing still needs a code. (8767 is the phone remote's probe.)
#ifndef PEK_SELFHOST_BEACON_H
#define PEK_SELFHOST_BEACON_H

#include <atomic>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#endif

#include "selfhost.h"

namespace pekself {

inline constexpr int kBeaconPort = 8768;

/// Starts the answering thread. Returns false (and logs why) when the port cannot be opened; the server still works, devices
/// then type the address. [stopped] is asked about once a second; when it says true the thread ends.
template <class StopFn>
inline bool startBeacon(StopFn stopped) {
#ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    using Sock = SOCKET;
    const Sock bad = INVALID_SOCKET;
#else
    using Sock = int;
    const Sock bad = -1;
#endif
    Sock s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == bad) { std::cerr << "[discovery] could not open a UDP socket; devices must type the address" << std::endl; return false; }
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&one), sizeof one);
#ifdef _WIN32
    DWORD tmo = 1000;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&tmo), sizeof tmo);
#else
    timeval tmo{1, 0};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tmo, sizeof tmo);
#endif
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(static_cast<uint16_t>(kBeaconPort));
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(s, reinterpret_cast<sockaddr*>(&a), sizeof a) != 0) {
        std::cerr << "[discovery] UDP port " << kBeaconPort << " is in use; devices must type the address" << std::endl;
#ifdef _WIN32
        closesocket(s);
#else
        close(s);
#endif
        return false;
    }
    std::thread([s, stopped]() {
        char buf[256];
        while (!stopped()) {
            sockaddr_in from{};
#ifdef _WIN32
            int fl = sizeof from;
#else
            socklen_t fl = sizeof from;
#endif
            const int n = static_cast<int>(recvfrom(s, buf, sizeof buf - 1, 0, reinterpret_cast<sockaddr*>(&from), &fl));
            if (n <= 0) continue;   // timeout: look at the stop flag again
            buf[n] = 0;
            if (std::strncmp(buf, "PEK_DISCOVER", 12) != 0) continue;
            const std::string reply = infoJson();
            sendto(s, reply.data(), static_cast<int>(reply.size()), 0, reinterpret_cast<sockaddr*>(&from), fl);
        }
#ifdef _WIN32
        closesocket(s);
#else
        close(s);
#endif
    }).detach();
    std::cout << "Discovery: devices on this network can find this server (UDP " << kBeaconPort << ")." << std::endl;
    return true;
}

}  // namespace pekself

#endif
