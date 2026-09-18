#include "net_stack.h"
#include "net_internal.h"
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
#include <cstdarg>
#include <ctime>
#include <cstring>
#include "net_internal.h"

// net_stack_link.cpp —— 连接级：accept / 明文 identity / TLS 读写 / 帧派发 / 链路关闭
// （S5-b：自 net_stack.cpp 原样搬入，仅新增 include；行为零变化）

namespace kdeconnect {

void NetStack::onTcpServerReadable()
{
    // EPOLLET 下监听套接字必须「accept 到 EAGAIN 为止」：只 accept 一个连接时，backlog 中
    // 剩余连接会让监听套接字保持可读，而 ET 不会再补边沿 ⇒ 那些连接会一直卡在 backlog 里
    // （真机形态：冷启动时两台对端几乎同时连入，结果只进来一台）。
    // 注意：被限流/被拒的连接必须 `continue` 继续排空，不能 `return`（否则同样留下 pending）。
    for (;;) {
        int fd = tcpServer_->accept();
        if (fd < 0) {
            return;  // EAGAIN（无更多连接）或真错误：本轮结束
        }

        // WP-2：仅接受私网地址（公网/非法来源直接拒绝）
        const std::string host = peerHostOf(fd);
        if (!isPrivateIpv4(host)) {
            LOGE("reject non-private peer %s fd=%d", host.c_str(), fd);
            ::close(fd);
            continue;
        }
        // WP-2：同 IP 1000ms 连接限流（KDE/Android 同款语义）
        {
            std::lock_guard<std::mutex> lk(trustMutex_);
            const int64_t now = nowMs();
            auto it = lastAcceptByIp_.find(host);
            if (it != lastAcceptByIp_.end() && now - it->second < CONN_RATE_LIMIT_MS) {
                deferLogf("E ", "rate limit: %s within %dms, rejecting fd=%d", host.c_str(),
                     CONN_RATE_LIMIT_MS, fd);  // S2b: trustMutex_ 临界区内
                ::close(fd);
                continue;
            }
            lastAcceptByIp_[host] = now;
        }

        // 未配对连接数上限（此前该常量只用作 listen backlog，非语义本意）
        {
            HoldTimer _hold("onTcpServerReadable");
            std::lock_guard<std::mutex> lk(connMutex_);
            int unpaired = 0;
            for (const auto &p : connections_) {
                if (p.second->deviceId().empty()) ++unpaired;
            }
            if (unpaired >= MAX_UNPAIRED_CONNECTIONS) {
                deferLogf("E ", "too many unpaired connections (%d), rejecting fd=%d", unpaired, fd);  // S2b
                ::close(fd);
                continue;
            }
        }

        auto conn = std::make_unique<TcpConnection>(fd, true);
        conn->setPeerInfo(peerHostOf(fd), 0);
        {
            HoldTimer _hold("onTcpServerReadable");
            std::lock_guard<std::mutex> lk(connMutex_);
            connections_[fd] = std::move(conn);
        }

        struct epoll_event ev {};
        // 入向连接不立刻写（本侧不发明文 identity）⇒ **不挂 EPOLLOUT**：等真有字节要写时
        // 由 updateWriteInterest 挂上（P0-b2-c：避免 EPOLLET 下"无可写内容仍被反复上报"烧核）。
        ev.events = EPOLLIN | EPOLLET;
        ev.data.fd = fd;
        epoll_ctl(epollFd_, EPOLL_CTL_ADD, fd, &ev);

        LOGI("accepted connection fd=%d", fd);
    }
}

void NetStack::updateWriteInterestLocked(int fd)
{
    auto it = connections_.find(fd);
    if (it == connections_.end()) {
        return;
    }
    TcpConnection &conn = *it->second;
    const bool want = conn.wantsWrite();
    if (want == conn.epollWriteArmed()) {
        return;   // 状态未变：绝不重复 MOD（MOD 会重新武装 ET 并立即上报）
    }
    struct epoll_event ev {};
    ev.events = EPOLLIN | EPOLLET | (want ? EPOLLOUT : 0u);
    ev.data.fd = fd;
    if (epoll_ctl(epollFd_, EPOLL_CTL_MOD, fd, &ev) == 0) {
        conn.setEpollWriteArmed(want);
    } else {
        deferLogf("E ", "updateWriteInterest fd=%d: epoll_ctl MOD failed: %s", fd, strerror(errno));  // S2b: 锁内/锁外双路径调用
    }
}

void NetStack::updateWriteInterest(int fd)
{
    HoldTimer _hold("updateWriteInterest");
    std::lock_guard<std::mutex> lk(connMutex_);
    updateWriteInterestLocked(fd);
}

void NetStack::closeConnection(int fd, const char *reason)
{
    auto it = connections_.find(fd);
    if (it == connections_.end()) return;
    std::string deviceId = it->second->deviceId();
    epoll_ctl(epollFd_, EPOLL_CTL_DEL, fd, nullptr);
    it->second->close();
    connections_.erase(it);
    deferLogf("I ", "connection closed: %s (fd=%d, device=%s)", reason, fd,
             deviceId.empty() ? "?" : deviceId.c_str());  // S2b: closeConnection 恒持锁被调（网络/JS 两线程）
    if (!deviceId.empty()) {
        // "新链路替换旧链路"场景：同设备仍有存活的另一条链路时**不报 Disconnected**，
        // 否则 UI 会先收到新链路的 Connected、又被这条 Disconnected 抹掉（设备列表变空）。
        bool sameDeviceAlive = false;
        for (const auto &p : connections_) {
            if (p.second->deviceId() == deviceId) {
                sameDeviceAlive = true;
                break;
            }
        }
        if (!sameDeviceAlive) {
            NetEvent ev {};
            ev.type = EventType::Disconnected;
            ev.deviceId = deviceId;
            dispatchEvent(ev);
            // 载荷随「设备级」失联而中止：与 Disconnected 同口径。
            // 修复前此处**无条件**调用 onDeviceDown ⇒ 链路替换/重复连接关闭时（上面刚判定
            // "仍有存活链路"）也会把所有在传载荷判 failed/ECONNRESET("control connection closed")
            // ⇒ 真机现象：1.4MB 文件传到 39% 被中止（DevEco MSG24，code=104）。
            // payload 任务自带 fd/TLS，独立于任何单条控制链路，故链路换代必须让它继续。
            if (payload_) {
                payload_->onDeviceDown(deviceId);
            }
        } else {
            deferLogf("I ", "link replaced: %s still has a live link, suppressing Disconnected", deviceId.c_str());  // S2b
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
        deferLogf("I ", "identity queued over TLS on fd=%d (%zu bytes)", conn.fd(), identity.size());  // S2b
    }
}

bool NetStack::handlePlainIdentity(TcpConnection &conn, const std::string &frame)
{
    DeviceInfo info;
    if (!PacketIO::parseIdentity(frame, info)) {
        deferLogf("E ", "invalid plain identity frame (%zu bytes) fd=%d", frame.size(), conn.fd());  // S2b
        return false;
    }

    if (info.deviceId == config_.deviceId) {
        deferLogf("E ", "plain identity from self, closing fd=%d", conn.fd());  // S2b
        epoll_ctl(epollFd_, EPOLL_CTL_DEL, conn.fd(), nullptr);
        conn.close();
        return false;
    }

    conn.setDeviceId(info.deviceId);
    conn.setPeerInfo(conn.peerHost().empty() ? peerHostOf(conn.fd()) : conn.peerHost(),
                     info.tcpPort, info.deviceName, info.deviceType);
    // KDE 拨入的 identity 不含 tcpPort ⇒ 这里通常为 0（不影响拨入本身）；有值（其他实现）就记缓存
    rememberPeerPort(conn.peerHost(), info.tcpPort);

    // 对端主动连入 = 我们确知该设备在线。这里补发 deviceDiscovered，
    // 使「发现列表」不只依赖对端的 UDP 广播（对端只在启动/网络变化时广播，
    // 后启动的一方会永远看不到它——这正是「发现页空」的成因）。
    {
        NetEvent dev {};
        dev.type = EventType::DeviceDiscovered;
        dev.deviceId = info.deviceId;
        dev.deviceName = info.deviceName;
        dev.deviceType = info.deviceType;
        dev.host = conn.peerHost();
        dev.tcpPort = info.tcpPort;
        dispatchEvent(dev);
    }

    NetEvent ev {};
    ev.type = EventType::PairingRequest;
    ev.deviceId = info.deviceId;
    ev.deviceName = info.deviceName;
    ev.deviceType = info.deviceType;
    ev.host = conn.peerHost();
    ev.tcpPort = conn.peerPort();
    dispatchEvent(ev);

    if (conn.isIncoming()) {
        // 入向连接同样设握手上限：半死/恶意连接不应长期占用一个连接槽
        conn.setHandshakeDeadline(nowMs() + handshakeTimeoutMs());
        if (!conn.startTlsHandshake(config_.certPem, config_.keyPem)) {
            dispatchError(info.deviceId, EIO, "tls init failed");
            epoll_ctl(epollFd_, EPOLL_CTL_DEL, conn.fd(), nullptr);
            conn.close();
            return false;
        }
        deferLogf("I ", "TLS client handshake started on fd=%d", conn.fd());  // S2: 临界区内→延迟打
        conn.doTlsHandshake();
    }
    return true;
}

void NetStack::dispatchFrames(std::unique_lock<std::mutex> &lk, TcpConnection &conn)
{
    // ————————— 阶段 1（持锁）：搬运 —————————
    const int fd = conn.fd();
    const std::string peerHost = conn.peerHost();
    const uint16_t peerPort = conn.peerPort();
    const bool isIncoming = conn.isIncoming();
    const TlsRole tlsRole = conn.tlsRole();
    std::string deviceId = conn.deviceId();
    bool connectedNotified = conn.connectedNotified();
    // 帧普查（CodeArts MSG9 P0 收尾用）：一次 drain 里有多少帧、多少字节、最大帧多大。
    // 第 N 次进入（进程内累计）：区分"首次/惰性初始化"与"稳态每帧开销"（DevEco MSG16 §2）。
    static std::atomic<uint64_t> s_dispatchSeq{1};
    const uint64_t _dispatchSeq = s_dispatchSeq.fetch_add(1, std::memory_order_relaxed);
    std::vector<std::string> frames;
    std::string leafCert;   // 本批含 identity 帧时，钉扎比较需要本连接的叶证书（在锁内取一次）
    {
        std::string frame;
        while (PacketIO::extractFrame(conn.rxBuf(), frame)) {
            if (frame.empty()) {
                continue;   // 超限帧已丢弃
            }
            if (leafCert.empty() && conn.tlsEngine() != nullptr &&
                frame.find("kdeconnect.identity") != std::string::npos) {
                const std::vector<uint8_t> leaf = conn.tlsEngine()->peerLeafCertDer();
                leafCert.assign(leaf.begin(), leaf.end());
            }
            frames.push_back(std::move(frame));
        }
    }
    if (frames.empty()) {
        return;   // 无完整帧（锁保持由调用方继续持有）
    }

    // ————————— 阶段 2（放锁）：解析 + 决策 + 派发 —————————
    lk.unlock();
    int64_t _censusFrames = 0;
    int64_t _censusBytes = 0;
    size_t _censusMaxFrame = 0;
    const int64_t _censusT0 = monoMs();
    bool dropConn = false;
    std::string dropReason;
    bool abortBatch = false;

    for (const std::string &raw : frames) {
        if (abortBatch) {
            break;   // 连接已消失/已判死：本批剩余帧作废（与旧实现的 break/return 语义一致）
        }
        std::string json = raw;
        if (!json.empty() && json.back() == '\n') json.pop_back();   // JSON 本身不含帧尾 '\n'
        if (json.empty()) continue;
        ++_censusFrames;
        _censusBytes += static_cast<int64_t>(json.size());
        if (json.size() > _censusMaxFrame) _censusMaxFrame = json.size();

        std::string type;
        std::string body;
        int64_t payloadSize = 0;
        uint16_t payloadPort = 0;
        if (!PacketIO::parsePacket(json, type, body, &payloadSize, &payloadPort)) {   // 锁外解析
            deferLogf("E ", "invalid JSON frame dropped (fd=%d, %zu bytes)", fd, json.size());
            continue;
        }

        if (type == "kdeconnect.identity") {
            DeviceInfo info;
            if (PacketIO::parseIdentity(json, info) && !info.deviceId.empty()) {
                if (deviceId.empty()) {   // 本连接首见身份：钉扎比较 + 替换同设备旧链路
                    std::string trustedPem;
                    {
                        std::lock_guard<std::mutex> tlk(trustMutex_);
                        auto it = trustedCertPem_.find(info.deviceId);
                        if (it != trustedCertPem_.end()) {
                            trustedPem = it->second;
                        }
                        lastConnByDevice_[info.deviceId] = nowMs();
                    }
                    // 钉扎比较：证书不一致 ⇒ 断链（TOFU + 钉扎），且本批不再继续
                    if (!trustedPem.empty() && !leafCert.empty()) {
                        const std::string trustedDer = pemToDer(trustedPem, "CERTIFICATE");
                        if (leafCert != trustedDer) {
                            deferLogf("E ", "certificate mismatch for %s, dropping", info.deviceId.c_str());
                            dispatchError(info.deviceId, EACCES,
                                          "certificate mismatch (device re-pair required)");
                            dropConn = true;
                            dropReason = "certificate mismatch";
                            abortBatch = true;
                            continue;
                        }
                    }
                    // 短临界区回写：替换同设备旧链路 + 写入身份
                    lk.lock();
                    auto it2 = connections_.find(fd);
                    if (it2 == connections_.end()) {
                        lk.unlock();
                        abortBatch = true;   // 连接已被回收：本批作废
                        continue;
                    }
                    TcpConnection &c2 = *it2->second;
                    std::vector<int> stale;
                    for (const auto &p2 : connections_) {
                        if (p2.first != fd && p2.second->deviceId() == info.deviceId) {
                            stale.push_back(p2.first);
                        }
                    }
                    for (int sfd : stale) {
                        deferLogf("I ", "replacing stale link for device %s: closing fd=%d",
                                  info.deviceId.c_str(), sfd);
                        closeConnection(sfd, "replaced by newer link");   // 同设备仍有本连接 ⇒ 不报 Disconnected
                    }
                    c2.setDeviceId(info.deviceId);
                    c2.setPeerInfo(peerHost, peerPort, info.deviceName, info.deviceType);
                    deviceId = info.deviceId;
                    lk.unlock();
                } else {
                    // 身份已知（或本批前帧刚写入）：仅刷新 peer 信息
                    lk.lock();
                    auto it2 = connections_.find(fd);
                    if (it2 != connections_.end()) {
                        it2->second->setPeerInfo(peerHost, peerPort, info.deviceName, info.deviceType);
                    }
                    lk.unlock();
                }

                NetEvent pev {};
                pev.type = EventType::PairingRequest;
                pev.deviceId = info.deviceId;
                pev.deviceName = info.deviceName;
                pev.deviceType = info.deviceType;
                pev.host = peerHost;
                pev.tcpPort = peerPort;
                dispatchEvent(pev);
                deferLogf("I ", "peer identity over TLS: %s (%s)", info.deviceId.c_str(),
                          info.deviceName.c_str());
                if (!connectedNotified) {
                    connectedNotified = true;
                    lk.lock();
                    auto it3 = connections_.find(fd);
                    if (it3 != connections_.end()) {
                        it3->second->markConnectedNotified();
                    }
                    lk.unlock();
                    NetEvent cev {};
                    cev.type = EventType::Connected;
                    cev.deviceId = deviceId;
                    cev.deviceName = info.deviceName;
                    cev.deviceType = info.deviceType;
                    cev.host = peerHost;
                    // 出向连接：peerPort 即拨号目标端口（对端真实监听端口）；入向连接的对端端口是
                    // 临时端口，报了反而误导，故保持 0。
                    if (!isIncoming) {
                        cev.tcpPort = peerPort;
                        rememberPeerPort(peerHost, peerPort);   // 仅出向：缓存"验证过的端口"
                    }
                    cev.role = tlsRole;
                    dispatchEvent(cev);
                    deferLogf("I ", "connected device=%s fd=%d role=%s", deviceId.c_str(), fd,
                              tlsRole == TlsRole::Server ? "server" : "client");
                }
            }
            // 注意（P0，2026-09-13）：identity 帧**必须继续走下面的 PacketReceived 派发**，
            // 不能 `continue` 跳过——ArkTS 的 PacketRouter.handleIdentity/onPeerCapabilities
            // 依赖它做能力协商（caps），跳过会导致 PluginHost 永不装载插件，
            // 现象是「配对成功、连上了，但对端发来的 packet 全部 unhandled」。
        }

        uint64_t xferId = 0;
        if (payloadSize != 0 && payloadPort != 0 && !deviceId.empty()) {
            // P1-3（A10）：只对已配对/已钉扎的设备自动拉取 payload；未信任 ⇒ 不建任务（spool 不落文件）
            bool trusted = false;
            {
                std::lock_guard<std::mutex> tlk(trustMutex_);
                trusted = trustedCertPem_.count(deviceId) != 0;
            }
            if (trusted) {
                // 锁外调用：PayloadManager 自带 mu_，锁序 connMutex_ → mu_ 允许（此处未持 connMutex_）
                xferId = payload_->startReceive(deviceId, peerHost, payloadPort, payloadSize, body);
            } else {
                deferLogf("E ", "[KDC-PAYLOAD] push rejected: device %s not trusted "
                                "(port=%u size=%lld)", deviceId.c_str(), payloadPort,
                          (long long) payloadSize);
                dispatchError(deviceId, EACCES, "payload rejected: device not paired/trusted");
            }
        }

        // 载荷已宣告但未启动：ArkTS 若据 payloadSize 建「接收中」条目会永久悬挂（DevEco MSG22）
        if (payloadSize != 0 && xferId == 0) {
            const char *why = payloadPort == 0    ? "port missing/0"
                              : deviceId.empty()  ? "deviceId unknown"
                                                  : "not trusted";
            std::string head = raw.substr(0, 160);
            for (char &ch : head) {
                if (ch == '\n' || ch == '\r') ch = ' ';
            }
            deferLogf("W ", "[KDC-PAYLOAD] announced but NOT started: fd=%d type=%s size=%lld "
                            "port=%u why=%s head=%s",
                      fd, type.c_str(), (long long) payloadSize, payloadPort, why, head.c_str());
            dispatchError(deviceId, EIO, std::string("payload not started (") + why + ")");
        }

        NetEvent ev {};
        ev.type = EventType::PacketReceived;
        ev.payloadTransferId = xferId;
        ev.deviceId = deviceId;
        ev.packet = raw;   // 保留帧尾 '\n'（ArkTS 现有切分逻辑依赖它）
        ev.payloadSize = payloadSize;
        ev.payloadTransferPort = payloadPort;
        dispatchEvent(ev);
    }

    const int64_t _censusMs = monoMs() - _censusT0;
    lk.lock();   // 恢复调用方的不变式（返回时 connMutex_ 必须已持有）
    if (_censusMs > 100) {
        deferLogf("I ", "[KDC-FRAMESPLIT] n=%llu frames=%lld bytes=%lld maxFrame=%llu total=%lldms",
                  (unsigned long long) _dispatchSeq, (long long) _censusFrames,
                  (long long) _censusBytes, (unsigned long long) _censusMaxFrame,
                  (long long) _censusMs);
    }
    if (dropConn) {
        closeConnection(fd, dropReason.c_str());
    }
}

void NetStack::pumpPlainIdentity(TcpConnection &conn)
{
    const int fd = conn.fd();
    std::string frame;
    int plainErr = EIO;
    ssize_t n = conn.readPlainFrame(frame, MAX_IDENTITY_PACKET_SIZE, &plainErr);
    if (n < 0) {
        if (conn.isIncoming()) {
            dispatchError(conn.deviceId(), EIO, "plain identity read failed");
        } else {
            // 出向：这才是用户「点连接」失败的真实原因（拒绝/不可达/对端立刻关闭）
            const int soErr = socketSoError(fd);
            dispatchConnectError(conn.peerHost(), conn.peerPort(),
                                 soErr != 0 ? soErr : plainErr, "connect failed");
        }
        closeConnection(fd, "plain identity failed");
        return;
    }
    if (n == 0) {
        return;  // 半包：等下次可读事件或 tick 兜底
    }
    handlePlainIdentity(conn, frame);
}

void NetStack::onConnectionReadable(int fd)
{
    // 同 onConnectionWritable：guard 先构造、lock 后构造 ⇒ 析构时锁已释放，可在 guard 内取锁。
    WriteInterestGuard _wig(this, fd);
    HoldTimer _hold("onConnectionReadable");
    DeferredLogFlush _dlf;   // S2: 临界区内 deferLogf 的统一出口（析构时锁已释放）
    std::unique_lock<std::mutex> lk(connMutex_);
    auto it = connections_.find(fd);
    if (it == connections_.end()) return;
    TcpConnection &conn = *it->second;

    if (conn.state() == ConnectionState::Idle || conn.state() == ConnectionState::PlainIdentity) {
        pumpPlainIdentity(conn);
        // pumpPlainIdentity 内部可能 closeConnection()（已从 connections_ 摘除并析构本对象）
        // ⇒ 此时 conn 引用已悬垂，绝不能再读其成员（旧写法读 conn.isClosed() 属 UB）。
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
                if (!conn.isIncoming()) {
                    ev.tcpPort = conn.peerPort();   // 同上：仅出向连接的端口有意义
                    rememberPeerPort(conn.peerHost(), conn.peerPort());
                }
                ev.role = conn.tlsRole();
                dispatchEvent(ev);
                deferLogf("I ", "connected device=%s fd=%d role=%s", conn.deviceId().c_str(),
                     fd, conn.tlsRole() == TlsRole::Server ? "server" : "client");
            }
            if (conn.needsSendIdentity()) {
                sendIdentityOverTls(conn);
            }
        } else if (conn.state() == ConnectionState::Closing) {
            if (conn.isIncoming()) {
                dispatchError(conn.deviceId(), EIO, "tls handshake failed");
            } else {
                dispatchConnectError(conn.peerHost(), conn.peerPort(), EIO, "tls handshake failed");
            }
            closeConnection(fd, "tls handshake failed");
        }
        return;
    }

