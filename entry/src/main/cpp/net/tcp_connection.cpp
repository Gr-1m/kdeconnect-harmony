#include "tcp_connection.h"
#include "net_log.h"
#include <sys/socket.h>
#include <poll.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <chrono>

namespace kdeconnect {

TcpConnection::TcpConnection(int fd, bool isIncoming)
    : fd_(fd), isIncoming_(isIncoming)
{
    if (isIncoming_) {
        state_ = ConnectionState::PlainIdentity;
        // accept 后 IDENTITY_TIMEOUT_MS 内必须收到 identity，否则由 tick 断开
        using namespace std::chrono;
        plainDeadlineMs_ =
            duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count()
            + IDENTITY_TIMEOUT_MS;
    } else {
        state_ = ConnectionState::Idle;
    }
}

TcpConnection::~TcpConnection()
{
    close();
}

void TcpConnection::setPeerInfo(const std::string &host, uint16_t port,
                                const std::string &name, const std::string &type)
{
    peerHost_ = host;
    peerPort_ = port;
    if (!name.empty()) peerName_ = name;
    if (!type.empty()) peerType_ = type;
}

// 明文 identity 帧读取：MSG_PEEK 先定位 '\n'，再精确消费该帧长度。
// 不能像旧实现那样「一次 read 拿满缓冲」——那会把紧随其后的 TLS ClientHello
// 一起吞进明文缓冲，破坏 TLS 握手（identity 与 TLS 在同一个 TCP 流里背靠背）。
ssize_t TcpConnection::readPlainFrame(std::string &out, size_t maxSize, int *errOut)
{
    out.clear();

    std::vector<uint8_t> peek(maxSize);
    ssize_t n = recv(fd_, peek.data(), peek.size(), MSG_PEEK);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;  // 等待更多数据
        const int err = errno;
        if (errOut != nullptr) *errOut = err;
        LOGE("readPlainFrame fd=%d: %s", fd_, strerror(err));
        return -1;
    }
    if (n == 0) {
        if (errOut != nullptr) *errOut = ECONNRESET;  // 对端关闭/被拒
        LOGE("readPlainFrame fd=%d: peer closed", fd_);
        return -1;
    }

    const void *nl = std::memchr(peek.data(), '\n', static_cast<size_t>(n));
    if (nl == nullptr) {
        if (static_cast<size_t>(n) >= maxSize) {
            if (errOut != nullptr) *errOut = EMSGSIZE;
            LOGE("readPlainFrame fd=%d: identity exceeds %zu bytes", fd_, maxSize);
            return -1;
        }
        return 0;  // 半包，等下次可读
    }

    const size_t frameLen = static_cast<size_t>(
        static_cast<const uint8_t *>(nl) - peek.data()) + 1;

    // 精确消费 frameLen 字节（数据已确认在内核缓冲，正常不会 EAGAIN）
    std::string frame(frameLen, '\0');
    size_t got = 0;
    while (got < frameLen) {
        ssize_t r = read(fd_, &frame[got], frameLen - got);
        if (r < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
            LOGE("readPlainFrame fd=%d consume: %s", fd_, strerror(errno));
            return -1;
        }
        if (r == 0) {
            LOGE("readPlainFrame fd=%d: eof mid-frame", fd_);
            return -1;
        }
        got += static_cast<size_t>(r);
    }

    out = std::move(frame);
    return static_cast<ssize_t>(frameLen);
}

void TcpConnection::queuePlainFrame(std::string data)
{
    if (data.empty()) {
        return;
    }
    if (plainOffset_ >= plainTx_.size()) {
        plainTx_.clear();
        plainOffset_ = 0;
    }
    plainTx_ += data;
}

bool TcpConnection::flushPlain()
{
    while (plainOffset_ < plainTx_.size()) {
        const size_t rest = plainTx_.size() - plainOffset_;
        ssize_t n = ::send(fd_, plainTx_.data() + plainOffset_, rest, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                // 对端读得慢 / socket 缓冲区满：余量留在队列里，等 EPOLLOUT 或 tick 续传。
                // P0-b：这里**不再** poll(2000ms) 原地等待 —— 那会把调用方的锁（connMutex_）
                // 一并扣住数秒，导致 JS 线程的 sendPacket 冻结（本轮卡顿根因）。
                return false;
            }
            LOGE("flushPlain fd=%d: %s", fd_, strerror(errno));
            state_ = ConnectionState::Closing;  // 硬错误：交调用方（网络线程）关闭连接
            return false;
        }
        if (n == 0) {
            LOGE("flushPlain fd=%d: send returned 0 (peer gone?)", fd_);
            state_ = ConnectionState::Closing;
            return false;
        }
        plainOffset_ += static_cast<size_t>(n);
    }
    plainTx_.clear();
    plainOffset_ = 0;
    return true;
}

