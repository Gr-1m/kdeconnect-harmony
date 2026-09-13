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
