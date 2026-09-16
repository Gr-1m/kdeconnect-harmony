#ifndef KDECONNECT_TCP_CONNECTION_H
#define KDECONNECT_TCP_CONNECTION_H

#include "net_types.h"
#include "tls_engine.h"
#include <string>
#include <vector>
#include <memory>
#include <deque>
#include <cstddef>

namespace kdeconnect {

class TcpConnection {
public:
    explicit TcpConnection(int fd, bool isIncoming);
    ~TcpConnection();

    TcpConnection(const TcpConnection &) = delete;
    TcpConnection &operator=(const TcpConnection &) = delete;

    int fd() const { return fd_; }
    bool isIncoming() const { return isIncoming_; }
    ConnectionState state() const { return state_; }
    const std::string &deviceId() const { return deviceId_; }
    TlsRole tlsRole() const { return isIncoming_ ? TlsRole::Client : TlsRole::Server; }
    void setPeerInfo(const std::string &host, uint16_t port,
                     const std::string &name = std::string(),
                     const std::string &type = std::string());
    const std::string &peerHost() const { return peerHost_; }
    uint16_t peerPort() const { return peerPort_; }
    const std::string &peerName() const { return peerName_; }
    const std::string &peerType() const { return peerType_; }

    // 明文 identity 帧：MSG_PEEK 精确定位 '\n' 后按需读取。
    // 关键：不接受超过一帧的数据，避免把紧随其后的 TLS 记录头吞进明文缓冲。
    // 返回 >0：帧字节数（out 含结尾 '\n'）；0：数据不足（等待）；-1：对端关闭/帧超限/错误。
    // errOut（可选）：失败时回填真实 errno（ECONNREFUSED/ECONNRESET/EMSGSIZE…），
    // 供上层把「连不上」的原因如实报给用户（strerror 会覆盖 errno，故必须就地捕获）。
    ssize_t readPlainFrame(std::string &out, size_t maxSize, int *errOut = nullptr);
    // ——— 明文发送侧队列（P0-b：任何线程都不得在 socket 上阻塞等待）———
    // queuePlainFrame 只做内存入队（可从 JS 线程/网络线程调用）；
    // flushPlain 由**网络线程**调用：尽量写，遇 EAGAIN 立即把余量留在队列里返回 false
    // （不 poll、不重试等待）；硬错误置 state_=Closing 并返回 false。
    // 语义：flushPlain() == true ⇒ 队列已排空。TLS 握手必须**在明文队列排空后**启动，
    // 否则明文 identity 会与 TLS 记录交错（协议顺序不变量）。
    void queuePlainFrame(std::string data);
    bool flushPlain();
    bool plainPending() const { return plainOffset_ < plainTx_.size(); }
    size_t plainQueuedBytes() const { return plainTx_.size() - plainOffset_; }
    // 是否值得注册 EPOLLOUT（P0-b2-c）：明文队列 / 加密队列有字节，或 TLS 引擎有待发记录。
    // EPOLLET 下「注册了 EPOLLOUT 却无可写内容」的 fd 会被 epoll_wait 每轮重复上报 ⇒ 空转烧核。
    bool wantsWrite() const
    {
        return plainPending() || txPending() || (tls_ && tls_->wantsWrite());
    }
    // EPOLLOUT 兴趣当前是否已挂（仅网络线程读写；用于只在状态变化时 epoll_ctl(MOD)）
    bool epollWriteArmed() const { return epollWriteArmed_; }
    void setEpollWriteArmed(bool v) { epollWriteArmed_ = v; }
    void markPlainIdentityQueued() { plainIdentityQueued_ = true; }
    bool plainIdentityQueued() const { return plainIdentityQueued_; }

