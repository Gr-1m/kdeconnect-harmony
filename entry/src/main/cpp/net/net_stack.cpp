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
#include <ctime>
#include <cstring>

namespace kdeconnect {

namespace {

// 事件循环 tick：定时器检查周期（REVIEW §4 P1-7 最小定时器基建）
constexpr int LOOP_TICK_MS = 200;

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

// 出向连接失败时取真实原因：非阻塞 connect 的失败通过 SO_ERROR 暴露，
// 不看它就只能报出「写 identity 失败」这类对用户无意义的错误（实测：连不上时报
// code=5 "plain identity read failed"，App 无法提示「找不到对应 IP / 连接失败」）。
static int socketSoError(int fd)
{
    int err = 0;
    socklen_t len = sizeof(err);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0) {
        return errno;
    }
    return err;
}

void NetStack::dispatchError(const std::string &deviceId, int code, const std::string &message,
                             const std::string &host, uint16_t port)
{
    NetEvent ev {};
    ev.type = EventType::Error;
    ev.deviceId = deviceId;
    ev.host = host;
    ev.tcpPort = port;
    ev.errorCode = code;
    ev.errorMessage = message;
    dispatchEvent(ev);
    LOGE("error event: device=%s host=%s:%u code=%d msg=%s",
         deviceId.empty() ? "?" : deviceId.c_str(), host.empty() ? "?" : host.c_str(), port, code,
         message.c_str());
}

// 出向连接在握手阶段的失败统一走这里：带上用户输入的目标地址 + 真实 errno，
// 使 App 能明确显示「连接失败/对端无响应」（用户 UX 规格 #1/#2）。
void NetStack::dispatchConnectError(const std::string &host, uint16_t port, int code,
                                    const char *stage)
{
    dispatchError({}, code,
                  std::string(stage) + " (" + host + ":" + std::to_string(port) + "): " +
                      strerror(code),
                  host, port);
}

bool NetStack::start(const NetConfig &config)
{
    if (running_.load()) {
        LOGE("net stack already running");
        return false;
    }

    config_ = config;
    // spool 目录可注入（NetConfig.spoolDir）：为空用设备默认路径。
    // 在 start() 里重建，避免 ArkTS 尚未 start 就下发 payload（此时 payload_ 为默认实例）。
    payload_ = std::make_unique<PayloadManager>(
        this, config_.spoolDir.empty() ? std::string(kPayloadSpoolDirDefault) : config_.spoolDir);

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

    // TCP server 先建：`listen()` 在目标端口被占时会顺序回退（1716→1764，KDE 同款语义），
    // 而 identity 里广播的 tcpPort 必须是**实际绑定**的端口 —— 否则本机 1716 被别的实例/桌面
    // daemon 占用时，我们对外声称 1716、实际在 1717，对端会拨到别人的 daemon 上（实测踩到过）。
    tcpServer_ = std::make_unique<TcpServer>();
    uint16_t tcpPort = config_.tcpPort;
    if (tcpPort == 0) {
        tcpPort = TCP_PORT_MIN;
    }
    if (!tcpServer_->listen(tcpPort)) {
        LOGE("tcp listen failed on port %u", tcpPort);
        stop();
        return false;
    }
    struct epoll_event srvEv {};
    srvEv.events = EPOLLIN;
    srvEv.data.fd = tcpServer_->fd();
    epoll_ctl(epollFd_, EPOLL_CTL_ADD, tcpServer_->fd(), &srvEv);

    udp_ = std::make_unique<UdpDiscovery>();
    if (!udp_->init(config_.deviceId, config_.deviceName, config_.deviceType,
                    tcpServer_->port())) {
        LOGE("udp init failed");
        stop();
        return false;
    }
    // caps 必须进**广播** identity（DevEco MSG116 §3.1：广播里 incoming/outgoing 为空）：
    // init() 建的是不带 caps 的 identity，而 ArkTS 按约定在 start() **之前**调 setCapabilities
    // （那时 udp_ 还是空指针，那次调用被丢弃）⇒ 这里补一次，随后 start() 自己的首次广播即带 caps。
    {
        std::vector<std::string> inC, outC;
        {
            std::lock_guard<std::mutex> lk(capsMutex_);
            inC = capsIncoming_;
            outC = capsOutgoing_;
        }
        udp_->setCapabilities(inC, outC);
        forceBroadcast_.store(false);   // start() 马上会广播一次，无需额外唤醒
    }
    struct epoll_event udpEv {};
    udpEv.events = EPOLLIN;
    udpEv.data.fd = udp_->fd();
    epoll_ctl(epollFd_, EPOLL_CTL_ADD, udp_->fd(), &udpEv);

    udp_->broadcast();
    lastBroadcastMs_ = nowMs();
    broadcastCount_ = 1;

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
    // 端口未知（0）：发现列表里「只被对端拨入过」的设备就是这个状态（KDE 拨入的 identity 不带 tcpPort，
    // 见 net_stack.h PendingDial 注释）。探测会阻塞 ≤PORT_PROBE_TIMEOUT_MS，只能交给事件循环线程，
    // 所以这里入队即返回 true —— 结果照例经 connected / error 事件回到 ArkTS（契约不变）。
    if (port == 0) {
        if (host.empty()) {
            dispatchError({}, EINVAL, "connectToPeer: host required when port unknown");
            return false;
        }
        {
            std::lock_guard<std::mutex> lk(dialMutex_);
            pendingDials_.push_back(PendingDial {host});
        }
        wakeLoop();
        LOGI("dial with unknown port queued: %s (probe %u-%u)", host.c_str(), TCP_PORT_MIN,
             TCP_PORT_MAX);
        return true;
    }

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
    // 注意：这里**不**缓存 host→port —— 端口必须验证过（建链成功或对端 UDP identity 声明）才可信，
    // 否则失败拨号的端口会污染缓存，下次「端口未知」的拨号会直接命中那个死端口（实测踩到）。
    return true;
}

// —— 端口未知拨号：探测 + 缓存（头文件有触发场景说明）——
void NetStack::rememberPeerPort(const std::string &host, uint16_t port)
{
    if (host.empty() || port == 0) {
        return;
    }
    std::lock_guard<std::mutex> lk(dialMutex_);
    portByHost_[host] = port;
}

uint16_t NetStack::cachedPortFor(const std::string &host)
{
    std::lock_guard<std::mutex> lk(dialMutex_);
    auto it = portByHost_.find(host);
    return it == portByHost_.end() ? 0 : it->second;
}

void NetStack::forgetPeerPort(const std::string &host)
{
    std::lock_guard<std::mutex> lk(dialMutex_);
    portByHost_.erase(host);
}

void NetStack::processPendingDials()
{
    std::vector<PendingDial> dials;
    {
        std::lock_guard<std::mutex> lk(dialMutex_);
        if (pendingDials_.empty()) {
            return;
        }
        dials.swap(pendingDials_);
    }

    for (const PendingDial &d : dials) {
        const uint16_t probeMin = config_.portProbeMin != 0 ? config_.portProbeMin : TCP_PORT_MIN;
        const uint16_t probeMax = config_.portProbeMax != 0 ? config_.portProbeMax : TCP_PORT_MAX;
        // 缓存只当线索：先单端口校验一次（约 1ms）。同一 host 上可能先后出现不同设备/端口
        // （对端重启换端口、host 上另跑一个实例），缓存过期必须自愈，否则会**永久**拨死端口。
        uint16_t port = cachedPortFor(d.host);
        if (port != 0 && findListeningTcpPort(d.host, port, port, PORT_PROBE_TIMEOUT_MS) == 0) {
            LOGI("port cache for %s is stale (%u), dropping", d.host.c_str(), port);
            forgetPeerPort(d.host);
            port = 0;
        }
        if (port == 0) {
            port = findListeningTcpPort(d.host, probeMin, probeMax, PORT_PROBE_TIMEOUT_MS);
        }
        if (port == 0) {
            LOGI("port probe: no listener on %s in %u-%u", d.host.c_str(), probeMin, probeMax);
            dispatchConnectError(d.host, 0, EHOSTUNREACH, "port probe");
            continue;
        }
        LOGI("port resolved for %s: %u (%s)", d.host.c_str(), port,
             cachedPortFor(d.host) == port ? "cache" : "probe");
        connectToPeer(d.host, port);
    }
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
        if (conn.deviceId() != deviceId) {
            continue;
        }
        // P0-b（CodeArts MSG160 §3.1 批准）：TLS 握手中的连接也接受 —— 只入队，
        // 由网络线程在 handshakeDone() 后自动 flush（flushTx 以 handshakeDone() 为前置，
        // 因此不会有明文裸发/顺序问题）。修复前这里找不到连接就返回 false，而启动时
        // 首批包（battery/connectivity_report/mpris.request）恰好落在握手窗口内，
        // 「成功」全靠 sendPacket 被 connMutex_ 扣住 6 秒等到了握手完成——纯属巧合。
        const ConnectionState st = conn.state();
        if (st != ConnectionState::Encrypted && st != ConnectionState::TlsHandshake) {
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
        loopIters_.fetch_add(1, std::memory_order_relaxed);
        if (n > 0) {
            epollWake_.fetch_add(1, std::memory_order_relaxed);
            eventsHandled_.fetch_add(static_cast<uint64_t>(n), std::memory_order_relaxed);
        }
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

        // 无端口的拨号请求：探测 + 拨号都在本线程做（≤500ms 阻塞，不能放在 JS 线程）
        processPendingDials();

        // 定时器 tick：identity 超时 + 发现超时（DeviceLost）+ TX 续传
        const int64_t now = nowMs();

        // 网络线程运行统计（MSG149 §3.1：区分「锁等待」与「CPU 饥饿/忙循环」）。
        // 全 cumulative：读相邻两行做差即得该窗口内的网络线程 CPU 与迭代/事件量。
        if (lastStatsMs_ == 0) {
            lastStatsMs_ = now;
        }
        if (now - lastStatsMs_ >= 5000) {
            long long cpuMs = -1;
            struct timespec ts {};
            if (::clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) == 0) {
                cpuMs = static_cast<long long>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
            }
            // 注意 hilog 隐私策略：数值参数必须 %{public}，否则真机上全被掩成 <private>（DevEco MSG151 §4 实测）
            LOGI("[KDC-NETLOOP] cpu=%{public}lldms iters=%{public}llu epollWake=%{public}llu "
                 "events=%{public}llu tick=%{public}dms",
                 cpuMs, (unsigned long long) loopIters_.load(), (unsigned long long) epollWake_.load(),
                 (unsigned long long) eventsHandled_.load(), LOOP_TICK_MS);
            lastStatsMs_ = now;
        }
        if (payload_) {
            payload_->onTick(now);
        }
        // 活跃链路集合：DeviceLost 判定以连接状态为主（P1-2）
        std::vector<std::string> linkedDevices;
        {
            std::lock_guard<std::mutex> lk(connMutex_);
            // 快照（fd → 对象指针）：本循环内调用的回调（pumpPlainIdentity/drainEncrypted →
            // dispatchFrames → closeConnection）会把条目从 connections_ **摘除并析构**，
            // 此后持有 TcpConnection& / 迭代器都会悬垂。已实测：旧写法在循环末段读
            // `c.deviceId()` 时读到已释放 std::string 头 ⇒ std::bad_alloc（desktop latency 探针
            // 稳定复现）。故先快照，每次使用前按 (fd, 指针) 双重确认仍是同一个连接。
            std::vector<std::pair<int, TcpConnection *>> snapshot;
            snapshot.reserve(connections_.size());
            for (auto &kv : connections_) {
                snapshot.emplace_back(kv.first, kv.second.get());
            }
            for (const auto &entry : snapshot) {
                const int cfd = entry.first;
                auto it = connections_.find(cfd);
                if (it == connections_.end() || it->second.get() != entry.second) {
                    continue;  // 已被回调销毁，或 fd 已被复用成新连接
                }
                TcpConnection &c = *it->second;
                if (c.state() == ConnectionState::Closing) {
                    // 硬错误（明文写失败/握手失败）由任一路径置位，本 tick 统一收尾
                    epoll_ctl(epollFd_, EPOLL_CTL_DEL, cfd, nullptr);
                    c.close();
                    it = connections_.erase(it);
                    continue;
                }
                if (c.state() == ConnectionState::TlsHandshake && c.handshakeExpired(now)) {
                    const int tfd = it->first;
                    const std::string thost = c.peerHost();
                    const uint16_t tport = c.peerPort();
                    const bool tincoming = c.isIncoming();
                    LOGI("tls handshake timeout fd=%d host=%s:%u incoming=%d", tfd, thost.c_str(),
                         tport, tincoming ? 1 : 0);
                    epoll_ctl(epollFd_, EPOLL_CTL_DEL, tfd, nullptr);
                    c.close();
                    it = connections_.erase(it);
                    if (!tincoming) {
                        // 用户可见的「连接失败」：对端无响应（黑洞 IP / 非 KDE Connect / 半死）
                        dispatchConnectError(thost, tport, ETIMEDOUT, "connect timeout");
                    }
                    continue;
                }
                if (c.state() == ConnectionState::PlainIdentity && c.plainExpired(now)) {
                    const int fd = it->first;
                    LOGI("identity timeout fd=%d (host=%s)", fd, c.peerHost().c_str());
                    epoll_ctl(epollFd_, EPOLL_CTL_DEL, fd, nullptr);
                    c.close();
                    it = connections_.erase(it);
                } else {
                    // P0-d：identity 阶段读取兜底 —— 与下面的 Encrypted 兜底同理。EPOLLET 下若对端
                    // 在本连接注册 epoll 之前就已写入（且此后单次 write 后沉默），边沿会丢失，
                    // 明文 identity 帧会一直滞留。每 tick 兜底读一次即消除该依赖。
                    if (c.state() == ConnectionState::Idle ||
                        c.state() == ConnectionState::PlainIdentity) {
                        pumpPlainIdentity(c);
                        // 回调可能已 closeConnection 并摘除本连接：必须按 (fd, 指针) 重新确认，
                        // 否则下面继续用 c 就是读已释放对象（实测 std::bad_alloc）。
                        it = connections_.find(cfd);
                        if (it == connections_.end() || it->second.get() != entry.second) {
                            continue;
                        }
                    }
                    // P0-b：明文队列续传（EPOLLOUT 边沿丢失时靠 tick 兜底）；
                    // **排空后**才启动 TLS 握手（协议顺序不变量：明文帧不得与 TLS 记录交错）。
                    if (c.state() == ConnectionState::Idle && c.plainPending()) {
                        const bool drained = c.flushPlain();
                        if (!drained && c.state() == ConnectionState::Closing) {
                            const int pfd = it->first;
                            LOGE("tick plain flush failed fd=%d, closing", pfd);
                            epoll_ctl(epollFd_, EPOLL_CTL_DEL, pfd, nullptr);
                            c.close();
                            it = connections_.erase(it);
                            continue;
                        }
                        if (drained && !c.isIncoming()) {
                            if (!c.startTlsHandshake(config_.certPem, config_.keyPem)) {
                                const int pfd = it->first;
                                LOGE("tick tls init failed fd=%d, closing", pfd);
                                epoll_ctl(epollFd_, EPOLL_CTL_DEL, pfd, nullptr);
                                c.close();
                                it = connections_.erase(it);
                                continue;
                            }
                            c.setHandshakeDeadline(now + handshakeTimeoutMs());
                            LOGI("TLS server handshake started (tick resume) on fd=%d", it->first);
                            c.doTlsHandshake();
                        }
                    }
                    // P0-c：caps 变更后重发 identity —— JS 线程只置标志（setCapabilities），
                    // 实际的 TLS 写出由网络线程完成（CPP_GUIDE §4：JS 线程不做 socket I/O）。
                    if (c.state() == ConnectionState::Encrypted && c.needsSendIdentity()) {
                        sendIdentityOverTls(c);
                    }
                    // 读取兜底：EPOLLET 下任何边沿丢失都会让已到达的帧滞留（对端 caps 协商失败），
                    // 故每 tick 对 Encrypted 连接兜底排空一次（fillTlsRx 无数据时开销为一次 recv）。
                    if (c.state() == ConnectionState::Encrypted) {
                        drainEncrypted(c);
                        // dispatchFrames 可能关闭并摘除本连接 ⇒ 重新确认后再继续使用 c
                        it = connections_.find(cfd);
                        if (it == connections_.end() || it->second.get() != entry.second) {
                            continue;
                        }
                    }
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
                }
            }
        }
        // 周期重播 UDP 发现广播（CodeArts MSG73_TO_OMP 修复 2）：
        // 对端只在启动/网络变化时广播 → 后启动的一方必须由我们补齐节奏。
        // 默认在「有活跃链路」时不播（DISCOVERY_BROADCAST_WHILE_LINKED 注释里有证据：
        // KDE 每收到一次广播就会新建链路并销毁同设备旧链路，会把进行中的传输换掉）。
        const bool forcedBroadcast = forceBroadcast_.exchange(false);
        if (udp_ != nullptr &&
            (forcedBroadcast || linkedDevices.empty() || DISCOVERY_BROADCAST_WHILE_LINKED)) {
            const int interval = (broadcastCount_ < DISCOVERY_BROADCAST_FAST_COUNT)
                                     ? DISCOVERY_BROADCAST_FAST_MS
                                     : DISCOVERY_LONG_INTERVAL_MS;
            if (forcedBroadcast || now - lastBroadcastMs_ >= interval) {
                udp_->broadcast();
                lastBroadcastMs_ = now;
                ++broadcastCount_;
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

    // KDE 只在 UDP 广播里带 tcpPort：这是最可靠的学习机会（后续拨号即使拿到 0 也能复用）
    rememberPeerPort(host, info.tcpPort);

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
                LOGE("rate limit: %s within %dms, rejecting fd=%d", host.c_str(),
                     CONN_RATE_LIMIT_MS, fd);
                ::close(fd);
                continue;
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
                ::close(fd);
                continue;
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

void NetStack::triggerBroadcast()
{
    // UI「扫描 / 下拉刷新」入口（MSG73_TO_OMP 修复 4）。
    // **实现约束（代码评审 L1）**：本函数由 JS 线程调用，而 lastBroadcastMs_/broadcastCount_
    // 是事件循环线程私有状态，直接在这里改构成数据竞争。故只置标志 + 唤醒事件循环，
    // 真正广播由循环线程执行（延迟 ≤ 一个 tick，UI 无感）。
    forceBroadcast_.store(true);
    wakeLoop();
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
                    // 出向连接：peerPort 即拨号目标端口（对端真实监听端口），供 App 显示真实地址；
                    // 入向连接的对端端口是临时端口，报了反而误导，故保持 0。
                    if (!conn.isIncoming()) {
                        cev.tcpPort = conn.peerPort();
                        // 建链成功才缓存：这是「验证过的端口」，供后续端口未知的拨号直接复用
                        rememberPeerPort(conn.peerHost(), conn.peerPort());
                    }
                    cev.role = conn.tlsRole();
                    dispatchEvent(cev);
                    LOGI("connected device=%s fd=%d role=%s", conn.deviceId().c_str(),
                         conn.fd(), conn.tlsRole() == TlsRole::Server ? "server" : "client");
                }
            }
            // 注意（P0，2026-09-13）：identity 帧**必须继续走下面的 PacketReceived 派发**，
            // 不能 `continue` 跳过——ArkTS 的 PacketRouter.handleIdentity/onPeerCapabilities
            // 依赖它做能力协商（caps），跳过会导致 PluginHost 永不装载插件，
            // 现象是「配对成功、连上了，但对端发来的 packet 全部 unhandled」。
            // 这与函数头注释「每个完整帧派发一次 packetReceived」一致。
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

// 明文 identity 阶段的读取（**调用方必须已持有 connMutex_**）。
// 独立成函数是为了让事件循环 tick 也能兜底驱动：EPOLLET 下若对端在我们注册 epoll
// **之前**就已写入、且此后**单次 write 后沉默**（真实形态：拨号方发明文 identity 后就等
// 我们的 TLS ClientHello），边沿会丢失，identity 帧将滞留到对端下一次写入为止。
// 真机上随后到来的 TLS 记录会掩盖这个问题，所以长期未被发现（本用例首次暴露）。
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
    std::lock_guard<std::mutex> lk(connMutex_);
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
                LOGI("connected device=%s fd=%d role=%s", conn.deviceId().c_str(),
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
        drainEncrypted(conn);
    }
}

// 加密态排空读 + 派发：EPOLLET 下必须读到 EAGAIN（REVIEW §4 P1-4）。
// **握手完成的当次也必须调用**：对端常在握手后立刻把 identity 帧塞进同一 burst，
// 若那时直接 return，后续没有新边沿 → 帧永久滞留 → 对端 caps 永远协商不了
// （现象：配对/连接成功，但对端发来的 packet 全部 unhandled）。
void NetStack::drainEncrypted(TcpConnection &conn)
{
    if (conn.state() != ConnectionState::Encrypted) {
        return;
    }
    if (conn.needsSendIdentity()) {
        sendIdentityOverTls(conn);
    }
    const ssize_t n = conn.fillTlsRx();
    if (n < 0) {
        const int fd = conn.fd();
        dispatchError(conn.deviceId(), EIO, "tls read failed");
        closeConnection(fd, "tls read failed");
        return;
    }
    if (n == 0) {
        return;
    }
    dispatchFrames(conn);
}

void NetStack::onConnectionWritable(int fd)
{
    std::lock_guard<std::mutex> lk(connMutex_);
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
        LOGI("TLS server handshake started on fd=%d", fd);
        conn.doTlsHandshake();
        return;
    }

    if (conn.state() == ConnectionState::TlsHandshake) {
        if (conn.doTlsHandshake()) {
            if (conn.needsSendIdentity()) {
                sendIdentityOverTls(conn);
            }
            drainEncrypted(conn);   // 同一 burst 里可能已带着对端 identity（见 drainEncrypted 注释）
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
    // 一次性初始化本机 SPKI（代码评审 L2）：JS 线程可能并发调用，ownSpkiDer_ 的写入需要
    // happens-before 保证 —— 用 call_once（此前是无锁的 done 标志，双线程可并发写）。
    std::call_once(ownSpkiOnce_, [this] {
        const std::string ownDer = pemToDer(config_.certPem, "CERTIFICATE");
        ownSpkiDer_ = ownDer.empty()
                          ? std::string()
                          : extractSpkiDer(reinterpret_cast<const uint8_t *>(ownDer.data()),
                                           ownDer.size());
    });
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
        // caps 变了就**立即**重播一次（MSG117 §3）：对端按广播 identity 预筛选时，等到下一次
        // 周期广播（最长 60s，或已建链时干脆不播）太迟。用既有的 forceBroadcast_ 机制交给
        // 事件循环执行（本函数由 JS 线程调用），与 triggerBroadcast 同一套做法。
        forceBroadcast_.store(true);
        wakeLoop();
    }
    // 向已建加密链路重发 identity（对端据此重算插件装载；d.ts v2 语义）。
    // P0-c：本函数由 **JS 线程** 调用 —— 只置标志 + 唤醒事件循环，真正的 TLS 写出交给
    // 网络线程（此前在这里直接 sendIdentityOverTls ⇒ 在 JS 线程的 socket 上做 I/O，
    // 高延迟链路上会连同 connMutex_ 一起冻结 UI；本改动是契约级修正，签名/语义不变）。
    {
        std::lock_guard<std::mutex> lk(connMutex_);
        bool any = false;
        for (auto &p : connections_) {
            TcpConnection &c = *p.second;
            if (c.state() == ConnectionState::Encrypted && !c.deviceId().empty()) {
                c.requestSendIdentity();
                any = true;
            }
        }
        if (!any) {
            return;  // 无加密链路：没有可重发的目标（等建链后加密前会自动发 identity）
        }
    }
    wakeLoop();
}


} // namespace kdeconnect
