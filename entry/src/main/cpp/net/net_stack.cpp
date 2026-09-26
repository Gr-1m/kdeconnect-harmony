// SPDX-License-Identifier: GPL-2.0-or-later
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

// 内部共享件（延迟日志 / 计时守卫 / 地址助手）——见 net_internal.h（S5 交付）
#include "net_internal.h"

namespace kdeconnect {


void NetStack::dispatchEvent(const NetEvent &event)
{
    const size_t ti = static_cast<size_t>(event.type);
    if (ti < evCounts_.size()) {
        evCounts_[ti].fetch_add(1, std::memory_order_relaxed);
    }
    if (event.type == EventType::DeviceDiscovered && !event.deviceId.empty()) {
        const int64_t now = nowMs();
        auto it = lastDiscoveredMs_.find(event.deviceId);
        if (it != lastDiscoveredMs_.end() && now - it->second < DISCOVERY_DEDUP_EVENT_MS) {
            return;   // 冗余发现：已在上一次派发中告知 ArkTS
        }
        lastDiscoveredMs_[event.deviceId] = now;
    }
    std::lock_guard<std::mutex> lk(callbackMutex_);
    if (eventCallback_) {
        eventCallback_(event);
    }
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
    // S2 收尾：本函数会在持 connMutex_ 的路径被调用（如 sendPacket/closeConnection 内部），
    // 故统一走延迟打；S2b 的 t_flushArmed 保证无冲刷出口的线程（JS 线程）仍立即输出。
    deferLogf("E ", "error event: device=%s host=%s:%u code=%d msg=%s",
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
    const uint16_t udpPort = config_.udpPort != 0 ? config_.udpPort : UDP_PORT;
    if (!udp_->init(config_.deviceId, config_.deviceName, config_.deviceType,
                    tcpServer_->port(), udpPort)) {
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
        HoldTimer _hold("stop");
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
        HoldTimer _hold("connectToPeer");
        std::lock_guard<std::mutex> lk(connMutex_);
        connections_[fd] = std::move(conn);
    }

    struct epoll_event ev {};
    // 拨号方立刻就要发明文 identity：初始即挂 EPOLLOUT，并在连接对象上登记「已挂」
    // （后续 updateWriteInterest 只在状态变化时才 MOD）。EPOLLET 下 ADD 会对当前可写立即
    // 上报一次，正好用来触发首帧写入。
    ev.events = EPOLLIN | EPOLLOUT | EPOLLET;
    ev.data.fd = fd;
    epoll_ctl(epollFd_, EPOLL_CTL_ADD, fd, &ev);
    {
        HoldTimer _hold("connectToPeer");
        std::lock_guard<std::mutex> lk(connMutex_);
        auto rit = connections_.find(fd);
        if (rit != connections_.end()) {
            rit->second->writeInterest().armed = true;   // S3：注册时已带 EPOLLOUT
        }
    }

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
    // 等锁计时（DevEco MSG178 §3 要求第一项）：真机实测本入口在 JS 线程被阻塞 1.3~16s，
    // 必须区分「等 connMutex_」与「入口内部工作」。>50ms 打一行，峰值随 NETLOOP 行输出。
    SendPacketTimer _entryTimer;   // §2.4：wall/cpu/lock 三段（>50ms 才打）
    DeferredLogFlush _dlf;         // S2：本函数持 connMutex_，临界区内日志经此在解锁后打出
    const int64_t lockT0 = nowMs();
    HoldTimer _hold("sendPacket");
    std::lock_guard<std::mutex> lk(connMutex_);
    const int64_t lockWaitMs = nowMs() - lockT0;
    _entryTimer.lockWaitMs = lockWaitMs;
    if (lockWaitMs > maxJsLockWaitMs_.load()) {
        maxJsLockWaitMs_.store(lockWaitMs);
    }
#if KDC_TELEMETRY   // S4：排查级埋点（release 关；maxJsLockWaitMs_ 累计不受影响）
    if (lockWaitMs >= 50) {
        deferLogf("I ", "[KDC-LOCKWAIT] sendPacket 等 connMutex_ %lldms（conns=%llu）",  // S2
                  (long long) lockWaitMs, (unsigned long long) connections_.size());
    }
#endif
    // 择链（Omp 2026-09-26）：优先选**已建立**（Encrypted）的链路，避免把包排到仍在握手的链路上。
    // 说明与更正：本改动**并非**基于「多链路长期并存」——`conn[in/out/hup]` 是**累计计数器**
    // （`net_stack.h` 的 connIn_/connOut_/connHup_），不是在线链路数（我曾误读，已在
    // `devdocs/KNOWN_ISSUES.md` 的 KI-2 更正）；同设备旧链路由 `net_stack_link.cpp` 的
    // 「替换同设备旧链路」逻辑主动关闭，长期只保留一条。此处两轮择链仍保留：它让**替换窗口内**
    // （新链路握手完成、旧链路尚未被关）的择链确定化，属稳健性改进。
    // 行为边界不变：仅在没有任何已建立链路时才退回 TlsHandshake（完整保留 P0-b）。
    TcpConnection *target = nullptr;
    for (auto &p : connections_) {
        TcpConnection &conn = *p.second;
        if (conn.deviceId() == deviceId && conn.state() == ConnectionState::Encrypted) {
            target = &conn;
            break;
        }
    }
    if (target == nullptr) {
        // P0-b（CodeArts MSG160 §3.1 批准）：TLS 握手中的连接也接受 —— 只入队，
        // 由网络线程在 handshakeDone() 后自动 flush（flushTx 以 handshakeDone() 为前置，
        // 因此不会有明文裸发/顺序问题）。修复前这里找不到连接就返回 false，而启动时
        // 首批包（battery/connectivity_report/mpris.request）恰好落在握手窗口内，
        // 「成功」全靠 sendPacket 被 connMutex_ 扣住 6 秒等到了握手完成——纯属巧合。
        for (auto &p : connections_) {
            TcpConnection &conn = *p.second;
            if (conn.deviceId() == deviceId && conn.state() == ConnectionState::TlsHandshake) {
                target = &conn;
                break;
            }
        }
    }
    if (target == nullptr) {
        return false;
    }
    // 只入队，不做 I/O：本方法可从 ArkTS 主线程调用（CPP_GUIDE §4 硬约束）。
    // 真正的写由网络线程 flushTx 承担（EPOLLOUT/tick 驱动），
    // 因此不会阻塞 JS 线程，也不会出现多写者帧交错（REVIEW §4 P1-6/P1-3）。
    if (!target->enqueueTx(packetJson)) {
        dispatchError(deviceId, ENOBUFS, "sendPacket: tx queue full");
        return false;
    }
    // 诊断（DevEco MSG181 §3.3 要求）：如实记录出向 pair 帧时序，便于与对端帧对齐。
    // 注意：native 侧**不构造**任何 pair 帧（代码中无 pair 语义），这里只记录 App 下发的内容。
    if (packetJson.find("kdeconnect.pair") != std::string::npos) {
        deferLogf("I ", "[KDC-PAIR-OUT] device=%s pkt=%s", deviceId.c_str(),  // S2
                  packetJson.c_str());
    }
    // 入队后按需挂 EPOLLOUT（否则要等 tick 的 200ms 兜底才发出去 —— 配对 ack 会被推迟）。
    //
    // 语义说明（AtomCode REVIEW_OMP_CHANGES_20260926 §2 建议，随 P2 后半梳理）：
    // 若 target 处于 `TlsHandshake`，此处挂上的 EPOLLOUT 对 flushTx **不生效**（flushTx 以
    // `handshakeDone()` 为前置）；该包由**握手完成当次必 drain** 的路径送出（见 EPOLLET 三坑之"握手完成当次必 drain"），
    // 因此不会滞留。**此调用保留不动**，理由有二：
    //   · 拨号方**依赖**注册时挂 EPOLLOUT 借 ADD 的可写上报启动首帧握手（去掉会破坏握手启动）；
    //   · 历史上 payload fd 的 EPOLLOUT "按需挂载"改过三次都让载荷握手停摆、接收侧 `done=0` 卡死
    //     （见 `devdocs/EXP_LESSONS_20260916_splash_freeze.md`）⇒ 此处不做"看似更精确"的时机收紧。
    // 真正可做的是 P2 后半（同设备冗余链路收敛）时，把"握手期链路的写兴趣"作为整体语义一并理清。
    updateWriteInterestLocked(target->fd());
    // 唤醒网络线程尽快 flush（EPOLLET 下不能指望一定会再有 EPOLLOUT 边沿）
    wakeLoop();
    return true;
}

void NetStack::disconnectDevice(const std::string &deviceId)
{
    HoldTimer _hold("disconnectDevice");
    DeferredLogFlush _dlf;   // S2：临界区内日志在解锁后统一打
    std::lock_guard<std::mutex> lk(connMutex_);
    bool any = false;
    for (auto it = connections_.begin(); it != connections_.end(); ) {
        if (it->second->deviceId() == deviceId) {
            int fd = it->first;
            epoll_ctl(epollFd_, EPOLL_CTL_DEL, fd, nullptr);
            it->second->close();
            it = connections_.erase(it);
            any = true;
            deferLogf("I ", "disconnected device %s (fd=%d)", deviceId.c_str(), fd);  // S2
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

// eventLoop() 已迁至 net_stack_discovery.cpp（S5-b）

// onUdpReadable() 已迁至 net_stack_discovery.cpp（S5-b）

// onTcpServerReadable() 已迁至 net_stack_link.cpp（S5-b）

// P0-b2-c：EPOLLET 下若连接 fd 挂着 EPOLLOUT 却**没有任何可写内容**，该 fd 会被 epoll_wait
// 每轮重复上报（无法靠"写到 EAGAIN"消费）⇒ 空转烧核：真机实测连接事件 ~1 万次/秒、约一个核，
// 并让配对 ack 等发送被推迟到对端超时（DevEco MSG180）。故改为**按需**挂/摘：
// 只有明文队列 / 加密队列有字节、或 TLS 引擎有待发记录时才挂 EPOLLOUT。
// updateWriteInterestLocked() 已迁至 net_stack_link.cpp（S5-b）

// updateWriteInterest() 已迁至 net_stack_link.cpp（S5-b）

// closeConnection() 已迁至 net_stack_link.cpp（S5-b）

// sendIdentityOverTls() 已迁至 net_stack_link.cpp（S5-b）

// triggerBroadcast() 已迁至 net_stack_discovery.cpp（S5-b）

// 明文 identity 帧：设置 deviceId/设备信息，派发 pairingRequest，入向连接就地启动 TLS 握手
// handlePlainIdentity() 已迁至 net_stack_link.cpp（S5-b）

// 排空读后按 '\n' 切分：每个完整帧派发一次 packetReceived（帧尾 '\n' 保留，
// ArkTS 侧 PacketRouter 仍按 '\n' 切分即可正确工作）
// 两阶段管线（S1，AtomCode REVIEW_HOLISTIC_BUGFIX S1）：
//   阶段 1（持锁）：**只做帧提取入队** + 快照（连接身份/地址/叶证书）。
//   阶段 2（放锁）：解析（Rust serde）、身份/信任决策、事件派发全部在锁外；
//                  需要变更连接或设备状态时，以 fd 短临界区回写（连接可能已被回收 ⇒ 重定位）。
// 目的：任何解析回归都不得再让 UI 冻结——f872b99 把 CPU 压到毫秒级但结构未变，
// 下一次解析变慢仍会变成全 UI 卡顿。行为与旧实现逐帧等价（顺序不变）。
// dispatchFrames() 已迁至 net_stack_link.cpp（S5-b）

// 明文 identity 阶段的读取（**调用方必须已持有 connMutex_**）。
// 独立成函数是为了让事件循环 tick 也能兜底驱动：EPOLLET 下若对端在我们注册 epoll
// **之前**就已写入、且此后**单次 write 后沉默**（真实形态：拨号方发明文 identity 后就等
// 我们的 TLS ClientHello），边沿会丢失，identity 帧将滞留到对端下一次写入为止。
// 真机上随后到来的 TLS 记录会掩盖这个问题，所以长期未被发现（本用例首次暴露）。
// pumpPlainIdentity() 已迁至 net_stack_link.cpp（S5-b）

// onConnectionReadable() 已迁至 net_stack_link.cpp（S5-b）

// 加密态排空读 + 派发：EPOLLET 下必须读到 EAGAIN（REVIEW §4 P1-4）。
// **握手完成的当次也必须调用**：对端常在握手后立刻把 identity 帧塞进同一 burst，
// 若那时直接 return，后续没有新边沿 → 帧永久滞留 → 对端 caps 永远协商不了
// （现象：配对/连接成功，但对端发来的 packet 全部 unhandled）。
// drainEncrypted() 已迁至 net_stack_link.cpp（S5-b）

// onConnectionWritable() 已迁至 net_stack_link.cpp（S5-b）

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
        HoldTimer _hold("peerCertPem");
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
    HoldTimer _hold("peerCertPem");
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

bool NetStack::epollMod(int fd, uint32_t events)
{
    // 兴趣位变更（EPOLLET 恒定附加）：仅供「按需挂/摘 EPOLLOUT」（连接侧与 payload 侧共用）。
    // 调用方必须保证**仅在状态变化时**调用 —— EPOLL_CTL_MOD 会重新武装 ET 并立即上报，
    // 每轮调用会变成新的空转源。
    epoll_event ev {};
    ev.events = events | EPOLLET;
    ev.data.fd = fd;
    return epoll_ctl(epollFd_, EPOLL_CTL_MOD, fd, &ev) == 0;
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
    HoldTimer _hold("getPeerCertificate");
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
        HoldTimer _hold("getPairVerificationCode");
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
        HoldTimer _hold("setCapabilities");
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


// —— 由 net_internal.h 迁回：头文件不得定义成员函数（多 TU 定义冲突，S5-a）——
void NetStack::setEventCallback(EventCallback cb)
{
    std::lock_guard<std::mutex> lk(callbackMutex_);
    eventCallback_ = std::move(cb);
}

NetStack::NetStack()
{
    payload_ = std::make_unique<PayloadManager>(this, std::string(kPayloadSpoolDirDefault));
}

NetStack::~NetStack()
{
    stop();
}

} // namespace kdeconnect
