#include "net_stack.h"
#include "udp_discovery.h"
#include "cert_util.h"
#include "tcp_server.h"
#include "tcp_connection.h"
#include "packet_io.h"
#include "net_util.h"
#include "net_log.h"
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <algorithm>
#include <chrono>
#include <cstring>

namespace kdeconnect {

namespace {

// 事件循环 tick：定时器检查周期（REVIEW §4 P1-7 最小定时器基建）
constexpr int LOOP_TICK_MS = 200;

int64_t nowMs()
{
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

// 仅接受私网地址直连（WP-2；公网/非法来源直接拒绝）—— 判定实现在 net_util.cpp
// （P1-1：172.16/12 边界曾写错，故独立成 host 可测单元并配边界回归用例）。

// 对端地址取自 socket（identity JSON 无 host 字段；REVIEW §3.4 建议 11）
std::string peerHostOf(int fd)
{
    struct sockaddr_in addr {};
    socklen_t len = sizeof(addr);
    if (getpeername(fd, reinterpret_cast<struct sockaddr *>(&addr), &len) != 0) {
        return {};
    }
    char buf[INET_ADDRSTRLEN] = {0};
    if (inet_ntop(AF_INET, &addr.sin_addr, buf, sizeof(buf)) == nullptr) {
        return {};
    }
    return std::string(buf);
}

} // namespace

NetStack::NetStack()
{
    payload_ = std::make_unique<PayloadManager>(this, std::string(kPayloadSpoolDirDefault));
}

NetStack::~NetStack()
{
    stop();
}

void NetStack::setEventCallback(EventCallback cb)
{
    std::lock_guard<std::mutex> lk(callbackMutex_);
    eventCallback_ = std::move(cb);
}

void NetStack::dispatchEvent(const NetEvent &event)
{
    std::lock_guard<std::mutex> lk(callbackMutex_);
    if (eventCallback_) {
        eventCallback_(event);
    }
}

void NetStack::dispatchError(const std::string &deviceId, int code, const std::string &message)
{
    NetEvent ev {};
    ev.type = EventType::Error;
    ev.deviceId = deviceId;
    ev.errorCode = code;
    ev.errorMessage = message;
    dispatchEvent(ev);
    LOGE("error event: device=%s code=%d msg=%s",
         deviceId.empty() ? "?" : deviceId.c_str(), code, message.c_str());
}

bool NetStack::start(const NetConfig &config)
{
    if (running_.load()) {
        LOGE("net stack already running");
        return false;
    }

    config_ = config;

    epollFd_ = epoll_create1(EPOLL_CLOEXEC);
    if (epollFd_ < 0) {
        LOGE("epoll_create1 failed: %s", strerror(errno));
        return false;
    }

    wakeFd_ = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (wakeFd_ < 0) {
        LOGE("eventfd failed: %s", strerror(errno));
        close(epollFd_);
        epollFd_ = -1;
        return false;
    }
    struct epoll_event ev {};
    ev.events = EPOLLIN;
    ev.data.fd = wakeFd_;
    epoll_ctl(epollFd_, EPOLL_CTL_ADD, wakeFd_, &ev);

    udp_ = std::make_unique<UdpDiscovery>();
    uint16_t tcpPort = config_.tcpPort;
    if (tcpPort == 0) {
        tcpPort = TCP_PORT_MIN;
    }

    if (!udp_->init(config_.deviceId, config_.deviceName, config_.deviceType, tcpPort)) {
        LOGE("udp init failed");
        stop();
        return false;
    }
    struct epoll_event udpEv {};
    udpEv.events = EPOLLIN;
    udpEv.data.fd = udp_->fd();
    epoll_ctl(epollFd_, EPOLL_CTL_ADD, udp_->fd(), &udpEv);

    tcpServer_ = std::make_unique<TcpServer>();
    if (!tcpServer_->listen(tcpPort)) {
        LOGE("tcp listen failed on port %u", tcpPort);
        stop();
        return false;
    }
    struct epoll_event srvEv {};
    srvEv.events = EPOLLIN;
    srvEv.data.fd = tcpServer_->fd();
    epoll_ctl(epollFd_, EPOLL_CTL_ADD, tcpServer_->fd(), &srvEv);

    udp_->broadcast();

    running_.store(true);
    loopThread_ = std::thread(&NetStack::eventLoop, this);

    LOGI("net stack started: deviceId=%s tcpPort=%u", config_.deviceId.c_str(), tcpServer_->port());
    return true;
}

void NetStack::stop()
{
    if (!running_.exchange(false)) {
        return;
    }

    if (wakeFd_ >= 0) {
        uint64_t one = 1;
        write(wakeFd_, &one, sizeof(one));
    }

    if (loopThread_.joinable()) {
        loopThread_.join();
    }

    {
        std::lock_guard<std::mutex> lk(connMutex_);
        for (auto &p : connections_) {
            p.second->close();
        }
        connections_.clear();
    }
    lastSeenMs_.clear();

    if (udp_) { udp_->close(); udp_.reset(); }
    if (tcpServer_) { tcpServer_->close(); tcpServer_.reset(); }

    if (wakeFd_ >= 0) { close(wakeFd_); wakeFd_ = -1; }
    if (epollFd_ >= 0) { close(epollFd_); epollFd_ = -1; }

    LOGI("net stack stopped");
}

bool NetStack::connectToPeer(const std::string &host, uint16_t port)
{
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        LOGE("socket failed: %s", strerror(errno));
        dispatchError({}, errno, std::string("socket failed: ") + strerror(errno));
        return false;
    }

