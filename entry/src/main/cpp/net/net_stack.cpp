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

// —— S2（专项关闭条件）：锁内日志延迟打 ——
// connMutex_ 临界区内不得直接调 hilog（I/O 与锁保护对象无关，标准化口径=「锁内零 I/O」）。
// 本文件的网络线程是这些临界区的唯一写者，故用 thread_local 缓冲攒日志，
// 由 DeferredLogFlush 的析构（锁已释放）统一打——沿用 WriteInterestGuard 的
// 「先构造、晚析构」模式（声明顺序见 onConnectionReadable 注释）。
thread_local std::string t_deferredLogs;

void deferLogf(const char *level, const char *fmt, ...)
{
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    if (!t_deferredLogs.empty()) {
        t_deferredLogs += '\n';
    }
    t_deferredLogs += level;
    t_deferredLogs += msg;
}

// 构造点必须在 std::lock_guard 之前 ⇒ 析构时锁已释放，可安全打日志。
struct DeferredLogFlush {
    ~DeferredLogFlush()
    {
        if (!t_deferredLogs.empty()) {
            OH_LOG_Print(LOG_APP, LOG_INFO, 0x0001, LOG_TAG, "%{public}s",
                         t_deferredLogs.c_str());
            t_deferredLogs.clear();
        }
    }
};

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

