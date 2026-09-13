#ifndef KDECONNECT_NET_UTIL_H
#define KDECONNECT_NET_UTIL_H

#include <cstdint>
#include <string>

namespace kdeconnect {

// 网络地址工具（纯函数，host 可测；CPP_GUIDE §2 的「不依赖 NAPI/NDK 头」约束）。
// 单独成文件的原因：这是安全策略（只接受私网直连），边界值必须有回归测试
// （P1-1 曾在 172.16/12 判定上写错，172.16–172.31 全被拒）。

// 仅私网 IPv4 视为可直连：10/8、127/8、172.16/12、192.168/16、169.254/16。
// 非法串（非四段、越界、尾部垃圾、空串）一律 false。
bool isPrivateIpv4(const std::string &host);

// 在 [minPort, maxPort] 内找出**真正在 listen** 的 TCP 端口，返回 0 表示区间内无监听者。
//
// 存在的理由（用户报「发现列表里端口是 0」，DevEco 第五次报，2026-09-13）：
// KDE 只在 UDP 广播的 identity 里带 `tcpPort`（kdeconnect-kde core/backends/lan/lanlinkprovider.cpp:254，
// 以及 connectError 回退路径 :348），**拨入连接的 identity 不带**（它走 DeviceInfo::toIdentityPacket()）。
// 于是「只被对端拨入过」的设备（桌面先连我们）在 ArkTS 发现列表里端口恒为 0，手动连接无从下手；
// 而 KDE 自己是靠 UDP 广播拿到对端端口的，同样只在双方都广播过时有效。
// 对端不配合时唯一可靠的办法就是按 KDE 的端口区间探测（KDE 从 MIN_TCP_PORT 起找第一个可用端口）。
//
// 实现：并行非阻塞 connect + 单轮 poll（监听端口由内核直接回 SYN/ACK，局域网内一轮即出结果），
// 端口按升序扫描，返回命中的最小端口（与 KDE 的「优先最小可用」语义一致）。
// timeoutMs 是整轮 poll 的上限；host 必须是点分 IPv4 串，非法输入返回 0。
uint16_t findListeningTcpPort(const std::string &host, uint16_t minPort, uint16_t maxPort,
                              int timeoutMs);

} // namespace kdeconnect

#endif