    struct sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1) {
        LOGE("connect: invalid host %s", host.c_str());
        dispatchError({}, EINVAL, "invalid host: " + host);
        close(fd);
        return false;
    }

    int ret = connect(fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr));
    if (ret < 0 && errno != EINPROGRESS) {
        LOGE("connect failed: %s", strerror(errno));
        dispatchError({}, errno, std::string("connect failed: ") + strerror(errno));
        close(fd);
        return false;
    }

    auto conn = std::make_unique<TcpConnection>(fd, false);
    conn->setPeerInfo(host, port);

    {
        std::lock_guard<std::mutex> lk(connMutex_);
        connections_[fd] = std::move(conn);
    }

    struct epoll_event ev {};
    ev.events = EPOLLIN | EPOLLOUT | EPOLLET;
    ev.data.fd = fd;
    epoll_ctl(epollFd_, EPOLL_CTL_ADD, fd, &ev);

    LOGI("connecting to %s:%u (fd=%d)", host.c_str(), port, fd);
    return true;
}

void NetStack::wakeLoop()
{
    if (wakeFd_ >= 0) {
        uint64_t one = 1;
        ssize_t n = write(wakeFd_, &one, sizeof(one));
        (void) n;
    }
}

bool NetStack::sendPacket(const std::string &deviceId, const std::string &packetJson)
{
    std::lock_guard<std::mutex> lk(connMutex_);
    for (auto &p : connections_) {
        TcpConnection &conn = *p.second;
        if (conn.deviceId() != deviceId || conn.state() != ConnectionState::Encrypted) {
            continue;
        }
        // 只入队，不做 I/O：本方法可从 ArkTS 主线程调用（CPP_GUIDE §4 硬约束）。
        // 真正的写由网络线程 flushTx 承担（EPOLLOUT/tick 驱动），
        // 因此不会阻塞 JS 线程，也不会出现多写者帧交错（REVIEW §4 P1-6/P1-3）。
        if (!conn.enqueueTx(packetJson)) {
            dispatchError(deviceId, ENOBUFS, "sendPacket: tx queue full");
            return false;
        }
        // 唤醒网络线程尽快 flush（EPOLLET 下不能指望一定会再有 EPOLLOUT 边沿）
        wakeLoop();
        return true;
    }
    return false;
}

void NetStack::disconnectDevice(const std::string &deviceId)
{
    std::lock_guard<std::mutex> lk(connMutex_);
    bool any = false;
    for (auto it = connections_.begin(); it != connections_.end(); ) {
        if (it->second->deviceId() == deviceId) {
            int fd = it->first;
            epoll_ctl(epollFd_, EPOLL_CTL_DEL, fd, nullptr);
            it->second->close();
            it = connections_.erase(it);
            any = true;
            LOGI("disconnected device %s (fd=%d)", deviceId.c_str(), fd);
        } else {
            ++it;
        }
    }
    if (any) {
        NetEvent ev {};
        ev.type = EventType::Disconnected;
        ev.deviceId = deviceId;
        dispatchEvent(ev);
    }
}

