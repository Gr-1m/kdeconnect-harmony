#ifndef KDECONNECT_NET_STACK_H
#define KDECONNECT_NET_STACK_H

#include "net_types.h"
#include "payload/payload.h"
#include <thread>
#include <atomic>
#include <unordered_map>
#include <memory>
#include <mutex>
#include <cstdint>
#include <vector>

namespace kdeconnect {

class UdpDiscovery;
class TcpServer;
class TcpConnection;
class TlsEngine;
class CertGen;

class NetStack : public PayloadHost {
public:
    NetStack();
    ~NetStack();

    NetStack(const NetStack &) = delete;
    NetStack &operator=(const NetStack &) = delete;

    void setEventCallback(EventCallback cb);

    bool start(const NetConfig &config);
    void stop();

    bool connectToPeer(const std::string &host, uint16_t port);
    bool sendPacket(const std::string &deviceId, const std::string &packetJson);
    void disconnectDevice(const std::string &deviceId);

    // caps 单一来源（d.ts v2 setCapabilities）：更新后向已建 TLS 链路重发 identity
    void setCapabilities(const std::vector<std::string> &incomingCaps,
                         const std::vector<std::string> &outgoingCaps);

    // AP-1b：对端证书 PEM（空 = 无加密链路）；配对验证码（KDE verificationKey 等价）
    std::string getPeerCertificate(const std::string &deviceId);
    std::string getOwnCertificate();

    // 立即发一次 UDP 发现广播（UI「扫描/下拉刷新」入口，CodeArts MSG73_TO_OMP 修复 4）
    void triggerBroadcast();

    // —— WP-2 安全加固 ——
    // 信任设备证书钉扎（内存态；持久化由 ArkTS TrustStore/Preferences 负责，启动时回灌）。
    // 已登记 deviceId 的后续连接：对端证书与登记不符 → 断链 + error 事件。
    void setTrustedCertificate(const std::string &deviceId, const std::string &certPem);
    void removeTrustedCertificate(const std::string &deviceId);
    std::string getPairVerificationCode(const std::string &deviceId, int64_t pairingTimestamp);

    // —— WP-1b payload ——
    uint64_t sendPayload(const std::string &deviceId, const std::string &type,
                         const std::string &bodyJson, const std::string &filePath);
    bool payloadSettle(uint64_t id, const std::string &destPath, bool keep);
    void payloadCancel(uint64_t id);

    // PayloadHost（payload/ 模块宿主钩子，仅网络线程语义见 payload.h）
    bool epollAdd(int fd, uint32_t events) override;
    void epollDel(int fd) override;
    const std::string &certPem() override { return config_.certPem; }
    const std::string &keyPem() override { return config_.keyPem; }
    bool sendControlFrame(const std::string &deviceId, const std::string &frame) override;
    void postPayloadEvent(NetEvent ev) override { dispatchEvent(ev); }
    int64_t nowMs() override;
    std::string peerCertPem(const std::string &deviceId) override;

private:
    void eventLoop();
    void dispatchEvent(const NetEvent &event);
    void dispatchError(const std::string &deviceId, int code, const std::string &message,
                       const std::string &host = std::string(), uint16_t port = 0);
    // 出向连接握手阶段失败：带目标地址 + 真实 errno（App 据此提示「连接失败/对端无响应」）
    void dispatchConnectError(const std::string &host, uint16_t port, int code, const char *stage);
    // 加密态排空读 + 派发帧（EPOLLET 正确性 + 握手完成当次排空，见实现注释）
    void drainEncrypted(TcpConnection &conn);
    // TLS 握手上限（NetConfig 可注入以便测试缩短；0 → CONNECT_HANDSHAKE_TIMEOUT_MS）
    int handshakeTimeoutMs() const
    {
        return config_.connectHandshakeTimeoutMs > 0 ? config_.connectHandshakeTimeoutMs
                                                    : CONNECT_HANDSHAKE_TIMEOUT_MS;
    }
    // 唤醒事件循环线程（跨线程入队后调用；eventfd 线程安全）
    void wakeLoop();

    void onUdpReadable();
    void onTcpServerReadable();
    void onConnectionReadable(int fd);
    void onConnectionWritable(int fd);
    void closeConnection(int fd, const char *reason);
    // 排空读后按 '\n' 切分逐帧派发（接收缓冲在连接对象内，半包留待下次）
    void dispatchFrames(TcpConnection &conn);
    // 处理握手前的明文 identity 帧；成功返回 true 并推进到 TLS 握手
    bool handlePlainIdentity(TcpConnection &conn, const std::string &frame);
    void sendIdentityOverTls(TcpConnection &conn);

