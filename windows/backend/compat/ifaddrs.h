// getifaddrs() for Windows (IPv4 only, which is all discovery.cpp asks for), built on GetAdaptersAddresses.
#pragma once
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <net/if.h>
#include <stdlib.h>
#include <string.h>
#include <vector>

struct ifaddrs {
    struct ifaddrs* ifa_next;
    char* ifa_name;
    unsigned int ifa_flags;
    struct sockaddr* ifa_addr;
    struct sockaddr* ifa_netmask;
};

static inline int getifaddrs(struct ifaddrs** out) {
    *out = nullptr;
    ULONG size = 16 * 1024;
    std::vector<unsigned char> buf;
    ULONG rc = ERROR_BUFFER_OVERFLOW;
    for (int i = 0; i < 4 && rc == ERROR_BUFFER_OVERFLOW; i++) {
        buf.resize(size);
        rc = GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
                                  nullptr, reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buf.data()), &size);
    }
    if (rc != NO_ERROR) return -1;
    struct ifaddrs* tail = nullptr;
    for (IP_ADAPTER_ADDRESSES* a = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buf.data()); a; a = a->Next) {
        if (a->OperStatus != IfOperStatusUp) continue;
        for (IP_ADAPTER_UNICAST_ADDRESS* u = a->FirstUnicastAddress; u; u = u->Next) {
            if (!u->Address.lpSockaddr || u->Address.lpSockaddr->sa_family != AF_INET) continue;
            struct ifaddrs* e = static_cast<struct ifaddrs*>(calloc(1, sizeof(struct ifaddrs)));
            sockaddr_in* ip = static_cast<sockaddr_in*>(calloc(1, sizeof(sockaddr_in)));
            sockaddr_in* mask = static_cast<sockaddr_in*>(calloc(1, sizeof(sockaddr_in)));
            memcpy(ip, u->Address.lpSockaddr, sizeof(sockaddr_in));
            mask->sin_family = AF_INET;
            ULONG bits = u->OnLinkPrefixLength > 32 ? 32 : u->OnLinkPrefixLength;
            mask->sin_addr.s_addr = htonl(bits == 0 ? 0 : (0xFFFFFFFFu << (32 - bits)));
            e->ifa_addr = reinterpret_cast<sockaddr*>(ip);
            e->ifa_netmask = reinterpret_cast<sockaddr*>(mask);
            e->ifa_flags = IFF_UP | (a->IfType == IF_TYPE_SOFTWARE_LOOPBACK ? IFF_LOOPBACK : 0);
            if (tail) tail->ifa_next = e; else *out = e;
            tail = e;
        }
    }
    return 0;
}

static inline void freeifaddrs(struct ifaddrs* l) {
    while (l) {
        struct ifaddrs* n = l->ifa_next;
        free(l->ifa_addr);
        free(l->ifa_netmask);
        free(l);
        l = n;
    }
}
