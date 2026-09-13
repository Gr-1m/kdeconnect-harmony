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
constexpr int IDENTITY_TIMEOUT_MS = 1000;
constexpr int DISCOVERY_DEBOUNCE_MS = 500;
constexpr int CONN_RATE_LIMIT_MS = 1000;   // 同 IP/deviceId 连接限流（WP-2）
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
    // payload 接收落盘的 spool 目录（空 = 设备默认 cacheDir 路径，见 payload.h）。
    // 设计 v0.2 §3 要求由 ArkTS 传入；当前 ArkTS 未传，native 保留可注入能力
    // （host 集成工具 tests/desktop_pair.cpp 用它把 spool 指到 /tmp）。
    std::string spoolDir;
    // TLS 握手上限（ms；0 = 用 CONNECT_HANDSHAKE_TIMEOUT_MS 默认值）。测试可注入以缩短耗时。
    int connectHandshakeTimeoutMs = 0;
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
