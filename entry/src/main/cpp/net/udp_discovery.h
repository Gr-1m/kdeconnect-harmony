#ifndef KDECONNECT_UDP_DISCOVERY_H
#define KDECONNECT_UDP_DISCOVERY_H

#include "net_types.h"
#include <string>

namespace kdeconnect {

class UdpDiscovery {
public:
    UdpDiscovery() = default;
    ~UdpDiscovery();

    UdpDiscovery(const UdpDiscovery &) = delete;
    UdpDiscovery &operator=(const UdpDiscovery &) = delete;

    bool init(const std::string &deviceId, const std::string &deviceName,
              const std::string &deviceType, uint16_t tcpPort);
    void close();

    int fd() const { return fd_; }

    bool broadcast();
    std::string readIdentity();

    // 最近一次 readIdentity 收到的 UDP 源地址（IPv4 点分十进制）。
    // identity JSON 本身不携带 host，host 只能来自 UDP 源地址。
    std::string lastSourceHost() const { return lastSourceHost_; }

private:
    int fd_ = -1;
    std::string identityJson_;
    std::string lastSourceHost_;
};

} // namespace kdeconnect

#endif
