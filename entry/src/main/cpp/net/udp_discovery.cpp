#include "udp_discovery.h"
#include "packet_io.h"
#include "net_log.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <cstring>

namespace kdeconnect {

UdpDiscovery::~UdpDiscovery()
{
    close();
}

bool UdpDiscovery::init(const std::string &deviceId, const std::string &deviceName,
                        const std::string &deviceType, uint16_t tcpPort)
{
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
    addr.sin_port = htons(UDP_PORT);
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
    LOGI("udp discovery init on port %u", UDP_PORT);
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
    struct sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(0xFFFFFFFF);
    addr.sin_port = htons(UDP_PORT);

    std::string identity;
    {
        std::lock_guard<std::mutex> lk(capsMutex_);
        identity = identityJson_;
    }
    ssize_t n = sendto(fd_, identity.data(), identity.size(), 0,
                       reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr));
    if (n < 0) {
        LOGE("udp broadcast: %s", strerror(errno));
        return false;
    }
    LOGI("udp broadcast sent (%zu bytes)", identity.size());
    return true;
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
