#include "net_util.h"

#include <cstdio>

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

} // namespace kdeconnect
