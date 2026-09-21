// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef KDECONNECT_UDP_DISCOVERY_H
#define KDECONNECT_UDP_DISCOVERY_H

#include "net_types.h"
#include <mutex>
#include <string>
#include <vector>

namespace kdeconnect {

class UdpDiscovery {
public:
    UdpDiscovery() = default;
    ~UdpDiscovery();

    UdpDiscovery(const UdpDiscovery &) = delete;
    UdpDiscovery &operator=(const UdpDiscovery &) = delete;

    bool init(const std::string &deviceId, const std::string &deviceName,
              const std::string &deviceType, uint16_t tcpPort, uint16_t udpPort = UDP_PORT);
    void close();

    int fd() const { return fd_; }

    bool broadcast();

    // caps 单一来源：更新后立即重建广播 identity（线程安全）
    void setCapabilities(const std::vector<std::string> &incomingCaps,
                         const std::vector<std::string> &outgoingCaps);
    std::string readIdentity();

    // 最近一次 readIdentity 收到的 UDP 源地址（IPv4 点分十进制）。
    // identity JSON 本身不携带 host，host 只能来自 UDP 源地址。
    std::string lastSourceHost() const { return lastSourceHost_; }

private:
    int fd_ = -1;
    uint16_t port_ = UDP_PORT;   // 监听/广播端口（可注入，默认 UDP_PORT）
    std::mutex capsMutex_;
    std::string identityFields_[3];   // deviceId / deviceName / deviceType
    uint16_t identityPort_ = 0;
    std::string identityJson_;
    std::string lastSourceHost_;
};

} // namespace kdeconnect

#endif
