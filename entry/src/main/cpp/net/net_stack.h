#ifndef KDECONNECT_NET_STACK_H
#define KDECONNECT_NET_STACK_H

#include "net_types.h"
#include "payload/payload.h"
#include <thread>
#include <array>
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
    bool epollMod(int fd, uint32_t events) override;
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
    // 两者都要求调用方已持有 connMutex_（lk 为其 unique_lock）：S1 两阶段管线在解析段临时放锁，
    // 返回时重新加锁。放锁期间连接可能被回收 ⇒ 该段内只按 fd/快照取值，绝不引用传入的 conn。
    void drainEncrypted(std::unique_lock<std::mutex> &lk, TcpConnection &conn);
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
    // 明文 identity 阶段读取（调用方持 connMutex_）；事件路径与 tick 兜底共用
    void pumpPlainIdentity(TcpConnection &conn);
    // EPOLLOUT 兴趣按需维护（P0-b2-c）：只在「真有可能写出东西」时挂 EPOLLOUT，
    // 且仅在状态变化时 epoll_ctl(MOD)（MOD 会重新武装 ET 并立即上报，必须避免每轮调用）。
    void updateWriteInterest(int fd);         // 自取 connMutex_
    void updateWriteInterestLocked(int fd);   // 调用方已持 connMutex_
    // 作用域退出时刷新 EPOLLOUT 兴趣：覆盖处理函数内所有 return 路径；连接可能在过程中被关闭，
    // updateWriteInterest 内部按 fd 重查，天然安全。
    struct WriteInterestGuard {
        NetStack *ns;
        int fd;
        WriteInterestGuard(NetStack *n, int f) : ns(n), fd(f) {}
        ~WriteInterestGuard() { ns->updateWriteInterest(fd); }
    };
    void closeConnection(int fd, const char *reason);
    // 排空读后按 '\n' 切分逐帧派发（接收缓冲在连接对象内，半包留待下次）
    void dispatchFrames(std::unique_lock<std::mutex> &lk, TcpConnection &conn);
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
    // ——— 真机阻塞根因定位（DevEco MSG178 §3）———
    // 真机实测：循环被高频唤醒（~1000 次/秒），而「每连接 tick + payload onTick」原先每轮都跑
    // ⇒ 每轮 ~0.78ms CPU 且每轮取一次 connMutex_（非公平锁）⇒ JS 线程 sendPacket 被饿死数秒。
    // 这里既做时间门控，也把「唤醒来源 / 持锁峰值 / 等锁峰值 / 队列长度」打进 NETLOOP 行。
    int64_t lastTickMs_ = 0;                  // 重活（payload onTick + 每连接 tick）的时间门
    uint64_t wakeByWakeFd_ = 0;               // 以下均为累计值：相邻两行做差 = 该窗口分布
    uint64_t wakeByUdp_ = 0;
    uint64_t wakeBySrv_ = 0;
    uint64_t wakeByConn_ = 0;
    uint64_t wakeByPayload_ = 0;
    uint64_t wakeByIdle_ = 0;                 // epoll_wait 超时（n == 0）
    // 连接事件的掩码分布（§3.2：判定 wake[conn] 3270/s 的来源）
    uint64_t connIn_ = 0;
    uint64_t connOut_ = 0;
    uint64_t connHup_ = 0;
    int64_t maxTickHoldMs_ = 0;               // 窗口内单次持 connMutex_ 的最长耗时（循环线程写）
    const char *maxHoldLabel_ = "?";          // 上述最长持锁来自哪个调用点（[KDC-LOCKHOLD] 同款标签）
    std::atomic<int64_t> maxJsLockWaitMs_{0}; // 窗口内 JS 线程等 connMutex_ 的最长耗时
    // —— 事件普查（用户「关 WiFi 就不卡」对照实验后的定位用）——
    // 开屏期 JS 线程被 tsfn 事件回调占住 ⇒ 点击无响应。这里按 EventType 计数，随 NETLOOP 行输出：
    // 若窗口内只有几十条 ⇒ 瓶颈在 ArkTS 单事件成本（每秒整页重建）；若是数千条 ⇒ native 过度派发。
    std::array<std::atomic<uint64_t>, 8> evCounts_{};
    // 同一设备 2s 内的重复 DeviceDiscovered 不再派发（UDP 广播与「对端拨入」两条来源会重复告知；
    // 仅网络线程写此表，故无需额外锁）。
    std::unordered_map<std::string, int64_t> lastDiscoveredMs_;
    size_t statTxQueuedBytes_ = 0;            // 窗口内观测到的 TX 队列字节（含明文队列）
    size_t statPlainQueuedBytes_ = 0;

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
    // P-4 方案 A：键为 "host|deviceId"（此前按 host）⇒ 异设备同 IP 不互相牵连
    std::unordered_map<std::string, int64_t> lastAcceptByIp_;
    std::unordered_map<std::string, int64_t> lastConnByDevice_;

    std::unique_ptr<PayloadManager> payload_;
};

NetStack &netStack();

} // namespace kdeconnect

#endif
