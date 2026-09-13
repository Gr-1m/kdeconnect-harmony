#ifndef KDECONNECT_NET_UTIL_H
#define KDECONNECT_NET_UTIL_H

#include <string>

namespace kdeconnect {

// 网络地址工具（纯函数，host 可测；CPP_GUIDE §2 的「不依赖 NAPI/NDK 头」约束）。
// 单独成文件的原因：这是安全策略（只接受私网直连），边界值必须有回归测试
// （P1-1 曾在 172.16/12 判定上写错，172.16–172.31 全被拒）。

// 仅私网 IPv4 视为可直连：10/8、127/8、172.16/12、192.168/16、169.254/16。
// 非法串（非四段、越界、尾部垃圾、空串）一律 false。
bool isPrivateIpv4(const std::string &host);

} // namespace kdeconnect

#endif