void NetStack::eventLoop()
{
    struct epoll_event events[64];
    while (running_.load()) {
        int n = epoll_wait(epollFd_, events, 64, LOOP_TICK_MS);
        if (n < 0) {
            if (errno == EINTR) continue;
            LOGE("epoll_wait: %s", strerror(errno));
            break;
        }

        for (int i = 0; i < n; ++i) {
            int fd = events[i].data.fd;
            uint32_t ev = events[i].events;

            if (fd == wakeFd_) {
                uint64_t val;
                read(wakeFd_, &val, sizeof(val));
                continue;
            }
            if (udp_ && fd == udp_->fd()) {
                onUdpReadable();
                continue;
            }
            if (tcpServer_ && fd == tcpServer_->fd()) {
                onTcpServerReadable();
                continue;
            }
            if (payload_ && payload_->handlesFd(fd)) {
                if (ev & EPOLLIN) {
                    payload_->onReadable(fd);
                }
                if (ev & EPOLLOUT) {
                    payload_->onWritable(fd);
                }
                if (ev & (EPOLLERR | EPOLLHUP)) {
                    payload_->onReadable(fd);
                }
                continue;
            }

            if (ev & (EPOLLERR | EPOLLHUP)) {
                // 尽量把内核缓冲里的已有数据读完，再无条件关闭（沿旧行为）
                if (ev & EPOLLIN) {
                    onConnectionReadable(fd);
                }
                std::lock_guard<std::mutex> lk(connMutex_);
                closeConnection(fd, "epoll err/hup");
                continue;
            }
            if (ev & EPOLLIN) {
                onConnectionReadable(fd);
            }
            if (ev & EPOLLOUT) {
                onConnectionWritable(fd);
            }
        }

        // 定时器 tick：identity 超时 + 发现超时（DeviceLost）+ TX 续传
        const int64_t now = nowMs();
        if (payload_) {
            payload_->onTick(now);
        }
        // 活跃链路集合：DeviceLost 判定以连接状态为主（P1-2）
        std::vector<std::string> linkedDevices;
        {
            std::lock_guard<std::mutex> lk(connMutex_);
            for (auto it = connections_.begin(); it != connections_.end(); ) {
                TcpConnection &c = *it->second;
                if (c.state() == ConnectionState::PlainIdentity && c.plainExpired(now)) {
                    const int fd = it->first;
                    LOGI("identity timeout fd=%d (host=%s)", fd, c.peerHost().c_str());
                    epoll_ctl(epollFd_, EPOLL_CTL_DEL, fd, nullptr);
                    c.close();
                    it = connections_.erase(it);
                } else {
                    // TX 续传：对端恢复读取且无新 EPOLLOUT 边沿时，靠 tick 兜底写出
                    if (c.state() == ConnectionState::Encrypted && c.txPending() && !c.flushTx()) {
                        const int fd = it->first;
                        LOGE("tick flush failed fd=%d, closing", fd);
                        epoll_ctl(epollFd_, EPOLL_CTL_DEL, fd, nullptr);
                        c.close();
                        it = connections_.erase(it);
                        continue;
                    }
                    if (!c.deviceId().empty() && !c.isClosed()) {
                        linkedDevices.push_back(c.deviceId());
                    }
                    ++it;
                }
            }
        }
        for (auto it = lastSeenMs_.begin(); it != lastSeenMs_.end(); ) {
            // P1-2：KDE/Android 只在启动/网络变化时广播（kdeconnect-kde
            // lanlinkprovider.cpp:149,192；kdeconnect-android LanLinkProvider.java:590,605），
            // 不周期广播 → 「60s 无广播」不等于离线。有活跃链路即在线：刷新时间戳、
            // 不派发 DeviceLost（链路断开后重新起算，给 UI 一个宽限窗口）。
            const bool linked = std::find(linkedDevices.begin(), linkedDevices.end(),
                                          it->first) != linkedDevices.end();
            if (linked) {
                it->second = now;
                ++it;
                continue;
            }
            if (now - it->second > DISCOVERY_TIMEOUT_MS) {
                NetEvent ev {};
                ev.type = EventType::DeviceLost;
                ev.deviceId = it->first;
                LOGI("device lost (no broadcast and no link for %d ms): %s",
                     DISCOVERY_TIMEOUT_MS, it->first.c_str());
                dispatchEvent(ev);
                it = lastSeenMs_.erase(it);
            } else {
                ++it;
            }
        }
    }
}

void NetStack::onUdpReadable()
{
    std::string identity = udp_->readIdentity();
    if (identity.empty()) return;

    DeviceInfo info;
    if (!PacketIO::parseIdentity(identity, info)) {
        LOGE("failed to parse identity from UDP");
        return;
    }

    // native 层自过滤：收到自己的广播直接丢弃，省一次跨线程投递
    if (info.deviceId == config_.deviceId) {
        return;
    }

    const std::string host = udp_->lastSourceHost();
    const int64_t now = nowMs();
    auto seen = lastSeenMs_.find(info.deviceId);
    const bool firstSeen = (seen == lastSeenMs_.end());
    // 同设备去抖：DISCOVERY_DEBOUNCE_MS 内的重复广播不再派发（AGENTS.md 不变量）
    const bool debounced = !firstSeen && (now - seen->second) < DISCOVERY_DEBOUNCE_MS;
    lastSeenMs_[info.deviceId] = now;

    if (debounced) {
        LOGI("device rediscovered within %d ms, ignoring: %s",
             DISCOVERY_DEBOUNCE_MS, info.deviceId.c_str());
        return;
    }

    NetEvent ev {};
    ev.type = EventType::DeviceDiscovered;
    ev.deviceId = info.deviceId;
    ev.deviceName = info.deviceName;
    ev.deviceType = info.deviceType;
    ev.tcpPort = info.tcpPort;
    ev.host = host;
    dispatchEvent(ev);

    LOGI("device discovered: %s (%s) at %s:%u",
         info.deviceId.c_str(), info.deviceName.c_str(), host.c_str(), info.tcpPort);
}

