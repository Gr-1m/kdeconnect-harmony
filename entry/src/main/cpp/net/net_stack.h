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

private:
    void eventLoop();
    void dispatchEvent(const NetEvent &event);
    void dispatchError(const std::string &deviceId, int code, const std::string &message);
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

    int wakeFd_ = -1;

    // caps 单一来源（REVIEW §3.3）：UDP 与 TLS 两条 identity 路径共用
    std::mutex capsMutex_;
    std::vector<std::string> capsIncoming_{"kdeconnect.ping", "kdeconnect.identity",
                                           "kdeconnect.pair"};
    std::vector<std::string> capsOutgoing_{"kdeconnect.ping"};

    // 本机证书 SPKI DER 惰性缓存（验证码用）
    std::string ownSpkiDer_;
    bool ownSpkiDone_ = false;

    std::unique_ptr<PayloadManager> payload_;
};

NetStack &netStack();

} // namespace kdeconnect

#endif