bool TcpConnection::startTlsHandshake(const std::string &certPem, const std::string &keyPem)
{
    tls_ = std::make_unique<TlsEngine>(fd_, tlsRole());
    // 控制连接作为 TLS server 时（= 本机主动发起的连接）请求对端证书：
    //   - 目的：捕获对端叶证书（验证码/钉扎/CN 校验的数据源）。TLS client 角色由
    //     client 分支的 capture_x509_vtable 直接拿对端证书，server 角色则必须主动请求。
    //   - 容忍缺失（tolerateNoCert）：老客户端/Java 客户端可能不出示证书，
    //     控制连接不能因此失败（与 payload 通道的严格模式区分）。
    ServerClientAuth clientAuth;
    clientAuth.tolerateNoCert = true;
    const ServerClientAuth *authArg = (tlsRole() == TlsRole::Server) ? &clientAuth : nullptr;
    if (!tls_->init(certPem, keyPem, authArg)) {
        LOGE("tls init failed fd=%d", fd_);
        state_ = ConnectionState::Closing;
        return false;
    }
    state_ = ConnectionState::TlsHandshake;
    return true;
}

bool TcpConnection::doTlsHandshake()
{
    if (!tls_ || state_ != ConnectionState::TlsHandshake) {
        return false;
    }
    if (tls_->doHandshake()) {
        state_ = ConnectionState::Encrypted;
        needsSendIdentity_ = true;
        return true;
    }
    if (tls_->lastError() != 0) {
        state_ = ConnectionState::Closing;
        return false;
    }
    return false;
}

bool TcpConnection::tlsHandshakeDone() const
{
    return tls_ && tls_->handshakeDone();
}

// 排空读：反复读直到引擎暂时无数据（EAGAIN）。
// EPOLLET 下必须这样读——一次事件只读一次会把后续数据滞留在引擎里，
// 对端安静时不再有新事件，数据就永远读不出来（REVIEW §4 P1-4）。
ssize_t TcpConnection::fillTlsRx()
{
    if (!tls_ || !tls_->handshakeDone()) {
        return -1;
    }

    std::vector<uint8_t> buf(16384);
    size_t added = 0;
    for (;;) {
        if (rxBuf_.size() > MAX_PACKET_SIZE) {
            LOGE("fillTlsRx fd=%d: rx buffer exceeds %zu bytes", fd_, MAX_PACKET_SIZE);
            return -1;
        }
        ssize_t n = tls_->read(buf);
        if (n < 0) {
            return -1;
        }
        if (n == 0) {
            break;  // 引擎需要更多 socket 数据
        }
        rxBuf_.append(reinterpret_cast<const char *>(buf.data()),
                      static_cast<size_t>(n));
        added += static_cast<size_t>(n);
    }
    return static_cast<ssize_t>(added);
}

// TLS 全写语义已由 TX 队列 + flushTx 承担：writeTls 不再存在，
// 避免「多写者直写 socket」与「队列写」并存导致帧交错。
bool TcpConnection::enqueueTx(std::string data)
{
    if (data.empty()) {
        return true;
    }
    if (txQueuedBytes_ + data.size() > MAX_TX_QUEUE_BYTES) {
        LOGE("enqueueTx fd=%d: tx queue would exceed %zu bytes (%zu queued)",
             fd_, MAX_TX_QUEUE_BYTES, txQueuedBytes_);
        return false;
    }
    txQueuedBytes_ += data.size();
    txQueue_.push_back(std::move(data));
    return true;
}

// 只有网络线程调用（唯一写者）。尽力写：引擎暂不可写就返回，剩余留给 EPOLLOUT/tick 重试。
bool TcpConnection::flushTx()
{
    if (!tls_ || !tls_->handshakeDone()) {
        return true;  // 尚未进入加密态：队列先攒着，握手完成后统一 flush
    }

    while (!txQueue_.empty()) {
        std::string &head = txQueue_.front();
        const uint8_t *base = reinterpret_cast<const uint8_t *>(head.data());
        const size_t remaining = head.size() - txOffset_;

        ssize_t n = tls_->write(base + txOffset_, remaining);
        if (n < 0) {
            return false;
        }
        if (n == 0) {
            return true;  // 引擎输出缓冲满/ socket 不可写：等 EPOLLOUT 或 tick
        }
        txOffset_ += static_cast<size_t>(n);
        if (txOffset_ >= head.size()) {
            txQueuedBytes_ -= head.size();
            txQueue_.pop_front();
            txOffset_ = 0;
        }
    }

    // 队列已空：把引擎里可能残留的加密记录泵出去
    return tls_->pump();
}

void TcpConnection::close()
{
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
    tls_.reset();
    rxBuf_.clear();
    // 会话结束即丢弃待发数据（DevEco MSG160 §2.1）：明文队列与 TX 队列都随连接销毁，
    // 上一会话的 battery/connectivity_report 不会再落到新会话（语义上是旧值）。
    // 丢弃是静默的：不派发任何错误事件（§2.2：避免给用户弹无意义的失败 toast）。
    txQueue_.clear();
    txOffset_ = 0;
    txQueuedBytes_ = 0;
    plainTx_.clear();
    plainOffset_ = 0;
    state_ = ConnectionState::Closed;
}

} // namespace kdeconnect