void NetStack::onTcpServerReadable()
{
    int fd = tcpServer_->accept();
    if (fd < 0) return;

    // WP-2：仅接受私网地址（公网/非法来源直接拒绝）
    const std::string host = peerHostOf(fd);
    if (!isPrivateIpv4(host)) {
        LOGE("reject non-private peer %s fd=%d", host.c_str(), fd);
        ::close(fd);
        return;
    }
    // WP-2：同 IP 1000ms 连接限流（KDE/Android 同款语义）
    {
        std::lock_guard<std::mutex> lk(trustMutex_);
        const int64_t now = nowMs();
        auto it = lastAcceptByIp_.find(host);
        if (it != lastAcceptByIp_.end() && now - it->second < CONN_RATE_LIMIT_MS) {
            LOGE("rate limit: %s within %dms, rejecting fd=%d", host.c_str(),
                 CONN_RATE_LIMIT_MS, fd);
            ::close(fd);
            return;
        }
        lastAcceptByIp_[host] = now;
    }

    // 未配对连接数上限（此前该常量只用作 listen backlog，非语义本意）
    {
        std::lock_guard<std::mutex> lk(connMutex_);
        int unpaired = 0;
        for (const auto &p : connections_) {
            if (p.second->deviceId().empty()) ++unpaired;
        }
        if (unpaired >= MAX_UNPAIRED_CONNECTIONS) {
            LOGE("too many unpaired connections (%d), rejecting fd=%d", unpaired, fd);
            close(fd);
            return;
        }
    }

    auto conn = std::make_unique<TcpConnection>(fd, true);
    conn->setPeerInfo(peerHostOf(fd), 0);
    {
        std::lock_guard<std::mutex> lk(connMutex_);
        connections_[fd] = std::move(conn);
    }

    struct epoll_event ev {};
    ev.events = EPOLLIN | EPOLLOUT | EPOLLET;
    ev.data.fd = fd;
    epoll_ctl(epollFd_, EPOLL_CTL_ADD, fd, &ev);

    LOGI("accepted connection fd=%d", fd);
}

void NetStack::closeConnection(int fd, const char *reason)
{
    auto it = connections_.find(fd);
    if (it == connections_.end()) return;
    std::string deviceId = it->second->deviceId();
    epoll_ctl(epollFd_, EPOLL_CTL_DEL, fd, nullptr);
    it->second->close();
    connections_.erase(it);
    LOGI("connection closed: %s (fd=%d, device=%s)", reason, fd,
         deviceId.empty() ? "?" : deviceId.c_str());
    if (!deviceId.empty()) {
        NetEvent ev {};
        ev.type = EventType::Disconnected;
        ev.deviceId = deviceId;
        dispatchEvent(ev);
        if (payload_) {
            payload_->onDeviceDown(deviceId);
        }
    }
}

void NetStack::sendIdentityOverTls(TcpConnection &conn)
{
    std::vector<std::string> inC, outC;
    {
        std::lock_guard<std::mutex> lk(capsMutex_);
        inC = capsIncoming_;
        outC = capsOutgoing_;
    }
    std::string identity = PacketIO::buildIdentity(
        config_.deviceId, config_.deviceName, config_.deviceType,
        tcpServer_ ? tcpServer_->port() : 0, PROTOCOL_VERSION, inC, outC);
    // 入队 + 立即 flush（本函数只由网络线程调用，是唯一写者）
    if (!conn.enqueueTx(identity)) {
        dispatchError(conn.deviceId(), ENOBUFS, "identity: tx queue full");
        return;
    }
    conn.clearNeedsSendIdentity();
    if (!conn.flushTx()) {
        dispatchError(conn.deviceId(), EIO, "identity: tls flush failed");
    } else {
        LOGI("identity queued over TLS on fd=%d (%zu bytes)", conn.fd(), identity.size());
    }
}

