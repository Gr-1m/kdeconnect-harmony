// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef KDECONNECT_NET_TYPES_H
#define KDECONNECT_NET_TYPES_H

#include <string>
#include <cstdint>
#include <functional>
#include <vector>

namespace kdeconnect {

constexpr uint16_t UDP_PORT = 1716;
constexpr uint16_t TCP_PORT_MIN = 1716;
constexpr uint16_t TCP_PORT_MAX = 1764;
constexpr uint16_t PAYLOAD_PORT_MIN = 1739;
constexpr size_t MAX_IDENTITY_PACKET_SIZE = 8192;
// JSON 帧上限（不含 payload 字节流；KDE landevicelink.cpp 同值）。
// payload 传输按 payloadSize 流式处理，不受此上限约束。
constexpr size_t MAX_PACKET_SIZE = 32u * 1024u * 1024u;
constexpr int PROTOCOL_VERSION = 8;
constexpr int MAX_UNPAIRED_CONNECTIONS = 42;
// P3（AtomCode 审计）：listen backlog 此前复用 MAX_UNPAIRED_CONNECTIONS ⇒ 语义巧合，
// 拆出独立常量，避免将来调 42 时顺带改掉 backlog。
constexpr int LISTEN_BACKLOG = 42;
constexpr int IDENTITY_TIMEOUT_MS = 1000;
constexpr int DISCOVERY_DEBOUNCE_MS = 500;
// 同一设备重复 DeviceDiscovered 的事件级去重窗口（UDP 广播 + 对端拨入两条来源会重复告知；
// 开屏期成对放大 ArkTS 侧处理量）。用户「关 WiFi 就不卡」对照实验后加入。
constexpr int DISCOVERY_DEDUP_EVENT_MS = 2000;
// sendPacket 慢调用判定阈值：超过即打 [KDC-ENTRY-SPLIT]（wall/cpu/lock 三段，见 NATIVE_ANALYSIS §2.4）
constexpr int64_t ENTRY_SPLIT_LOG_MS = 50;
// 持锁超时打点阈值（[KDC-LOCKHOLD]）：真机持锁达 1.2~3.2s，这里取 100ms 以便捕获中间态
constexpr int64_t LOCK_HOLD_LOG_MS = 100;
// 同 IP accept 限流（防连接风暴）。原为 1000ms：但 KDE 的「新链路替换旧链路」语义会让对端在
// ~0.6~0.7s 后重拨一次，1000ms 会把这次**合法重拨**直接拒掉（真机配对失败成因之一，DevEco MSG181）。
// 降到 300ms：仍能挡住真正风暴，又能容纳 KDE 的正常替换节奏。
constexpr int CONN_RATE_LIMIT_MS = 300;
// UDP 广播超时：无活跃链路且超过该时长未见广播 → 派发 DeviceLost（定时器 tick 驱动）。
// 注意（P1-2）：KDE/Android 不周期广播，故判定以「连接状态」为主——有活跃链路时
// 只刷新时间戳不派发（见 NetStack::eventLoop）。
constexpr int DISCOVERY_TIMEOUT_MS = 60000;

// —— UDP 发现周期重播（CodeArts MSG73_TO_OMP 修复 2 + MSG78 §2 裁决）——
// 对端只在启动/网络变化时广播（KDE `lanlinkprovider.cpp:149,192`、Android 同构），
// 故「后启动/错过对端广播」的一方必须由我们主动补齐：启动初期快速，随后长期低频持续。
// MSG78 §2 裁决：早期版本「5s×5 次后停止」会让发现列表在 60s 后因 DISCOVERY_TIMEOUT 被清空
// （真机实证），故稳定期改为**每 60s 一次、持续不停**；60s 远大于 KDE 同设备去抖窗口(500ms)。
constexpr int DISCOVERY_BROADCAST_FAST_MS = 5000;      // 启动初期
constexpr int DISCOVERY_BROADCAST_FAST_COUNT = 5;      // 快速阶段次数
constexpr int DISCOVERY_LONG_INTERVAL_MS = 60000;      // 稳定期：长期低频、不停
// 已建链时是否仍周期广播 —— 默认 **false**（偏离 MSG73 原方案，理由与证据见下）。
// KDE 收到任意 identity 广播都会**新建 TCP 连接**（`udpBroadcastReceived` 无「已有链路则跳过」，
// 仅 500ms 同设备去抖），而它对同设备**新链路替换旧链路**（实测 `deviceLinkDestroyed`
// → 我方旧链路 `error tls read failed` + `disconnected`）。若持续周期广播，对端会周期性换链路：
// 正在进行的 payload 传输会随控制链路丢失被中止（`onDeviceDown`），会话弹窗也会被判失败。
// 因此默认只在我们**没有活跃链路**时重播（覆盖「发现页空」的主场景），
// 需要「对端后加入也能发现我们」时改 true——代价就是上述链路替换。
constexpr bool DISCOVERY_BROADCAST_WHILE_LINKED = false;
// 等待 socket 可写的单次上限（非阻塞写不可用时的兜底等待）
constexpr int TLS_WRITE_WAIT_MS = 2000;
// —— 无端口拨号的端口探测（DevEco 报「KDE 拨入过的设备 tcpPort=0」，2026-09-13）——
// KDE 只在 UDP 广播里带 tcpPort（lanlinkprovider.cpp:254），拨入连接的 identity 不带 ⇒
// 只被拨入过的设备端口未知。此时在 [TCP_PORT_MIN, TCP_PORT_MAX] 并行探测真在 listen 的端口，
// 整轮 poll 的上限即本值（用户在发现页点连接可容忍的半秒级等待；探测跑在事件循环线程上）。
constexpr int PORT_PROBE_TIMEOUT_MS = 500;
// 单连接发送队列上限（对端长期不读时防止内存无界增长）
constexpr size_t MAX_TX_QUEUE_BYTES = 8u * 1024u * 1024u;

enum class TlsRole {
    Server,
    Client,
};

enum class ConnectionState {
    Idle,
    PlainIdentity,
    TlsHandshake,
    Encrypted,
    Closing,
    Closed,
};

// 明文 identity 等待上限：accept 后超时未收到 identity 即断开（AGENTS.md 不变量）
constexpr int PLAIN_IDENTITY_TIMEOUT_MS = 1000;

// TLS 握手上限：对端 TCP 能连上但不应答（不是 KDE Connect / 半死 / 黑洞 IP）时必须有界失败，
// 否则连接悬挂、用户也看不到「连接失败」（用户 UX 规格 #1/#2：连接要明确成功或失败）。
constexpr int CONNECT_HANDSHAKE_TIMEOUT_MS = 10000;

struct DeviceInfo {
    std::string deviceId;
    std::string deviceName;
    std::string deviceType;
    std::string host;
    uint16_t tcpPort = 0;
};

struct NetConfig {
    std::string deviceId;
    std::string deviceName;
    std::string deviceType;
    std::string certPem;
    std::string keyPem;
    uint16_t tcpPort = 0;
    // UDP 监听/广播端口（0 = 用 UDP_PORT 默认 1716）。host 测试注入非标准端口，避免假对端
    // 在真实局域网广播污染真机 hilog（DevEco MSG4 §3）。
    uint16_t udpPort = 0;
    // payload 接收落盘的 spool 目录（空 = 设备默认 cacheDir 路径，见 payload.h）。
    // 设计 v0.2 §3 要求由 ArkTS 传入；当前 ArkTS 未传，native 保留可注入能力
    // （host 集成工具 tests/desktop_pair.cpp 用它把 spool 指到 /tmp）。
    std::string spoolDir;
    // TLS 握手上限（ms；0 = 用 CONNECT_HANDSHAKE_TIMEOUT_MS 默认值）。测试可注入以缩短耗时。
    int connectHandshakeTimeoutMs = 0;
    // 端口探测区间（0 = 用 TCP_PORT_MIN/TCP_PORT_MAX）。测试可注入：本机 1716-1764 常被
    // 桌面 kdeconnectd 占用，注入单端口区间才能确定性地验证「端口未知 ⇒ 探测 ⇒ 拨号」这条路径。
    uint16_t portProbeMin = 0;
    uint16_t portProbeMax = 0;
};

enum class EventType {
    DeviceDiscovered,
    DeviceLost,
    Connected,
    Disconnected,
    PacketReceived,
    PairingRequest,
    Error,
    PayloadTransfer,
};

struct NetEvent {
    EventType type;
    std::string deviceId;
    std::string deviceName;
    std::string deviceType;
    std::string host;
    uint16_t tcpPort = 0;
    TlsRole role = TlsRole::Client;
    std::string packet;
    int errorCode = 0;
    std::string errorMessage;
    // packetReceived 且帧内含 payloadTransferInfo 时填充（WP-1b 前置）：
    // payloadSize：0 = 无 payload，-1 = 流式；payloadTransferPort：对端 payload 监听端口。
    int64_t payloadSize = 0;
    uint16_t payloadTransferPort = 0;
    // type == PayloadTransfer 时填充（WP-1b）：
    uint64_t payloadTransferId = 0;
    bool payloadDirectionSend = false;
    std::string payloadState;      // started/progress/finished/failed/cancelled
    std::string payloadFilePath;   // receive: spool 路径
    std::string payloadFileName;
    int64_t payloadBytesDone = 0;
};

using EventCallback = std::function<void(const NetEvent &)>;

} // namespace kdeconnect

#endif
