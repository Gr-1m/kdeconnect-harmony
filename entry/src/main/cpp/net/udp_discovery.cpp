// SPDX-License-Identifier: GPL-2.0-or-later
#include "udp_discovery.h"
#include "packet_io.h"
#include "net_log.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <unistd.h>
#include <cstring>

namespace kdeconnect {

UdpDiscovery::~UdpDiscovery()
{
    close();
}

bool UdpDiscovery::init(const std::string &deviceId, const std::string &deviceName,
                        const std::string &deviceType, uint16_t tcpPort, uint16_t udpPort)
{
    port_ = udpPort;
    fd_ = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd_ < 0) {
        LOGE("udp socket: %s", strerror(errno));
        return false;
    }

    int yes = 1;
    setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(fd_, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes));

    struct sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port_);
    if (bind(fd_, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) < 0) {
        LOGE("udp bind: %s", strerror(errno));
        ::close(fd_);
        fd_ = -1;
        return false;
    }

    identityFields_[0] = deviceId;
    identityFields_[1] = deviceName;
    identityFields_[2] = deviceType;
    identityPort_ = tcpPort;
    identityJson_ = PacketIO::buildIdentity(deviceId, deviceName, deviceType, tcpPort);
    LOGI("udp discovery init on port %u", port_);   // 日志用实际端口（可注入）
    return true;
}

void UdpDiscovery::close()
{
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
}

void UdpDiscovery::setCapabilities(const std::vector<std::string> &incomingCaps,
                                   const std::vector<std::string> &outgoingCaps)
{
    std::lock_guard<std::mutex> lk(capsMutex_);
    identityJson_ = PacketIO::buildIdentity(identityFields_[0], identityFields_[1],
                                            identityFields_[2], identityPort_,
                                            PROTOCOL_VERSION, incomingCaps, outgoingCaps);
}

bool UdpDiscovery::broadcast()
{
    std::string identity;
    {
        std::lock_guard<std::mutex> lk(capsMutex_);
        identity = identityJson_;
    }

    bool anySent = false;

    // 子网定向广播（主）：逐网卡算 IP | ~mask。
    // 全局广播 255.255.255.255 在部分 HarmonyOS 版本被拒（docs/14 §2.2，errno 13），
    // 故定向广播为主、全局广播仅作兜底（CodeArts MSG73_TO_OMP 修复 1）。
    struct ifaddrs *ifaddr = nullptr;
    if (getifaddrs(&ifaddr) == 0) {
        for (struct ifaddrs *ifa = ifaddr; ifa != nullptr; ifa = ifa->ifa_next) {
            if (ifa->ifa_addr == nullptr || ifa->ifa_addr->sa_family != AF_INET ||
                ifa->ifa_netmask == nullptr) {
                continue;
            }
            if ((ifa->ifa_flags & IFF_LOOPBACK) != 0 || (ifa->ifa_flags & IFF_UP) == 0) {
                continue;
            }
            const auto *addr = reinterpret_cast<const struct sockaddr_in *>(ifa->ifa_addr);
            const auto *mask = reinterpret_cast<const struct sockaddr_in *>(ifa->ifa_netmask);
            struct sockaddr_in baddr {};
            baddr.sin_family = AF_INET;
            baddr.sin_addr.s_addr = addr->sin_addr.s_addr | ~mask->sin_addr.s_addr;
            baddr.sin_port = htons(port_);
            const ssize_t sent = sendto(fd_, identity.data(), identity.size(), 0,
                                        reinterpret_cast<struct sockaddr *>(&baddr),
                                        sizeof(baddr));
            if (sent > 0) {
                anySent = true;
                char ip[INET_ADDRSTRLEN] = {0};
                inet_ntop(AF_INET, &baddr.sin_addr, ip, sizeof(ip));
                LOGI("udp directed broadcast to %s on %s", ip, ifa->ifa_name);
            }
        }
        freeifaddrs(ifaddr);
    }

    // 兜底：全局广播（定向广播全部失败时才依赖它）
    struct sockaddr_in gaddr {};
    gaddr.sin_family = AF_INET;
    gaddr.sin_addr.s_addr = htonl(0xFFFFFFFF);
    gaddr.sin_port = htons(port_);
    const ssize_t n = sendto(fd_, identity.data(), identity.size(), 0,
                             reinterpret_cast<struct sockaddr *>(&gaddr), sizeof(gaddr));
    if (n > 0) {
        anySent = true;
        LOGI("udp global broadcast sent (%zu bytes)", identity.size());
    }

    if (!anySent) {
        LOGE("udp broadcast: all attempts failed: %s", strerror(errno));
    }
    return anySent;
}

std::string UdpDiscovery::readIdentity()
{
    char buf[MAX_IDENTITY_PACKET_SIZE];
    struct sockaddr_in src {};
    socklen_t srcLen = sizeof(src);

    ssize_t n = recvfrom(fd_, buf, sizeof(buf), 0,
                         reinterpret_cast<struct sockaddr *>(&src), &srcLen);
    if (n <= 0) {
        return {};
    }

    char ip[INET_ADDRSTRLEN];
    if (inet_ntop(AF_INET, &src.sin_addr, ip, sizeof(ip)) != nullptr) {
        lastSourceHost_ = ip;
    }

    std::string raw(buf, n);
    if (!raw.empty() && raw.back() == '\n') {
        raw.pop_back();
    }

    // 这里只校验 identity JSON 合法性；host 来自上面的 lastSourceHost_
    // （UDP 源地址），identity JSON 本身不含 host 字段。
    DeviceInfo parsed;
    if (!PacketIO::parseIdentity(raw, parsed)) {
        return {};
    }
    return raw;
}

} // namespace kdeconnect