// 明文 identity 帧：设置 deviceId/设备信息，派发 pairingRequest，入向连接就地启动 TLS 握手
bool NetStack::handlePlainIdentity(TcpConnection &conn, const std::string &frame)
{
    DeviceInfo info;
    if (!PacketIO::parseIdentity(frame, info)) {
        LOGE("invalid plain identity frame (%zu bytes) fd=%d", frame.size(), conn.fd());
        return false;
    }

    if (info.deviceId == config_.deviceId) {
        LOGE("plain identity from self, closing fd=%d", conn.fd());
        epoll_ctl(epollFd_, EPOLL_CTL_DEL, conn.fd(), nullptr);
        conn.close();
        return false;
    }

    conn.setDeviceId(info.deviceId);
    conn.setPeerInfo(conn.peerHost().empty() ? peerHostOf(conn.fd()) : conn.peerHost(),
                     info.tcpPort, info.deviceName, info.deviceType);

    NetEvent ev {};
    ev.type = EventType::PairingRequest;
    ev.deviceId = info.deviceId;
    ev.deviceName = info.deviceName;
    ev.deviceType = info.deviceType;
    ev.host = conn.peerHost();
    ev.tcpPort = conn.peerPort();
    dispatchEvent(ev);

    if (conn.isIncoming()) {
        if (!conn.startTlsHandshake(config_.certPem, config_.keyPem)) {
            dispatchError(info.deviceId, EIO, "tls init failed");
            epoll_ctl(epollFd_, EPOLL_CTL_DEL, conn.fd(), nullptr);
            conn.close();
            return false;
        }
        LOGI("TLS client handshake started on fd=%d", conn.fd());
        conn.doTlsHandshake();
    }
    return true;
}

// 排空读后按 '\n' 切分：每个完整帧派发一次 packetReceived（帧尾 '\n' 保留，
// ArkTS 侧 PacketRouter 仍按 '\n' 切分即可正确工作）
void NetStack::dispatchFrames(TcpConnection &conn)
{
    std::string frame;
    // 帧循环内不得销毁 conn（引用悬垂）：标记后出循环统一关闭
    bool dropConn = false;
    const char *dropReason = nullptr;
    while (PacketIO::extractFrame(conn.rxBuf(), frame)) {
        if (frame.empty()) {
            continue;  // 超限帧已丢弃
        }
        // 去掉帧尾 '\n' 供 cJSON 解析/事件载荷（JSON 本身不含它）
        std::string json = frame;
        if (!json.empty() && json.back() == '\n') json.pop_back();
        if (json.empty()) continue;

        std::string type;
        std::string body;
        int64_t payloadSize = 0;
        uint16_t payloadPort = 0;
        if (!PacketIO::parsePacket(json, type, body, &payloadSize, &payloadPort)) {
            LOGE("invalid JSON frame dropped (fd=%d, %zu bytes)", conn.fd(), json.size());
            continue;
        }

        if (type == "kdeconnect.identity") {
            DeviceInfo info;
            if (PacketIO::parseIdentity(json, info) && !info.deviceId.empty()) {
                if (conn.deviceId().empty()) {
                    // WP-2：证书钉扎——已登记设备出现证书变更立即断链（TOFU + 钉扎）
                    std::string trustedPem;
                    {
                        std::lock_guard<std::mutex> lk(trustMutex_);
                        auto it = trustedCertPem_.find(info.deviceId);
                        if (it != trustedCertPem_.end()) {
                            trustedPem = it->second;
                        }
                        // 同 deviceId 1000ms 连接限流（identity 阶段判定）
                        auto lit = lastConnByDevice_.find(info.deviceId);
                        if (lit != lastConnByDevice_.end() &&
                            nowMs() - lit->second < CONN_RATE_LIMIT_MS) {
                            LOGE("rate limit: device %s reconnect within %dms",
                                 info.deviceId.c_str(), CONN_RATE_LIMIT_MS);
                            dispatchError(info.deviceId, ECONNREFUSED,
                                          "connection rate limited");
                            dropConn = true;
                            dropReason = "device rate limited";
                            break;
                        }
                        lastConnByDevice_[info.deviceId] = nowMs();
                    }
                    if (!trustedPem.empty() && conn.tlsEngine() != nullptr) {
                        std::vector<uint8_t> leaf = conn.tlsEngine()->peerLeafCertDer();
                        const std::string trustedDer = pemToDer(trustedPem, "CERTIFICATE");
                        const std::string leafStr(leaf.begin(), leaf.end());
                        if (leafStr.empty() || leafStr != trustedDer) {
                            LOGE("certificate mismatch for %s, dropping", info.deviceId.c_str());
                            dispatchError(info.deviceId, EACCES,
                                          "certificate mismatch (device re-pair required)");
                            dropConn = true;
                            dropReason = "certificate mismatch";
                            break;
                        }
                    }
                    conn.setDeviceId(info.deviceId);
                }
                conn.setPeerInfo(conn.peerHost(), conn.peerPort(), info.deviceName, info.deviceType);
                NetEvent pev {};
                pev.type = EventType::PairingRequest;
                pev.deviceId = info.deviceId;
                pev.deviceName = info.deviceName;
                pev.deviceType = info.deviceType;
                pev.host = conn.peerHost();
                pev.tcpPort = conn.peerPort();
                dispatchEvent(pev);
                LOGI("peer identity over TLS: %s (%s)", info.deviceId.c_str(), info.deviceName.c_str());
                if (!conn.connectedNotified()) {
                    conn.markConnectedNotified();
                    NetEvent cev {};
                    cev.type = EventType::Connected;
                    cev.deviceId = conn.deviceId();
                    cev.deviceName = conn.peerName();
                    cev.deviceType = conn.peerType();
                    cev.host = conn.peerHost();
                    cev.role = conn.tlsRole();
                    dispatchEvent(cev);
                    LOGI("connected device=%s fd=%d role=%s", conn.deviceId().c_str(),
                         conn.fd(), conn.tlsRole() == TlsRole::Server ? "server" : "client");
                }
            }
            continue;
        }

        uint64_t xferId = 0;
        if (payloadSize != 0 && payloadPort != 0 && !conn.deviceId().empty()) {
            // P1-3（A10）：只对已配对/已钉扎的设备自动拉取 payload。
            // 未配对设备推送带 payload 的帧 → 不建拉取任务（spool 不落文件）+ error 事件；
            // 帧本身仍派发（ArkTS PacketRouter 自行判定策略）。
            bool trusted = false;
            {
                std::lock_guard<std::mutex> lk(trustMutex_);
                trusted = trustedCertPem_.count(conn.deviceId()) != 0;
            }
            if (trusted) {
                // 收到带 payload 的帧：自动建 payload 拉取任务（spool 落盘，设计 v0.2 §2）
                xferId = payload_->startReceive(conn.deviceId(), conn.peerHost(),
                                                payloadPort, payloadSize, body);
            } else {
                LOGE("payload push from untrusted device %s rejected (port=%u size=%lld)",
                     conn.deviceId().c_str(), payloadPort, (long long) payloadSize);
                dispatchError(conn.deviceId(), EACCES,
                              "payload rejected: device not paired/trusted");
            }
        }

        NetEvent ev {};
        ev.type = EventType::PacketReceived;
        ev.payloadTransferId = xferId;
        ev.deviceId = conn.deviceId();
        ev.packet = frame;  // 保留帧尾 '\n'（ArkTS 现有切分逻辑依赖它）
        ev.payloadSize = payloadSize;
        ev.payloadTransferPort = payloadPort;
        dispatchEvent(ev);
    }
    if (dropConn) {
        closeConnection(conn.fd(), dropReason);
    }
}