    if (conn.state() == ConnectionState::Encrypted) {
        drainEncrypted(lk, conn);
    }
}

void NetStack::drainEncrypted(std::unique_lock<std::mutex> &lk, TcpConnection &conn)
{
    // json 段（cJSON 解析 + 逐帧派发）计时：仅用于 PHASESPLIT 打点，静态累计，不改签名
    static thread_local int64_t s_jsonMs = 0;
    s_jsonMs = 0;
    if (conn.state() != ConnectionState::Encrypted) {
        return;
    }
    // —— 协议硬约束：deviceId == 对端证书 CN（AGENTS.md；AtomCode 全量排查 域2 P2-1）——
    // 控制连接此前只依赖「identity 声明 + 已配对设备的证书钉扎」间接保证；未配对首次连接时，
    // 持有自签证书者可声明任意 deviceId。这里在**握手完成且 deviceId 已知**后一次性校验，
    // 不一致即断链（fail-closed）。payload 通道早已有同义校验（verifyPeerLocked）。
    // 注：拨号方的 deviceId 来自握手后收到的 identity ⇒ 故等待 deviceId 非空再判，判过即置位。
    if (!conn.cnVerified() && !conn.deviceId().empty()) {
        const std::string cn =
            conn.tlsEngine() != nullptr ? conn.tlsEngine()->peerCommonName() : std::string();
        if (cn.empty() || cn != conn.deviceId()) {
            deferLogf("E ", "control link cert CN mismatch: cn='%s' deviceId='%s' fd=%d", cn.c_str(),
                 conn.deviceId().c_str(), conn.fd());
            dispatchError(conn.deviceId(), EACCES, "peer cert CN != deviceId");
            closeConnection(conn.fd(), "cert CN mismatch");
            return;
        }
        conn.markCnVerified();
    }
    if (conn.needsSendIdentity()) {
        sendIdentityOverTls(conn);
    }
    const int64_t _tIo = monoMs();
    const ssize_t n = conn.fillTlsRx();
    const int64_t _ioMs = monoMs() - _tIo;
    if (n < 0) {
        const int fd = conn.fd();
        dispatchError(conn.deviceId(), EIO, "tls read failed");
        closeConnection(fd, "tls read failed");
        return;
    }
    if (n == 0) {
        return;
    }
    const int64_t _tJson = monoMs();
    dispatchFrames(lk, conn);
    s_jsonMs = monoMs() - _tJson;
    // 只在这两段合计超阈值时打一行（与 PHASESPLIT 同口径）
    if (_ioMs + s_jsonMs > 100) {
        deferLogf("I ", "[KDC-DRAINSPLIT] tls_decrypt_recv=%{public}lldms json_dispatch=%{public}lldms",
                  (long long) _ioMs, (long long) s_jsonMs);  // S2: 临界区内→延迟打
    }
}