// 事件派发唯一收口。除转发外做两件事：
//  ① 按类型普查（[KDC-EVENTS] 随 NETLOOP 行输出）——用于判断"JS 线程被事件回调占住"的规模；
//  ② 同一设备 2s 内重复的 DeviceDiscovered 去重：UDP 广播（onUdpReadable）与对端拨入
//     （handlePlainIdentity）都会宣告同一设备，开屏期会成对放大 JS 侧处理量。
namespace {
// ── 持锁分段计时（CodeArts MSG7 P0 / DevEco MSG11 §2.1）──
// 现象：真机 JS 线程等 connMutex_ 1.2~3.2s（maxJsLockWait 与慢 sendPacket 1:1），而套接字均为
// 非阻塞 ⇒ 只可能是「锁内长 CPU 工作」或「持锁时又等另一把锁（锁序）」。本守卫按调用点打标签，
// 超过阈值即打一行，并把窗口内最长的一次连同标签汇入 NETLOOP 行 —— 一次复跑即可指认凶手。
int64_t lockCpuMs()
{
    struct timespec ts {};
    if (::clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) {
        return -1;
    }
    return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

int64_t lockMonoMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

// 锁内子段计时（CodeArts MSG9 P0）：先定位「锁内长计算」到底花在哪一段，再谈移出锁。
// 只在总耗时超阈值时打一行，故对稳态零噪声。
int64_t monoMs();   // 定义见下方（供 PhaseAccum 使用）

struct PhaseAccum {
    const char *what;
    int64_t t0 = monoMs();
    int64_t plain = 0;   // 明文 identity 读/解析
    int64_t tls = 0;     // TLS 握手推进
    int64_t ident = 0;   // 加密通道内 identity 发送
    int64_t drain = 0;   // 排空读（含 TLS 解密）
    int64_t json = 0;    // dispatchFrames（cJSON 解析 + 派发）
    int64_t flush = 0;   // TX 出队写
    int64_t other = 0;
    int conns = 0;
    explicit PhaseAccum(const char *w) : what(w) {}
    int64_t mark()
    {
        return monoMs();
    }
    void done(int64_t &slot, int64_t t)
    {
        slot += monoMs() - t;
    }
    ~PhaseAccum()
    {
        const int64_t total = monoMs() - t0;
        if (total > 100) {
            LOGI("[KDC-PHASESPLIT] what=%{public}s total=%{public}lldms conns=%{public}d "
                 "plain=%{public}lldms tls=%{public}lldms ident=%{public}lldms "
                 "drain=%{public}lldms json=%{public}lldms flush=%{public}lldms",
                 what, (long long) total, conns, (long long) plain, (long long) tls,
                 (long long) ident, (long long) drain, (long long) json, (long long) flush);
        }
    }
};

struct HoldTimer {
    const char *label;
    int64_t t0 = lockMonoMs();
    int64_t cpu0 = lockCpuMs();
    explicit HoldTimer(const char *l) : label(l) {}
    ~HoldTimer()
    {
        const int64_t hold = lockMonoMs() - t0;
        if (hold > LOCK_HOLD_LOG_MS) {
            LOGI("[KDC-LOCKHOLD] label=%{public}s hold=%{public}lldms cpu=%{public}lldms",
                 label, (long long) hold, (long long) (lockCpuMs() - cpu0));
        }
    }
};
}  // namespace

namespace {
// 本线程 CPU 时间（毫秒）。用途：区分「函数内真有活」与「线程未被调度/被阻塞」——
// 这是 DevEco ARKTS_ANALYSIS 与 NATIVE_ANALYSIS §2.4 约定的决定性判据。
int64_t threadCpuMs()
{
    struct timespec ts {};
    if (::clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) {
        return -1;
    }
    return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

// 自包含的单调毫秒（不依赖文件内其它定义，避免插入点可见性问题）
int64_t monoMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

// sendPacket 三段计时（RAII，覆盖所有 return 路径）：
//   wall≫cpu ⇒ 线程在等（调度/阻塞，需继续查谁在占 CPU 或让线程入睡）
//   wall≈cpu ⇒ 函数内确有耗时（按逐段微秒计时继续拆）
struct SendPacketTimer {
    int64_t t0;
    int64_t cpu0;
    int64_t lockWaitMs = 0;
    SendPacketTimer() : t0(monoMs()), cpu0(threadCpuMs()) {}
    ~SendPacketTimer()
    {
        const int64_t wall = monoMs() - t0;
        if (wall > ENTRY_SPLIT_LOG_MS) {
            LOGI("[KDC-ENTRY-SPLIT] sendPacket wall=%{public}lldms cpu=%{public}lldms "
                 "lock=%{public}lldms",
                 (long long) wall, (long long) (threadCpuMs() - cpu0), (long long) lockWaitMs);
        }
    }
};
}  // namespace

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
            rit->second->setEpollWriteArmed(true);
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
    if (lockWaitMs >= 50) {
        deferLogf("I ", "[KDC-LOCKWAIT] sendPacket 等 connMutex_ %lldms（conns=%llu）",  // S2
                  (long long) lockWaitMs, (unsigned long long) connections_.size());
    }
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
        // 诊断（DevEco MSG181 §3.3 要求）：如实记录出向 pair 帧时序，便于与对端帧对齐。
        // 注意：native 侧**不构造**任何 pair 帧（代码中无 pair 语义），这里只记录 App 下发的内容。
        if (packetJson.find("kdeconnect.pair") != std::string::npos) {
            deferLogf("I ", "[KDC-PAIR-OUT] device=%s pkt=%s", deviceId.c_str(),  // S2
                      packetJson.c_str());
        }
        // 入队后按需挂 EPOLLOUT（否则要等 tick 的 200ms 兜底才发出去 —— 配对 ack 会被推迟）
        updateWriteInterestLocked(conn.fd());
        // 唤醒网络线程尽快 flush（EPOLLET 下不能指望一定会再有 EPOLLOUT 边沿）
        wakeLoop();
        return true;
    }
    return false;
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

void NetStack::eventLoop()
{
    struct epoll_event events[64];
    while (running_.load()) {
        int n = epoll_wait(epollFd_, events, 64, LOOP_TICK_MS);
        loopIters_.fetch_add(1, std::memory_order_relaxed);
        if (n > 0) {
            epollWake_.fetch_add(1, std::memory_order_relaxed);
            eventsHandled_.fetch_add(static_cast<uint64_t>(n), std::memory_order_relaxed);
        } else if (n == 0) {
            ++wakeByIdle_;   // 纯超时唤醒（无 fd 就绪）：这是健康空闲态
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
                ++wakeByWakeFd_;
                continue;
            }
            if (udp_ && fd == udp_->fd()) {
                onUdpReadable();
                ++wakeByUdp_;
                continue;
            }
            if (tcpServer_ && fd == tcpServer_->fd()) {
                onTcpServerReadable();
                ++wakeBySrv_;
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
                ++wakeByPayload_;
                continue;
            }

            if (ev & (EPOLLERR | EPOLLHUP)) {
                // 尽量把内核缓冲里的已有数据读完，再无条件关闭（沿旧行为）
                if (ev & EPOLLIN) {
                    onConnectionReadable(fd);
                }
                HoldTimer _hold("eventLoop");
                std::lock_guard<std::mutex> lk(connMutex_);
                closeConnection(fd, "epoll err/hup");
                ++wakeByConn_;
                ++connHup_;
                continue;
            }
            if (ev & EPOLLIN) {
                onConnectionReadable(fd);
                ++connIn_;
            }
            if (ev & EPOLLOUT) {
                onConnectionWritable(fd);
                ++connOut_;
            }
            ++wakeByConn_;
        }

        // 无端口的拨号请求：探测 + 拨号都在本线程做（≤500ms 阻塞，不能放在 JS 线程）
        processPendingDials();

        // 定时器 tick：identity 超时 + 发现超时（DeviceLost）+ TX 续传
        const int64_t now = nowMs();

        // 重活时间门（DevEco MSG178 真机根因）：循环会被高频 fd 唤醒（真机实测 ~1000 次/秒），
        // 而「每连接 tick + payload onTick」原先**每轮**都执行 —— 实测 0.78ms CPU/轮 ⇒ 空烧约一个核，
        // 且每轮取一次 connMutex_（std::mutex 非公平）⇒ JS 线程 sendPacket 被饿死 1.3~16s（真机 ANR）。
        // 事件类工作（拨号、广播）仍每轮处理；只有重活按 LOOP_TICK_MS 节流。
        const bool dueTick = (now - lastTickMs_ >= LOOP_TICK_MS);
        if (dueTick) {
            lastTickMs_ = now;
        }

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
            const int64_t dtMs = now - lastStatsMs_;
            // 注意 hilog 隐私策略：数值参数必须 %{public}，否则真机上全被掩成 <private>（DevEco MSG151 §4 实测）
            // dt= 本窗口实际墙钟毫秒 ⇒ 读者可直接算 iters/s、cpu 占比，不再依赖"窗口是 5s"的假设。
            LOGI("[KDC-NETLOOP] cpu=%{public}lldms iters=%{public}llu epollWake=%{public}llu "
                 "events=%{public}llu tick=%{public}dms dt=%{public}lldms "
                 "wake[wakefd=%{public}llu udp=%{public}llu srv=%{public}llu conn=%{public}llu "
                 "payload=%{public}llu idle=%{public}llu] "
                 "maxHold=%{public}lldms maxJsLockWait=%{public}lldms "
                 "txQueued=%{public}llu plainQueued=%{public}llu "
                 "ev[disc=%{public}llu lost=%{public}llu conn=%{public}llu disc2=%{public}llu "
                 "pkt=%{public}llu pair=%{public}llu err=%{public}llu xfer=%{public}llu] "
                 "conn[in=%{public}llu out=%{public}llu hup=%{public}llu]",
                 cpuMs, (unsigned long long) loopIters_.load(), (unsigned long long) epollWake_.load(),
                 (unsigned long long) eventsHandled_.load(), LOOP_TICK_MS, (long long) dtMs,
                 (unsigned long long) wakeByWakeFd_, (unsigned long long) wakeByUdp_,
                 (unsigned long long) wakeBySrv_, (unsigned long long) wakeByConn_,
                 (unsigned long long) wakeByPayload_, (unsigned long long) wakeByIdle_,
                 (long long) maxTickHoldMs_, (long long) maxJsLockWaitMs_.load(),
                 (unsigned long long) statTxQueuedBytes_, (unsigned long long) statPlainQueuedBytes_,
                 (unsigned long long) evCounts_[0].load(), (unsigned long long) evCounts_[1].load(),
                 (unsigned long long) evCounts_[2].load(), (unsigned long long) evCounts_[3].load(),
                 (unsigned long long) evCounts_[4].load(), (unsigned long long) evCounts_[5].load(),
                 (unsigned long long) evCounts_[6].load(), (unsigned long long) evCounts_[7].load(),
                 (unsigned long long) connIn_, (unsigned long long) connOut_,
                 (unsigned long long) connHup_);
            maxTickHoldMs_ = 0;
            maxJsLockWaitMs_.store(0);
            lastStatsMs_ = now;
        }
        if (dueTick && payload_) {
            payload_->onTick(now);
        }
        // 活跃链路集合：DeviceLost 判定以连接状态为主（P1-2）
        std::vector<std::string> linkedDevices;
        // ↓ 本块是「每连接重活」（握手推进 / 兜底读 / TX 续传），按 LOOP_TICK_MS 节流（见 dueTick 注释）。
        //   内部内容未重排缩进，以保持 diff 最小、便于复核。
        if (dueTick) {
        const int64_t holdT0 = nowMs();
        PhaseAccum _phases("eventLoop:tick");
        {
            HoldTimer _hold("eventLoop");
            DeferredLogFlush _dlf;   // S2: tick 临界区内 deferLogf 的统一出口（析构时锁已释放）
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
                    deferLogf("I ", "tls handshake timeout fd=%d host=%s:%u incoming=%d", tfd, thost.c_str(),
                              tport, tincoming ? 1 : 0);  // S2
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
                    deferLogf("I ", "identity timeout fd=%d (host=%s)", fd, c.peerHost().c_str());  // S2
                    epoll_ctl(epollFd_, EPOLL_CTL_DEL, fd, nullptr);
                    c.close();
                    it = connections_.erase(it);
                } else {
                    // P0-d：identity 阶段读取兜底 —— 与下面的 Encrypted 兜底同理。EPOLLET 下若对端
                    // 在本连接注册 epoll 之前就已写入（且此后单次 write 后沉默），边沿会丢失，
                    // 明文 identity 帧会一直滞留。每 tick 兜底读一次即消除该依赖。
                    if (c.state() == ConnectionState::Idle ||
                        c.state() == ConnectionState::PlainIdentity) {
                        const int64_t _tp = _phases.mark();
                        pumpPlainIdentity(c);
                        _phases.done(_phases.plain, _tp);
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
                            deferLogf("E ", "tick plain flush failed fd=%d, closing", pfd);  // S2
                            epoll_ctl(epollFd_, EPOLL_CTL_DEL, pfd, nullptr);
                            c.close();
                            it = connections_.erase(it);
                            continue;
                        }
                        if (drained && !c.isIncoming()) {
                            if (!c.startTlsHandshake(config_.certPem, config_.keyPem)) {
                                const int pfd = it->first;
                                deferLogf("E ", "tick tls init failed fd=%d, closing", pfd);  // S2
                                epoll_ctl(epollFd_, EPOLL_CTL_DEL, pfd, nullptr);
                                c.close();
                                it = connections_.erase(it);
                                continue;
                            }
                            c.setHandshakeDeadline(now + handshakeTimeoutMs());
                            deferLogf("I ", "TLS server handshake started (tick resume) on fd=%d",  // S2
                                      it->first);
                            c.doTlsHandshake();
                        }
                    }
                    // P0-c：caps 变更后重发 identity —— JS 线程只置标志（setCapabilities），
                    // 实际的 TLS 写出由网络线程完成（CPP_GUIDE §4：JS 线程不做 socket I/O）。
                    if (c.state() == ConnectionState::Encrypted && c.needsSendIdentity()) {
                        const int64_t _ti = _phases.mark();
                        sendIdentityOverTls(c);
                        _phases.done(_phases.ident, _ti);
                    }
                    // 读取兜底：EPOLLET 下任何边沿丢失都会让已到达的帧滞留（对端 caps 协商失败），
                    // 故每 tick 对 Encrypted 连接兜底排空一次（fillTlsRx 无数据时开销为一次 recv）。
                    if (c.state() == ConnectionState::Encrypted) {
                        const int64_t _td = _phases.mark();
                        drainEncrypted(c);
                        _phases.done(_phases.drain, _td);
                        // dispatchFrames 可能关闭并摘除本连接 ⇒ 重新确认后再继续使用 c
                        it = connections_.find(cfd);
                        if (it == connections_.end() || it->second.get() != entry.second) {
                            continue;
                        }
                    }
                    // TX 续传：对端恢复读取且无新 EPOLLOUT 边沿时，靠 tick 兜底写出
                    if (c.state() == ConnectionState::Encrypted && c.txPending() && !c.flushTx()) {
                        const int fd = it->first;
                        deferLogf("E ", "tick flush failed fd=%d, closing", fd);  // S2
                        epoll_ctl(epollFd_, EPOLL_CTL_DEL, fd, nullptr);
                        c.close();
                        it = connections_.erase(it);
                        continue;
                    }
                    // 写兴趣随队列状态更新（P0-b2-c；此刻已持 connMutex_，用 Locked 版本）
                    updateWriteInterestLocked(cfd);
                    if (!c.deviceId().empty() && !c.isClosed()) {
                        linkedDevices.push_back(c.deviceId());
                    }
                }
            }
            // 队列长度采样（DevEco MSG178 §3 要求）：随 NETLOOP 行输出，用于判断
            // 「是否堆积 / 是否卡在明文队列 / 握手是否迟迟不推进」。
            statTxQueuedBytes_ = 0;
            statPlainQueuedBytes_ = 0;
            for (const auto &kv : connections_) {
                statTxQueuedBytes_ += kv.second->txQueuedBytes();
                statPlainQueuedBytes_ += kv.second->plainQueuedBytes();
            }
        }
        const int64_t holdMs = nowMs() - holdT0;
        if (holdMs > maxTickHoldMs_) {
            maxTickHoldMs_ = holdMs;   // 窗口内单次持 connMutex_ 的最长耗时（随 NETLOOP 行输出）
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
                deferLogf("I ", "device lost (no broadcast and no link for %d ms): %s",  // S2
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
            HoldTimer _hold("onTcpServerReadable");
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

// P0-b2-c：EPOLLET 下若连接 fd 挂着 EPOLLOUT 却**没有任何可写内容**，该 fd 会被 epoll_wait
// 每轮重复上报（无法靠"写到 EAGAIN"消费）⇒ 空转烧核：真机实测连接事件 ~1 万次/秒、约一个核，
// 并让配对 ack 等发送被推迟到对端超时（DevEco MSG180）。故改为**按需**挂/摘：
// 只有明文队列 / 加密队列有字节、或 TLS 引擎有待发记录时才挂 EPOLLOUT。
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
        LOGE("updateWriteInterest fd=%d: epoll_ctl MOD failed: %s", fd, strerror(errno));
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
    LOGI("connection closed: %s (fd=%d, device=%s)", reason, fd,
         deviceId.empty() ? "?" : deviceId.c_str());
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
            LOGI("link replaced: %s still has a live link, suppressing Disconnected", deviceId.c_str());
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
        deferLogf("I ", "TLS client handshake started on fd=%d", conn.fd());  // S2: 临界区内→延迟打
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
    // 帧普查（CodeArts MSG9 P0 收尾用）：一次 drain 里有多少帧、多少字节、最大帧多大。
    // 目的：区分「大量小帧（每帧固定开销）」与「少量超大帧（解析成本）」——两者修法不同。
    // 第 N 次进入 dispatchFrames（进程内累计）：用于区分"首次/惰性初始化"与"稳态每帧开销"
    // ——真机两台机型都出现"整轮唯一一次 ~330ms、frames=1 bytes=2294"，形态更像前者（DevEco MSG16 §2）。
    static std::atomic<uint64_t> s_dispatchSeq{1};
    const uint64_t _dispatchSeq = s_dispatchSeq.fetch_add(1, std::memory_order_relaxed);
    int64_t _censusFrames = 0;
    int64_t _censusBytes = 0;
    size_t _censusMaxFrame = 0;
    const int64_t _censusT0 = monoMs();
    while (PacketIO::extractFrame(conn.rxBuf(), frame)) {
        if (frame.empty()) {
            continue;  // 超限帧已丢弃
        }
        // 去掉帧尾 '\n' 供 cJSON 解析/事件载荷（JSON 本身不含它）
        std::string json = frame;
        if (!json.empty() && json.back() == '\n') json.pop_back();
        if (json.empty()) continue;
        ++_censusFrames;
        _censusBytes += static_cast<int64_t>(json.size());
        if (json.size() > _censusMaxFrame) _censusMaxFrame = json.size();

        std::string type;
        std::string body;
        int64_t payloadSize = 0;
        uint16_t payloadPort = 0;
        if (!PacketIO::parsePacket(json, type, body, &payloadSize, &payloadPort)) {
            deferLogf("E ", "invalid JSON frame dropped (fd=%d, %zu bytes)", conn.fd(), json.size());  // S2
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
                        // 同 deviceId 的**新**链路到达 ⇒ 按 KDE 语义「保留新链路、关掉旧链路」。
                        // KDE 的 lanlinkprovider 在每次收到广播后都会新建链路并销毁同设备旧链路
                        // （见 AGENTS.md 记载），因此**对端必然会在 ~0.6~0.7s 后重拨一次**。
                        // 旧实现是「1000ms 内同设备重连 ⇒ 丢弃该连接」，于是新链路被我们自己掐断，
                        // 而对端又已销毁它那条旧链路 ⇒ **两边同时死链**（真机现象：connected →
                        // disconnected 间隔 0.6~0.7s、配对主链路走不通，见 DevEco MSG181）。
                        lastConnByDevice_[info.deviceId] = nowMs();
                        // 关掉同 deviceId 的其他连接（新链路即 conn，不动它）。
                        // 注意：这里的关闭是"替换"，closeConnection 会在仍有同设备存活连接时
                        // 抑制 Disconnected 事件，避免 UI 误判离线。
                        {
                            std::vector<int> stale;
                            for (const auto &p2 : connections_) {
                                if (p2.first != conn.fd() && p2.second->deviceId() == info.deviceId) {
                                    stale.push_back(p2.first);
                                }
                            }
                            for (int sfd : stale) {
                                deferLogf("I ", "replacing stale link for device %s: closing fd=%d",
                                          info.deviceId.c_str(), sfd);  // S2
                                closeConnection(sfd, "replaced by newer link");
                            }
                        }
                    }
                    if (!trustedPem.empty() && conn.tlsEngine() != nullptr) {
                        std::vector<uint8_t> leaf = conn.tlsEngine()->peerLeafCertDer();
                        const std::string trustedDer = pemToDer(trustedPem, "CERTIFICATE");
                        const std::string leafStr(leaf.begin(), leaf.end());
                        if (leafStr.empty() || leafStr != trustedDer) {
                            deferLogf("E ", "certificate mismatch for %s, dropping", info.deviceId.c_str());  // S2
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
                deferLogf("I ", "peer identity over TLS: %s (%s)", info.deviceId.c_str(), info.deviceName.c_str());  // S2
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
                    deferLogf("I ", "connected device=%s fd=%d role=%s",  // S2
                              conn.deviceId().c_str(), conn.fd(),
                              conn.tlsRole() == TlsRole::Server ? "server" : "client");
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
                deferLogf("E ", "[KDC-PAYLOAD] push rejected: device %s not trusted "
                                "(port=%u size=%lld)",  // S2: 临界区内延迟打; 标签化便于按 KDC-PAYLOAD 抓取
                          conn.deviceId().c_str(), payloadPort, (long long) payloadSize);
                dispatchError(conn.deviceId(), EACCES,
                              "payload rejected: device not paired/trusted");
            }
        }

        // 载荷已宣告但未启动（xferId==0 而 payloadSize!=0）：ArkTS 若据 payloadSize 建「接收中」
        // 条目将**永久悬挂**（FSM 每 5s/任务必打 ⇒ 无 KDC-PAYLOAD 行即从未入表，见 DevEco MSG22）。
        // 这里给出可诊断日志 + 显式错误事件收口，避免「无任务、无终态」的静默失败。
        if (payloadSize != 0 && xferId == 0) {
            const char *why = payloadPort == 0       ? "port missing/0"
                              : conn.deviceId().empty() ? "deviceId unknown"
                                                        : "not trusted";
            std::string head = frame.substr(0, 160);
            for (char &ch : head) {
                if (ch == '\n' || ch == '\r') ch = ' ';
            }
            deferLogf("W ", "[KDC-PAYLOAD] announced but NOT started: fd=%d type=%s size=%lld "
                            "port=%u why=%s head=%s",
                      conn.fd(), type.c_str(), (long long) payloadSize, payloadPort, why,
                      head.c_str());
            dispatchError(conn.deviceId(), EIO, std::string("payload not started (") + why + ")");
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
    const int64_t _censusMs = monoMs() - _censusT0;
    if (_censusMs > 100) {
        LOGI("[KDC-FRAMESPLIT] n=%{public}llu frames=%{public}lld bytes=%{public}lld "
             "maxFrame=%{public}llu total=%{public}lldms",
             (unsigned long long) _dispatchSeq, (long long) _censusFrames,
             (long long) _censusBytes, (unsigned long long) _censusMaxFrame,
             (long long) _censusMs);
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
    // 同 onConnectionWritable：guard 先构造、lock 后构造 ⇒ 析构时锁已释放，可在 guard 内取锁。
    WriteInterestGuard _wig(this, fd);
    HoldTimer _hold("onConnectionReadable");
    DeferredLogFlush _dlf;   // S2: 临界区内 deferLogf 的统一出口（析构时锁已释放）
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
            LOGE("control link cert CN mismatch: cn='%s' deviceId='%s' fd=%d", cn.c_str(),
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
    dispatchFrames(conn);
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


} // namespace kdeconnect