void NetStack::onConnectionReadable(int fd)
{
    std::lock_guard<std::mutex> lk(connMutex_);
    auto it = connections_.find(fd);
    if (it == connections_.end()) return;
    TcpConnection &conn = *it->second;

    if (conn.state() == ConnectionState::Idle || conn.state() == ConnectionState::PlainIdentity) {
        std::string frame;
        ssize_t n = conn.readPlainFrame(frame, MAX_IDENTITY_PACKET_SIZE);
        if (n < 0) {
            dispatchError(conn.deviceId(), EIO, "plain identity read failed");
            closeConnection(fd, "plain identity failed");
            return;
        }
        if (n == 0) {
            return;  // 半包，等下次可读事件
        }
        if (!handlePlainIdentity(conn, frame)) {
            if (conn.isClosed()) {
                connections_.erase(fd);
            }
            return;
        }
        return;
    }

    if (conn.state() == ConnectionState::TlsHandshake) {
        if (conn.doTlsHandshake()) {
            if (conn.isIncoming() && !conn.connectedNotified()) {
                conn.markConnectedNotified();
                NetEvent ev {};
                ev.type = EventType::Connected;
                ev.deviceId = conn.deviceId();
                ev.deviceName = conn.peerName();
                ev.deviceType = conn.peerType();
                ev.host = conn.peerHost();
                ev.role = conn.tlsRole();
                dispatchEvent(ev);
                LOGI("connected device=%s fd=%d role=%s", conn.deviceId().c_str(),
                     fd, conn.tlsRole() == TlsRole::Server ? "server" : "client");
            }
            if (conn.needsSendIdentity()) {
                sendIdentityOverTls(conn);
            }
        } else if (conn.state() == ConnectionState::Closing) {
            dispatchError(conn.deviceId(), EIO, "tls handshake failed");
            closeConnection(fd, "tls handshake failed");
        }
        return;
    }

    if (conn.state() == ConnectionState::Encrypted) {
        if (conn.needsSendIdentity()) {
            sendIdentityOverTls(conn);
        }
        // 排空读：EPOLLET 下必须读到 EAGAIN，否则数据滞留引擎里（REVIEW §4 P1-4）
        ssize_t n = conn.fillTlsRx();
        if (n < 0) {
            dispatchError(conn.deviceId(), EIO, "tls read failed");
            closeConnection(fd, "tls read failed");
            return;
        }
        if (n == 0) {
            return;
        }
        dispatchFrames(conn);
    }
}