void NetStack::onConnectionWritable(int fd)
{
    // 注意声明顺序：guard 先构造、lock 后构造 ⇒ 析构顺序相反（lock 先释放），
    // 因此 guard 在析构里取锁是安全的（不会自锁）。
    WriteInterestGuard _wig(this, fd);
    HoldTimer _hold("onConnectionWritable");
    std::unique_lock<std::mutex> lk(connMutex_);
    auto it = connections_.find(fd);
    if (it == connections_.end()) return;

    TcpConnection &conn = *it->second;

    if (conn.state() == ConnectionState::Idle && !conn.isIncoming()) {
        // 先看 connect 的真实结果：非阻塞 connect 失败会以 EPOLLOUT/EPOLLERR 唤醒，
        // 若此处当成功继续写 identity，最终只会报出无意义的「plain identity read failed」。
        const int soErr = socketSoError(fd);
        if (soErr != 0) {
            dispatchConnectError(conn.peerHost(), conn.peerPort(), soErr, "connect failed");
            epoll_ctl(epollFd_, EPOLL_CTL_DEL, fd, nullptr);
            conn.close();
            connections_.erase(it);
            return;
        }
        // TCP 已连上（EPOLLOUT 就绪）：发明文 identity，然后立刻起 TLS server 握手
        if (!conn.plainIdentityQueued()) {
            std::vector<std::string> inC, outC;
            {
                std::lock_guard<std::mutex> lk(capsMutex_);
                inC = capsIncoming_;
                outC = capsOutgoing_;
            }
            const std::string identity = PacketIO::buildIdentity(
                config_.deviceId, config_.deviceName, config_.deviceType,
                tcpServer_ ? tcpServer_->port() : 0, PROTOCOL_VERSION, inC, outC);
            conn.queuePlainFrame(identity);
            conn.markPlainIdentityQueued();
        }
        // P0-b：握手必须等明文队列排空后才启动（协议顺序不变量：明文帧不得与 TLS 记录交错）。
        if (!conn.flushPlain()) {
            if (conn.state() == ConnectionState::Closing) {
                const int wrErr = socketSoError(fd);
                dispatchConnectError(conn.peerHost(), conn.peerPort(), wrErr != 0 ? wrErr : EIO,
                                     "send identity failed");
                closeConnection(fd, "plain identity write failed");
            }
            // EAGAIN（对端读得慢）：余量留在队列里，等 EPOLLOUT 或 tick 续传后启动握手。
            // 这里**不再**原地 poll 等待 —— 那会扣住 connMutex_ 数秒并冻结 JS 线程（本轮卡顿根因）。
            return;
        }

        if (!conn.startTlsHandshake(config_.certPem, config_.keyPem)) {
            dispatchConnectError(conn.peerHost(), conn.peerPort(), EIO, "tls init failed");
            closeConnection(fd, "tls init failed");
            return;
        }
        // 握手上限：对端不应答（黑洞/非 KDE Connect/半死）时必须有界失败
        conn.setHandshakeDeadline(nowMs() + handshakeTimeoutMs());
        deferLogf("I ", "TLS server handshake started on fd=%d", fd);  // S2b
        conn.doTlsHandshake();
        return;
    }

    if (conn.state() == ConnectionState::TlsHandshake) {
        if (conn.doTlsHandshake()) {
            if (conn.needsSendIdentity()) {
                sendIdentityOverTls(conn);
            }
            drainEncrypted(lk, conn);
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

} // namespace kdeconnect