    // —— 端口未知（0）的拨号：探测 + host→端口 缓存 ——
    // 触发场景：KDE 只在 UDP 广播的 identity 里带 tcpPort，拨入连接的 identity 不带
    // （kdeconnect-kde core/backends/lan/lanlinkprovider.cpp:254 vs toIdentityPacket()），
    // 所以「只被对端拨入过」的设备在发现列表里端口恒为 0，用户点连接时无从下手。
    // 队列只承载「端口待探测」的请求：探测要 ≤PORT_PROBE_TIMEOUT_MS 阻塞，绝不能在 JS 线程做，
    // 因此 connectToPeer(host, 0) 只入队 + 唤醒事件循环，探测与拨号都在循环线程完成。
    struct PendingDial {
        std::string host;
    };
    void processPendingDials();
    void rememberPeerPort(const std::string &host, uint16_t port);
    void forgetPeerPort(const std::string &host);
    uint16_t cachedPortFor(const std::string &host);

    int epollFd_ = -1;
    std::atomic<bool> running_{false};
    std::thread loopThread_;
    EventCallback eventCallback_;
    std::mutex callbackMutex_;

    NetConfig config_;
    std::unique_ptr<UdpDiscovery> udp_;
    std::unique_ptr<TcpServer> tcpServer_;

    std::unordered_map<int, std::unique_ptr<TcpConnection>> connections_;
    std::mutex connMutex_;

    // UDP 发现跟踪（deviceId → 最近一次广播时间 ms），超时后派发 DeviceLost
    std::unordered_map<std::string, int64_t> lastSeenMs_;

    // host → 对端 TCP 监听端口（从 UDP identity / 成功拨号学到）。JS 线程读（connectToPeer）、
    // 事件循环线程写，故单独一把锁——不与 connMutex_ 嵌套，避免锁序问题。
    std::mutex dialMutex_;
    std::vector<PendingDial> pendingDials_;
    std::unordered_map<std::string, uint16_t> portByHost_;

    // 周期重播节奏（仅事件循环线程访问）
    int64_t lastBroadcastMs_ = 0;
    int broadcastCount_ = 0;

    int wakeFd_ = -1;

    // 网络线程运行统计（MSG149 §3.1：查 CPU 饥饿/忙循环）。JS 线程只读副本，全 atomic。
    std::atomic<uint64_t> loopIters_{0};      // 事件循环迭代次数
    std::atomic<uint64_t> epollWake_{0};      // epoll_wait 返回 >0 的次数
    std::atomic<uint64_t> eventsHandled_{0};  // 处理过的 epoll 事件总数
    int64_t lastStatsMs_ = 0;                 // 上次打印统计的时间（仅循环线程访问）

    // caps 单一来源（REVIEW §3.3）：UDP 与 TLS 两条 identity 路径共用
    std::mutex capsMutex_;
    std::vector<std::string> capsIncoming_{"kdeconnect.ping", "kdeconnect.identity",
                                           "kdeconnect.pair"};
    std::vector<std::string> capsOutgoing_{"kdeconnect.ping"};

    // 本机证书 SPKI DER 惰性缓存（验证码用）
    std::string ownSpkiDer_;
    // 一次性初始化本机 SPKI（call_once；见 getPairVerificationCode 注释）
    std::once_flag ownSpkiOnce_;
    // UI 触发的立即广播请求（JS 线程置位、事件循环线程消费；避免 JS 线程直改循环线程状态）
    std::atomic<bool> forceBroadcast_{false};
    // 对端证书 PEM 缓存（按 deviceId，掉线后保留至下次连接覆盖；AP-1b「记住的设备」展示用）
    std::unordered_map<std::string, std::string> peerCertPemCache_;

    // WP-2：信任设备证书（deviceId → PEM）；连接限流（IP/deviceId → 最近一次 ms）
    std::mutex trustMutex_;
    std::unordered_map<std::string, std::string> trustedCertPem_;
    std::unordered_map<std::string, int64_t> lastAcceptByIp_;
    std::unordered_map<std::string, int64_t> lastConnByDevice_;

    std::unique_ptr<PayloadManager> payload_;
};

NetStack &netStack();

} // namespace kdeconnect

#endif