void NetStack::onConnectionWritable(int fd)
{
    std::lock_guard<std::mutex> lk(connMutex_);
    auto it = connections_.find(fd);
    if (it == connections_.end()) return;

    TcpConnection &conn = *it->second;

    if (conn.state() == ConnectionState::Idle && !conn.isIncoming()) {
        // TCP 已连上（EPOLLOUT 就绪）：发明文 identity，然后立刻起 TLS server 握手
        std::vector<std::string> inC, outC;
        {
            std::lock_guard<std::mutex> lk(capsMutex_);
            inC = capsIncoming_;
            outC = capsOutgoing_;
        }
        std::string identity = PacketIO::buildIdentity(
            config_.deviceId, config_.deviceName, config_.deviceType,
            tcpServer_ ? tcpServer_->port() : 0, PROTOCOL_VERSION, inC, outC);
        if (!conn.writePlainAll(reinterpret_cast<const uint8_t *>(identity.data()),
                                identity.size())) {
            dispatchError(conn.deviceId(), EIO, "plain identity write failed");
            closeConnection(fd, "plain identity write failed");
            return;
        }

        if (!conn.startTlsHandshake(config_.certPem, config_.keyPem)) {
            dispatchError(conn.deviceId(), EIO, "tls init failed");
            closeConnection(fd, "tls init failed");
            return;
        }
        LOGI("TLS server handshake started on fd=%d", fd);
        conn.doTlsHandshake();
        return;
    }

    if (conn.state() == ConnectionState::TlsHandshake) {
        if (conn.doTlsHandshake()) {
            if (conn.needsSendIdentity()) {
                sendIdentityOverTls(conn);
            }
        } else if (conn.state() == ConnectionState::Closing) {
            dispatchError(conn.deviceId(), EIO, "tls handshake failed");
            closeConnection(fd, "tls handshake failed");
        }
        return;
    }

    if (conn.state() == ConnectionState::Encrypted && conn.needsSendIdentity()) {
        sendIdentityOverTls(conn);
    }

    // EPOLLOUT 就绪：把 TX 队列里积压的数据（可能含大帧的剩余部分）继续写出
    if (conn.state() == ConnectionState::Encrypted) {
        if (!conn.flushTx()) {
            dispatchError(conn.deviceId(), EIO, "tls flush failed");
            closeConnection(fd, "tls flush failed");
        }
    }
}

NetStack &netStack()
{
    static NetStack instance;
    return instance;
}

} // namespace kdeconnect

// —————— PayloadHost / WP-1b 公共入口 ——————

