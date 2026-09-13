#include "net_util.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdio>
#include <vector>

namespace kdeconnect {

bool isPrivateIpv4(const std::string &host)
{
    unsigned a[4] = {0, 0, 0, 0};
    int consumed = 0;
    // 必须整串匹配 "a.b.c.d"：%n 记下已消费长度，多一字符即拒绝（"1.2.3.4x" 之类）
    if (::sscanf(host.c_str(), "%u.%u.%u.%u%n", &a[0], &a[1], &a[2], &a[3], &consumed) != 4 ||
        consumed != static_cast<int>(host.size())) {
        return false;
    }
    for (int i = 0; i < 4; ++i) {
        if (a[i] > 255) {
            return false;
        }
    }
    return a[0] == 10 || a[0] == 127 ||
           (a[0] == 172 && a[1] >= 16 && a[1] <= 31) ||   // 172.16.0.0/12
           (a[0] == 192 && a[1] == 168) ||
           (a[0] == 169 && a[1] == 254);
}

namespace {

// 自连接：connect() 的本地端口恰好等于目标端口时，内核会把它接到自己身上并「成功」。
// 探测已关闭的临时端口时实测必然踩到（刚释放的端口最容易被再次分配成本地端口），
// 会把「无监听者」误判成有 —— 必须按 getsockname 排除。
bool isSelfConnect(int fd, uint16_t targetPort)
{
    struct sockaddr_in local {};
    socklen_t len = sizeof(local);
    if (::getsockname(fd, reinterpret_cast<struct sockaddr *>(&local), &len) != 0) {
        return false;
    }
    return ntohs(local.sin_port) == targetPort;
}

} // namespace

uint16_t findListeningTcpPort(const std::string &host, uint16_t minPort, uint16_t maxPort,
                              int timeoutMs)
{
    struct sockaddr_in addr {};
    addr.sin_family = AF_INET;
    if (::inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1 || minPort == 0 ||
        maxPort < minPort) {
        return 0;
    }

    std::vector<int> fds;
    std::vector<uint16_t> ports;
    uint16_t found = 0;

    for (uint32_t p = minPort; p <= maxPort; ++p) {
        const int fd = ::socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
        if (fd < 0) {
            continue;
        }
        addr.sin_port = htons(static_cast<uint16_t>(p));
        const int r = ::connect(fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr));
        if (r == 0) {
            if (isSelfConnect(fd, static_cast<uint16_t>(p))) {
                ::close(fd);
                continue;
            }
            ::close(fd);   // 本机/同网段常见：内核立刻完成握手
            found = static_cast<uint16_t>(p);
            break;
        }
        if (errno != EINPROGRESS) {
            ::close(fd);   // ECONNREFUSED / ENETUNREACH 等：该端口无监听者
            continue;
        }
        fds.push_back(fd);
        ports.push_back(static_cast<uint16_t>(p));
    }

    if (found == 0 && !fds.empty()) {
        std::vector<struct pollfd> pfd(fds.size());
        for (size_t i = 0; i < fds.size(); ++i) {
            pfd[i].fd = fds[i];
            pfd[i].events = POLLOUT;
        }
        // 每个 fd 只判定一次：SO_ERROR 是**读即清除**的，第二轮再读会拿到 0（表现为
        // 「第一次读走了 ECONNREFUSED，第二次误判为连接成功」——实测踩到过）。
        // 取值：-1 未判定 / 0 不可用 / 1 可用。
        std::vector<signed char> verdict(fds.size(), -1);
        // 两轮：第一轮用调用者给的预算，第二轮给仍在握手的连接一个很短的收尾窗口
        // （丢包重传的现场；局域网正常情况第一轮就全出结果）。
        for (int round = 0; round < 2 && found == 0; ++round) {
            const int budget = (round == 0) ? timeoutMs : 50;
            if (budget <= 0 || ::poll(pfd.data(), pfd.size(), budget) <= 0) {
                break;
            }
            for (size_t i = 0; i < fds.size(); ++i) {
                if (verdict[i] >= 0 || pfd[i].revents == 0) {
                    continue;
                }
                int err = 0;
                socklen_t len = sizeof(err);
                verdict[i] = (::getsockopt(fds[i], SOL_SOCKET, SO_ERROR, &err, &len) == 0 &&
                              err == 0 && !isSelfConnect(fds[i], ports[i]))
                                 ? 1
                                 : 0;
            }
            for (size_t i = 0; i < fds.size() && found == 0; ++i) {
                if (verdict[i] == 1) {
                    found = ports[i];   // 端口升序扫描 ⇒ 命中区间内最小可用端口
                }
            }
        }
    }

    for (int fd : fds) {
        ::close(fd);
    }
    return found;
}

} // namespace kdeconnect