    bool startTlsHandshake(const std::string &certPem, const std::string &keyPem);
    bool doTlsHandshake();
    bool needsSendIdentity() const { return needsSendIdentity_; }
    void clearNeedsSendIdentity() { needsSendIdentity_ = false; }
    // 请求重发 identity（P0-c）：JS 线程只置标志，实际写出由网络线程的 tick/可写路径完成。
    // 必须在 connMutex_ 内调用（与读取方同锁，避免数据竞争）。
    void requestSendIdentity() { needsSendIdentity_ = true; }
    bool tlsHandshakeDone() const;
    TlsEngine *tlsEngine() { return tls_.get(); }

    // TLS 应用数据排空读：反复读直到 EAGAIN（或缓冲超限），数据追加到 rxBuf_。
    // 返回 >=0：本轮追加的字节数；-1：对端关闭/错误/超限。
    ssize_t fillTlsRx();
    std::string &rxBuf() { return rxBuf_; }

    // ——— 发送侧 TX 队列（单写者模型）———
    // 任何线程只 enqueue（拷贝入队，不做 I/O）；**只有网络线程**调 flushTx。
    // 未写尽的字节保留在队列里，因此帧不会交错、也不会被截断（REVIEW §4 P1-3/P1-6）。
    // 返回 false 表示队列超限（对端长期不读，防内存无界增长）。
    bool enqueueTx(std::string data);
    // 网络线程：尽力把队列数据交给 TLS 引擎并泵到 socket。false = 引擎错误（应关连接）。
    bool flushTx();
    bool txPending() const { return !txQueue_.empty(); }
    size_t txQueuedBytes() const { return txQueuedBytes_; }

    void close();
    bool isClosed() const { return state_ == ConnectionState::Closed; }

    void setDeviceId(const std::string &id) { deviceId_ = id; }
    void setState(ConnectionState s) { state_ = s; }

    // Connected 事件只应派发一次（入向/出向、可读/可写路径都可能推进握手）
    bool connectedNotified() const { return connectedNotified_; }
    void markConnectedNotified() { connectedNotified_ = true; }

    // 明文 identity 超时（accept 后 1s 未收到 identity → 断开；AGENTS.md 不变量）
    bool plainExpired(int64_t nowMs) const { return plainDeadlineMs_ > 0 && nowMs > plainDeadlineMs_; }

    // TLS 握手上限（出向连接尤其需要：对端不应答时必须**有界**失败并回报可解释错误，
    // 见 CONNECT_HANDSHAKE_TIMEOUT_MS）。setHandshakeDeadline(0) = 不设限。
    void setHandshakeDeadline(int64_t deadlineMs) { handshakeDeadlineMs_ = deadlineMs; }
    bool handshakeExpired(int64_t nowMs) const
    {
        return handshakeDeadlineMs_ > 0 && nowMs > handshakeDeadlineMs_;
    }

private:
    int fd_ = -1;
    bool isIncoming_ = false;
    ConnectionState state_ = ConnectionState::Idle;
    std::string deviceId_;
    std::string peerHost_;
    uint16_t peerPort_ = 0;
    std::string peerName_;
    std::string peerType_;
    bool needsSendIdentity_ = false;
    bool connectedNotified_ = false;
    int64_t plainDeadlineMs_ = 0;
    int64_t handshakeDeadlineMs_ = 0;
    std::unique_ptr<TlsEngine> tls_;
    // 明文/解密后的接收缓冲：按 '\n' 切分后剩余的半帧留在这里等下次数据。
    std::string rxBuf_;
    // 发送队列（队首可能已部分写出，txOffset_ 记录其已写入偏移）
    std::deque<std::string> txQueue_;
    size_t txOffset_ = 0;
    size_t txQueuedBytes_ = 0;
    // 明文发送队列（仅拨号方使用：TLS 握手前的 identity 帧）
    std::string plainTx_;
    size_t plainOffset_ = 0;
    bool plainIdentityQueued_ = false;
    bool epollWriteArmed_ = false;   // EPOLLOUT 兴趣是否已挂（**须持 connMutex_ 读写**：
                                     // 网络线程与 sendPacket(JS 线程) 都会改它）
};

} // namespace kdeconnect

#endif