namespace kdeconnect {

int64_t NetStack::nowMs()
{
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

// 已知的对端证书 PEM：活连接上的对端叶证书（最新）→ 信任存储（ArkTS 回灌，WP-2 钉扎）
// → 掉线后的缓存。调用链（payload send 方向 → TLS server client-auth 的 CA 名）在
// NAPI/JS 线程，**不在 PayloadManager::mu_ 内**，故可安全取 connMutex_/trustMutex_（P0-3）。
std::string NetStack::peerCertPem(const std::string &deviceId)
{
    {
        std::lock_guard<std::mutex> lk(connMutex_);
        for (auto &p : connections_) {
            TcpConnection &c = *p.second;
            if (c.deviceId() != deviceId || c.tlsEngine() == nullptr) {
                continue;
            }
            std::vector<uint8_t> der = c.tlsEngine()->peerLeafCertDer();
            if (!der.empty()) {
                return derToPem("CERTIFICATE", der.data(), der.size());
            }
        }
    }
    {
        std::lock_guard<std::mutex> lk(trustMutex_);
        auto it = trustedCertPem_.find(deviceId);
        if (it != trustedCertPem_.end()) {
            return it->second;
        }
    }
    std::lock_guard<std::mutex> lk(connMutex_);
    auto it = peerCertPemCache_.find(deviceId);
    return it != peerCertPemCache_.end() ? it->second : std::string();
}

bool NetStack::epollAdd(int fd, uint32_t events)
{
    epoll_event ev {};
    ev.events = events | EPOLLET;
    ev.data.fd = fd;
    return epoll_ctl(epollFd_, EPOLL_CTL_ADD, fd, &ev) == 0;
}

void NetStack::epollDel(int fd)
{
    epoll_ctl(epollFd_, EPOLL_CTL_DEL, fd, nullptr);
}

bool NetStack::sendControlFrame(const std::string &deviceId, const std::string &frame)
{
    return sendPacket(deviceId, frame);
}

uint64_t NetStack::sendPayload(const std::string &deviceId, const std::string &type,
                               const std::string &bodyJson, const std::string &filePath)
{
    if (payload_ == nullptr) {
        return 0;
    }
    return payload_->startSend(deviceId, type, bodyJson, filePath);
}

bool NetStack::payloadSettle(uint64_t id, const std::string &destPath, bool keep)
{
    return payload_ != nullptr && payload_->settle(id, destPath, keep);
}

void NetStack::payloadCancel(uint64_t id)
{
    if (payload_ != nullptr) {
        payload_->cancel(id);
    }
}

// —— WP-2 安全加固 ——

void NetStack::setTrustedCertificate(const std::string &deviceId, const std::string &certPem)
{
    std::lock_guard<std::mutex> lk(trustMutex_);
    trustedCertPem_[deviceId] = certPem;
}

void NetStack::removeTrustedCertificate(const std::string &deviceId)
{
    std::lock_guard<std::mutex> lk(trustMutex_);
    trustedCertPem_.erase(deviceId);
}


std::string NetStack::getPeerCertificate(const std::string &deviceId)
{
    std::lock_guard<std::mutex> lk(connMutex_);
    for (auto &p : connections_) {
        TcpConnection &c = *p.second;
        if (c.deviceId() == deviceId && c.state() == ConnectionState::Encrypted &&
            c.tlsEngine() != nullptr) {
            std::vector<uint8_t> der = c.tlsEngine()->peerLeafCertDer();
            if (!der.empty()) {
                std::string pem = derToPem("CERTIFICATE", der.data(), der.size());
                peerCertPemCache_[deviceId] = pem;
                return pem;
            }
        }
    }
    // 掉线后保留（MSG43_TO_ZCODE §1.4）：命中缓存则返回，否则空串
    // （缓存读写一律在 connMutex_ 内，避免与 peerCertPem() 并发访问）
    auto it = peerCertPemCache_.find(deviceId);
    return it != peerCertPemCache_.end() ? it->second : std::string();
}

std::string NetStack::getOwnCertificate()
{
    // 与 generateCert 产出的同一份（d.ts v2 语义：两端一致才能算对验证码）
    return config_.certPem;
}

std::string NetStack::getPairVerificationCode(const std::string &deviceId,
                                              int64_t pairingTimestamp)
{
    std::string peerCertDer;
    {
        std::lock_guard<std::mutex> lk(connMutex_);
        for (auto &p : connections_) {
            TcpConnection &c = *p.second;
            if (c.deviceId() == deviceId && c.state() == ConnectionState::Encrypted &&
                c.tlsEngine() != nullptr) {
                std::vector<uint8_t> der = c.tlsEngine()->peerLeafCertDer();
                peerCertDer.assign(der.begin(), der.end());
                break;
            }
        }
        if (peerCertDer.empty()) {
            // 掉线后仍可查询验证码（与 getPeerCertificate 同一缓存策略）
            auto it = peerCertPemCache_.find(deviceId);
            if (it != peerCertPemCache_.end()) {
                peerCertDer = pemToDer(it->second, "CERTIFICATE");
            }
        }
    }
    std::string peerSpki;
    if (!peerCertDer.empty()) {
        peerSpki = extractSpkiDer(reinterpret_cast<const uint8_t *>(peerCertDer.data()),
                                  peerCertDer.size());
    }
    if (peerSpki.empty()) {
        return std::string();
    }
    if (!ownSpkiDone_) {
        const std::string ownDer = pemToDer(config_.certPem, "CERTIFICATE");
        ownSpkiDer_ = ownDer.empty()
                          ? std::string()
                          : extractSpkiDer(reinterpret_cast<const uint8_t *>(ownDer.data()),
                                           ownDer.size());
        ownSpkiDone_ = true;
    }
    if (ownSpkiDer_.empty()) {
        return std::string();
    }
    return computeVerificationCode(ownSpkiDer_, peerSpki, pairingTimestamp);
}

void NetStack::setCapabilities(const std::vector<std::string> &incomingCaps,
                               const std::vector<std::string> &outgoingCaps)
{
    {
        std::lock_guard<std::mutex> lk(capsMutex_);
        capsIncoming_ = incomingCaps;
        capsOutgoing_ = outgoingCaps;
    }
    if (udp_) {
        udp_->setCapabilities(incomingCaps, outgoingCaps);
    }
    // 向已建加密链路重发 identity（对端据此重算插件装载；d.ts v2 语义）
    std::lock_guard<std::mutex> lk(connMutex_);
    for (auto &p : connections_) {
        TcpConnection &c = *p.second;
        if (c.state() == ConnectionState::Encrypted && !c.deviceId().empty()) {
            sendIdentityOverTls(c);
        }
    }
}


} // namespace kdeconnect
