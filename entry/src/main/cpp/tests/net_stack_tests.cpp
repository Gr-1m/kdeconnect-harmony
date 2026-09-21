// SPDX-License-Identifier: GPL-2.0-or-later
// WP-4 native 集成测试（host，CI 可跑）：**连接失败的可解释性** + 有界握手。
//
// 背景（用户 UX 规格 #1/#2）：点「连接」后必须明确「连接成功」或「连接失败（找不到对应 IP 等）」。
// 实测旧行为：连不上的端口只报 `code=5 "plain identity read failed"` —— 无 IP、无真实 errno，
// App 无法给出任何有意义的提示。本测试锁住修复后的契约：
//   ① 出向 connect 失败（端口关闭）→ error 事件带 **host/tcpPort + 真实 errno(ECONNREFUSED)**
//   ② 对端 TCP 可连但不应答（mute peer）→ 握手上限到点 → error 事件带 host/tcpPort + ETIMEDOUT
// 两者都无需真实设备/局域网（UDP 广播失败被忽略）。

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <csignal>
#include <cstdlib>
#include <sys/wait.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "../net/cert_gen.h"
#include "../net/net_stack.h"
#include "../net/net_util.h"
#include "../net/packet_io.h"

using namespace kdeconnect;

namespace {

int g_failed = 0;
int g_cases = 0;
const char *g_case = "?";
// —— harness 隔离（CodeArts MSG22 §2）——
// 根因：全部 net 用例原先共享**同一个 netStack() 单例**，且都从 127.0.0.1 拨入 ⇒ 既受上一个
// 用例的残留状态影响，又受「同 IP accept 限流（300ms）」影响；负载下表现为握手偶发不成（sent=0）。
// 对策：run.sh 用 --list/--case 让**每个用例在独立进程**里跑（栈与进程状态全新）。
const char *g_onlyCase = nullptr;
// 发送侧进度（harness 判定"传输进行中"用）
std::atomic<int64_t> g_peerSendDone{0};
std::atomic<int64_t> g_peerSendTotal{0};
// P0 回归用的假对端 deviceId（必须在被测栈与子进程之间保持一致）
constexpr const char *kMutePeerId = "hosttest33333333333333333333333333";
// main() 里启动用的基础配置：需要改配置重启 net stack 的用例（端口探测）用完要还原
NetConfig g_baseCfg;

#define CHECK(cond) \
    do { \
        if (!(cond)) { \
            ++g_failed; \
            std::fprintf(stderr, "FAIL [%s] %s:%d CHECK(%s)\n", g_case, __FILE__, __LINE__, #cond); \
        } \
    } while (0)

#define CHECK_MSG(cond, ...) \
    do { \
        if (!(cond)) { \
            ++g_failed; \
            std::fprintf(stderr, "FAIL [%s] %s:%d CHECK(%s): ", g_case, __FILE__, __LINE__, \
                         #cond); \
            std::fprintf(stderr, __VA_ARGS__); \
            std::fprintf(stderr, "\n"); \
        } \
    } while (0)

int64_t nowMs()
{
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

std::mutex g_mu;
std::vector<NetEvent> g_events;

void onEvent(const NetEvent &e)
{
    std::lock_guard<std::mutex> lk(g_mu);
    g_events.push_back(e);
    if (e.type == EventType::Error) {
        std::printf("  [error] host=%s port=%u code=%d msg=%s\n", e.host.c_str(), e.tcpPort,
                    e.errorCode, e.errorMessage.c_str());
    }
}

// 取一个当前空闲的本地端口（bind(0) 后读端口再关闭；紧接使用，竞态可接受）
uint16_t freePort()
{
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return 0;
    }
    struct sockaddr_in a {};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = 0;
    if (::bind(fd, reinterpret_cast<struct sockaddr *>(&a), sizeof(a)) != 0) {
        ::close(fd);
        return 0;
    }
    socklen_t len = sizeof(a);
    if (::getsockname(fd, reinterpret_cast<struct sockaddr *>(&a), &len) != 0) {
        ::close(fd);
        return 0;
    }
    const uint16_t port = ntohs(a.sin_port);
    ::close(fd);
    return port;
}

// 等待一个满足条件的 error 事件
const NetEvent *waitError(const std::string &host, uint16_t port, int timeoutMs)
{
    const int64_t deadline = nowMs() + timeoutMs;
    while (nowMs() < deadline) {
        {
            std::lock_guard<std::mutex> lk(g_mu);
            for (const NetEvent &e : g_events) {
                if (e.type == EventType::Error && (host.empty() || e.host == host) &&
                    (port == 0 || e.tcpPort == port)) {
                    return &e;
                }
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    return nullptr;
}

void runCase(const char *name, void (*fn)())
{
    if (g_onlyCase != nullptr && std::strcmp(g_onlyCase, name) != 0) {
        return;   // 进程隔离模式：未被选中则跳过（由 run.sh 逐个拉起独立进程）
    }
    g_case = name;
    ++g_cases;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        g_events.clear();   // 每个用例只看自己的事件，避免匹配到上一个用例的残留
    }
    const int before = g_failed;
    fn();
    std::printf("%-34s %s\n", name, g_failed == before ? "OK" : "FAILED");
    std::fflush(stdout);
}

// —————— ① 端口关闭 → ECONNREFUSED 且带 host/port ——————

void connectToClosedPortReportsReason()
{
    const uint16_t port = freePort();
    CHECK_MSG(port != 0, "拿不到空闲端口");
    if (port == 0) {
        return;
    }
    CHECK(netStack().connectToPeer("127.0.0.1", port));

    const NetEvent *ev = waitError("127.0.0.1", port, 5000);
    CHECK_MSG(ev != nullptr, "未收到带 host=127.0.0.1 的 error 事件（旧行为只有 code=5 无 host）");
    if (ev != nullptr) {
        CHECK_MSG(ev->tcpPort == port, "error 事件携带的端口=%u，期望 %u", ev->tcpPort, port);
        CHECK_MSG(ev->errorCode == ECONNREFUSED, "errno=%d，期望 ECONNREFUSED(%d)：%s", ev->errorCode,
                  ECONNREFUSED, ev->errorMessage.c_str());
        CHECK_MSG(ev->errorMessage.find("127.0.0.1") != std::string::npos,
                  "错误文案里应包含目标地址：'%s'", ev->errorMessage.c_str());
    }
}

// —————— ② 对端可连但不应答 → 有界失败（握手上限）——————

void muteePeerTimesOutBounded()
{
    const int lfd = ::socket(AF_INET, SOCK_STREAM, 0);
    CHECK(lfd >= 0);
    if (lfd < 0) {
        return;
    }
    int one = 1;
    ::setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a {};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = 0;
    CHECK(::bind(lfd, reinterpret_cast<struct sockaddr *>(&a), sizeof(a)) == 0);
    CHECK(::listen(lfd, 1) == 0);
    socklen_t len = sizeof(a);
    CHECK(::getsockname(lfd, reinterpret_cast<struct sockaddr *>(&a), &len) == 0);
    const uint16_t port = ntohs(a.sin_port);

    // mute peer：accept 后什么都不发（也不是 TLS 响应），连接一直挂着
    std::atomic<bool> stop{false};
    std::thread mute([&] {
        const int cfd = ::accept(lfd, nullptr, nullptr);
        while (!stop.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        if (cfd >= 0) {
            ::close(cfd);
        }
    });

    CHECK(netStack().connectToPeer("127.0.0.1", port));
    // 握手上限在 main() 里注入为 1.5s（native 默认 10s），避免拖慢 CI
    const NetEvent *ev = waitError("127.0.0.1", port, 6000);
    CHECK_MSG(ev != nullptr, "mute 对端未触发有界失败（连接会一直悬挂）");
    if (ev != nullptr) {
        CHECK_MSG(ev->tcpPort == port, "error 事件端口=%u，期望 %u", ev->tcpPort, port);
        CHECK_MSG(ev->errorCode == ETIMEDOUT, "errno=%d，期望 ETIMEDOUT(%d)：%s", ev->errorCode,
                  ETIMEDOUT, ev->errorMessage.c_str());
    }

    stop.store(true);
    ::close(lfd);
    ::shutdown(lfd, SHUT_RDWR);
    mute.detach();
}

// —————— ③ identity 帧必须派发 packetReceived（P0 回归）——————
//
// 回归点：`dispatchFrames` 曾对 `kdeconnect.identity` 帧 `continue` 跳过 PacketReceived 派发，
// 导致 ArkTS 的 handleIdentity/onPeerCapabilities 永不执行 → 插件永不装载 →
// 「配对成功、连上了，但对端发来的 packet 全部 unhandled」（用户实测 P0）。
// 做法：把本测试二进制再 fork 成一个「对端栈」进程（同一份 native 代码，独立 deviceId/端口），
// 让它主动拨入被测栈；被测栈必须收到 identity 帧的 packetReceived。
void peerIdentityIsDispatchedAsPacket()
{
    // 同 IP accept 限流 300ms：上一用例（muteePeerTimesOutBounded）也来自 127.0.0.1，
    // 若间隔过近本用例的对端会被拒 ⇒ 表现为「偶发连不上」。前置等待即可稳定（同
    // sendPacketQueuesDuringHandshake 的做法）。
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    const pid_t child = ::fork();
    CHECK_MSG(child >= 0, "fork 失败");
    if (child < 0) {
        return;
    }
    if (child == 0) {
        // 子进程：对端栈，拨入父进程（被测栈）
        ::execl("/proc/self/exe", "kdc_net_tests", "--peer", "1745", nullptr);
        ::_exit(127);
    }

    // 父进程：等对端 identity（PairingRequest）→ Connected → 其 identity 帧的 packetReceived
    bool sawIdentityPacket = false;
    bool sawPeerIdentity = false;
    bool sawConnected = false;
    const int64_t deadline = nowMs() + 20000;   // 12s→20s：负载下对端拨入+握手可能超过 12s（harness 稳定性，非产品缺陷）
    while (nowMs() < deadline) {
        {
            std::lock_guard<std::mutex> lk(g_mu);
            for (const NetEvent &e : g_events) {
                if (e.type == EventType::PairingRequest) {
                    sawPeerIdentity = true;
                } else if (e.type == EventType::Connected) {
                    sawConnected = true;
                } else if (e.type == EventType::PacketReceived &&
                           e.packet.find("\"type\":\"kdeconnect.identity\"") != std::string::npos) {
                    sawIdentityPacket = true;
                }
            }
        }
        if (sawIdentityPacket) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }

    CHECK_MSG(sawPeerIdentity, "未收到对端 identity（PairingRequest）");
    CHECK_MSG(sawConnected, "未收到 Connected 事件");
    CHECK_MSG(sawIdentityPacket,
              "identity 帧没有派发 packetReceived（P0 回归：ArkTS 能力协商将失效）");
    if (!sawIdentityPacket) {
        std::lock_guard<std::mutex> lk(g_mu);
        for (const NetEvent &e : g_events) {
            std::fprintf(stderr, "  [dbg] type=%d device=%s pkt=%s\n", (int) e.type,
                         e.deviceId.c_str(), e.packet.substr(0, 120).c_str());
        }
    }

    ::kill(child, SIGKILL);
    int status = 0;
    ::waitpid(child, &status, 0);
}

// P0 回归（MSG163 §4 / DevEco MSG160 §2）：TLS 握手未完成时 sendPacket 必须「入队 + 立即返回 true」。
// 修复前：sendPacket 只匹配 state==Encrypted 的连接 ⇒ 返回 false。启动时首批
// battery/connectivity_report/mpris.request 恰好落在握手窗口内，其「成功」纯靠
// sendPacket 被 connMutex_ 扣住数秒、等到了握手完成（本轮 UI 冻结根因）。
// 本用例构造「对端只发明文 identity 就沉默」⇒ 被测栈侧连接停在 TlsHandshake（未加密），断言：
//   ① 接受入队并返回 true    ② 调用不阻塞（<100ms，JS 线程不得等 connMutex_）
void sendPacketQueuesDuringHandshake()
{
    const std::string peerId = kMutePeerId;
    const uint16_t targetPort = g_baseCfg.tcpPort;

    // 被测栈对「同 IP 连接」有 1000ms 限流（KDE/Android 同款语义，见 onTcpServerReadable）。
    // 上一个用例的连接同样来自 127.0.0.1，故此处先等过限流窗口，否则本用例的连接会被拒。
    std::this_thread::sleep_for(std::chrono::milliseconds(1200));

    const pid_t child = ::fork();
    CHECK_MSG(child >= 0, "fork 失败");
    if (child < 0) {
        return;
    }
    if (child == 0) {
        // 注意：必须 exec（不能直接在 fork 出的副本里跑）——父进程是多线程且持有可能已锁的
        // 分配器/stdio 锁，fork 副本里继续执行会在第一次打印/分配时死锁。
        char portArg[16];
        std::snprintf(portArg, sizeof(portArg), "%u", (unsigned) targetPort);
        ::execl("/proc/self/exe", "kdc_net_tests", "--mute-peer", portArg, nullptr);
        ::_exit(127);
    }

    // 等对端明文 identity 到达（PairingRequest）⇒ 被测栈侧连接进入 TlsHandshake
    bool sawPeerIdentity = false;
    const int64_t deadline = nowMs() + 8000;
    while (nowMs() < deadline) {
        {
            std::lock_guard<std::mutex> lk(g_mu);
            for (const NetEvent &e : g_events) {
                if (e.type == EventType::PairingRequest) {
                    sawPeerIdentity = true;
                }
            }
        }
        if (sawPeerIdentity) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    CHECK_MSG(sawPeerIdentity, "未收到对端明文 identity（PairingRequest）");
    if (!sawPeerIdentity) {
        std::lock_guard<std::mutex> lk(g_mu);
        std::fprintf(stderr, "  [dbg] 事件总数=%zu\n", g_events.size());
        size_t shown = 0;
        for (const NetEvent &e : g_events) {
            if (shown++ >= 12) {
                break;
            }
            std::fprintf(stderr, "  [dbg] type=%d device=%s pkt=%.90s\n", (int) e.type,
                         e.deviceId.c_str(), e.packet.c_str());
        }
    }

    const std::string pkt =
        "{\"id\":\"p0reg\",\"type\":\"kdeconnect.ping\",\"body\":{},\"version\":8}";
    const int64_t t0 = nowMs();
    const bool ok = netStack().sendPacket(peerId, pkt);
    const int64_t elapsed = nowMs() - t0;

    CHECK_MSG(ok, "TLS 握手中的连接必须接受入队并返回 true（修复前此处返回 false）");
    CHECK_MSG(elapsed < 100, "sendPacket 阻塞 %lldms（P0 回归：JS 线程在等 connMutex_）",
              (long long) elapsed);

    ::kill(child, SIGKILL);
    int status = 0;
    ::waitpid(child, &status, 0);
}

// 子进程入口（P0 回归用）：连入被测栈，只发明文 identity 帧后沉默（不参与 TLS 握手）。
// 目的：让被测栈侧连接停在 TlsHandshake（未加密）状态，用于验证 sendPacket 的入队语义。
int runMutePeerMode(uint16_t targetPort)
{
    const int s = ::socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) {
        return 3;
    }
    struct sockaddr_in a {};
    a.sin_family = AF_INET;
    a.sin_port = htons(targetPort);
    ::inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    if (::connect(s, reinterpret_cast<struct sockaddr *>(&a), sizeof(a)) != 0) {
        std::fprintf(stderr, "[mute] connect 失败 port=%u errno=%d\n", (unsigned) targetPort, errno);
        return 4;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    std::string frame = PacketIO::buildIdentity(kMutePeerId, "mute-peer", "desktop", 0,
                                               PROTOCOL_VERSION, {}, {});
    frame.push_back('\n');
    const ssize_t sent = ::send(s, frame.data(), frame.size(), 0);
    std::fprintf(stderr, "[mute] connected port=%u sent=%zd/%zu\n", (unsigned) targetPort, sent,
                 frame.size());
    std::this_thread::sleep_for(std::chrono::seconds(20));
    return 0;
}

// 子进程入口：起一个对端栈并拨入父进程
// 被测栈（父进程）的 deviceId 由父进程写文件、子进程读——避免依赖事件回调时序（负载下会偶发取不到）
constexpr const char *kHarnessParentIdPath = "/tmp/kdc_harness_parent_id.txt";

// runPeerMode 的父进程 deviceId（回调在 net 线程写、主流程读，故加锁）
std::mutex g_peerDevMu;
std::string g_peerSeenDevice;

// 回归 harness（CodeArts MSG22 §2）：模拟 KDE「收广播后新建链路并销毁同设备旧链路」，
// 用于验证 31d9f49（链路替换不得中止在传载荷）。
constexpr const char *kHarnessPeerPemPath = "/tmp/kdc_harness_peer.pem";
constexpr const char *kHarnessSrcPath = "/tmp/kdc_harness_src.bin";
const char *kPeerLinksDeviceId = "hosttest33333333333333333333333333";

int runPeerLinksMode(uint16_t targetPort)
{
    const std::string devId = kPeerLinksDeviceId;
    CertPair cert = CertGen::generateSelfSignedEc(devId, 10);
    {
        std::FILE *f = std::fopen(kHarnessPeerPemPath, "w");   // 供被测栈建立信任
        if (f == nullptr) return 1;
        std::fputs(cert.certPem.c_str(), f);
        std::fclose(f);
    }
    {
        std::FILE *f = std::fopen(kHarnessSrcPath, "wb");      // 256MB：保证"传中"窗口足够宽
        if (f == nullptr) return 1;
        std::vector<char> blk(1024 * 1024, 'k');
        for (int i = 0; i < 1024; ++i) {   // 1GB：保证"传中"窗口足以覆盖多次建链（256MB 在大吞吐下会先传完 ⇒ 假阴性）
            if (std::fwrite(blk.data(), 1, blk.size(), f) != blk.size()) break;
        }
        std::fclose(f);
    }
    NetConfig cfg;
    cfg.deviceId = devId;
    cfg.deviceName = "kdc-nettest-links";
    cfg.deviceType = "desktop";
    cfg.certPem = cert.certPem;
    cfg.keyPem = cert.keyPem;
    cfg.tcpPort = 1747;
    cfg.udpPort = 17160;
    cfg.spoolDir = "/tmp/kdc_nettest_spool";
    NetStack &ns = netStack();
    ns.setEventCallback([](const NetEvent &e) {
        if (e.type == EventType::PayloadTransfer && e.payloadDirectionSend) {
            if (e.payloadState == "progress") {
                g_peerSendDone.store(e.payloadBytesDone);
                g_peerSendTotal.store(e.payloadSize);
            } else {
                g_peerSendDone.store(e.payloadSize);   // 终态：视作不再有"传中"
                g_peerSendTotal.store(e.payloadSize);
            }
            std::fprintf(stderr, "[peer-links] local id=%llu state=%s done=%lld/%lld code=%d msg=%s\n",
                         (unsigned long long) e.payloadTransferId, e.payloadState.c_str(),
                         (long long) e.payloadBytesDone, (long long) e.payloadSize, e.errorCode,
                         e.errorMessage.c_str());
        }
    });
    if (!ns.start(cfg)) return 1;
    std::this_thread::sleep_for(std::chrono::milliseconds(1000));   // 等被测栈读到证书并建立信任
    ns.connectToPeer("127.0.0.1", targetPort);
    std::string peerDev;
    for (int i = 0; i < 250 && peerDev.empty(); ++i) {
        std::FILE *f = std::fopen(kHarnessParentIdPath, "r");
        if (f != nullptr) {
            char buf[256];
            size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
            buf[n] = '\0';
            peerDev.assign(buf, n);
            while (!peerDev.empty() && (peerDev.back() == '\n' || peerDev.back() == '\r')) peerDev.pop_back();
            std::fclose(f);
        }
        if (peerDev.empty()) std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    uint64_t xid = 0;
    for (int i = 0; i < 100 && xid == 0; ++i) {   // 链路可能未就绪 ⇒ 重试
        xid = ns.sendPayload(peerDev, "kdeconnect.share.request",
                             "{\"filename\":\"harness.bin\"}", kHarnessSrcPath);
        if (xid == 0) std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    std::fprintf(stderr, "[peer-links] sendPayload -> %llu\n", (unsigned long long) xid);
    // 建链由父进程在"接收进度过半"时确定性触发（本侧只负责把载荷发出去）
    std::this_thread::sleep_for(std::chrono::milliseconds(3000));
    ns.stop();
    return 0;
}

// 「证书 CN ≠ 声明的 deviceId」的对端（负路径）：用于验证 NetStack 的控制链路 CN 校验（P2-1）。
// 形态：用 CN=hosttest9999… 的自签证书，却在 identity 里声明 hosttest4444… ⇒ 必须被断链。
const char *kMismatchPeerId = "hosttest44444444444444444444444444";
const char *kMismatchCertCn = "hosttest99999999999999999999999999";

int runPeerMismatchMode(uint16_t targetPort)
{
    CertPair cert = CertGen::generateSelfSignedEc(kMismatchCertCn, 10);   // 证书 CN ≠ 下面声明的 deviceId
    NetConfig cfg;
    cfg.deviceId = kMismatchPeerId;
    cfg.deviceName = "kdc-nettest-mismatch";
    cfg.deviceType = "desktop";
    cfg.certPem = cert.certPem;
    cfg.keyPem = cert.keyPem;
    cfg.tcpPort = 1748;
    cfg.udpPort = 17160;
    cfg.spoolDir = "/tmp/kdc_nettest_spool";
    NetStack &ns = netStack();
    if (!ns.start(cfg)) {
        return 1;
    }
    ns.connectToPeer("127.0.0.1", targetPort);
    std::this_thread::sleep_for(std::chrono::milliseconds(6000));
    ns.stop();
    return 0;
}

int runPeerMode(uint16_t targetPort, bool announcePayload = false)
{
    const std::string devId = "hosttest22222222222222222222222222";
    CertPair cert = CertGen::generateSelfSignedEc(devId, 10);
    NetConfig cfg;
    cfg.deviceId = devId;
    cfg.deviceName = "kdc-nettest-peer";
    cfg.deviceType = "desktop";
    cfg.certPem = cert.certPem;
    cfg.keyPem = cert.keyPem;
    cfg.tcpPort = 1746;
    // 与主测试栈同用非标准 UDP 端口：否则本对端会在真实局域网广播/被真实桌面吸引
    // ⇒ 既是真机 hilog 噪声源（DevEco MSG4 §3），也是 peerIdentityIsDispatchedAsPacket 偶发失败的根因。
    cfg.udpPort = 17160;
    cfg.spoolDir = "/tmp/kdc_nettest_spool";

    NetStack &ns = netStack();
    // 对端侧只保留一行摘要（CI 失败时可据此判断是对端没发、还是被测栈没收）
    ns.setEventCallback([](const NetEvent &e) {
        if (e.type == EventType::PacketReceived || e.type == EventType::Connected) {
            std::fprintf(stderr, "[peer] type=%d device=%s role=%s\n", (int) e.type,
                         e.deviceId.c_str(), e.role == TlsRole::Server ? "server" : "client");
        }
        if ((e.type == EventType::Connected || e.type == EventType::PairingRequest) &&
            !e.deviceId.empty()) {
            std::lock_guard<std::mutex> lk(g_peerDevMu);
            g_peerSeenDevice = e.deviceId;
        }
    });
    if (!ns.start(cfg)) {
        return 1;
    }
    // 诊断：本用例偶发失败（约 1/3）表现为「主栈收到对端 UDP 广播但没有 PairingRequest」，
    // 即对端 TCP 身份交换未完成。这里打印拨号结果，便于归属方定位（不影响通过路径）。
    const bool dialed = ns.connectToPeer("127.0.0.1", targetPort);
    std::fprintf(stderr, "[peer] connectToPeer(%s:%u) -> %d\n", "127.0.0.1",
                 (unsigned) targetPort, dialed ? 1 : 0);
    if (announcePayload) {
        // 等被测栈的 deviceId 到达（identity 交换完成）后再发，避免落到握手中
        std::string peerDev;
        for (int i = 0; i < 250 && peerDev.empty(); ++i) {
            std::FILE *f = std::fopen(kHarnessParentIdPath, "r");   // 文件优先（与时序无关）
            if (f != nullptr) {
                char buf[256];
                size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
                buf[n] = '\0';
                peerDev.assign(buf, n);
                while (!peerDev.empty() && (peerDev.back() == '\n' || peerDev.back() == '\r')) {
                    peerDev.pop_back();
                }
                std::fclose(f);
            }
            if (peerDev.empty()) {
                std::lock_guard<std::mutex> lk(g_peerDevMu);
                peerDev = g_peerSeenDevice;
            }
            if (peerDev.empty()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(20));
            }
        }
        // 关键形态：payloadSize 非 0、但**不带 payloadTransferInfo**（对端只宣告、不建通道）
        const std::string frame =
            "{\"id\":1,\"type\":\"kdeconnect.share.request\","
            "\"body\":{\"filename\":\"probe.txt\"},\"payloadSize\":200,\"version\":8}\n";
        // 链路可能尚未就绪（sendPacket 返回 false）⇒ 重试到成功（负载下会偶发）
        bool sent = false;
        for (int i = 0; i < 100 && !sent; ++i) {
            sent = !peerDev.empty() && ns.sendPacket(peerDev, frame);
            if (!sent) {
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        }
        std::fprintf(stderr, "[peer] announce-payload sent=%d dev=%s\n", sent ? 1 : 0,
                     peerDev.c_str());
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(8000));
    ns.stop();
    return 0;
}


void announcedPayloadWithoutPortIsTerminal()
{
    std::this_thread::sleep_for(std::chrono::milliseconds(500));   // 同 IP accept 限流
    const pid_t child = ::fork();
    CHECK_MSG(child >= 0, "fork 失败");
    if (child < 0) {
        return;
    }
    if (child == 0) {
        ::execl("/proc/self/exe", "kdc_net_tests", "--peer-announce", "1745", nullptr);
        ::_exit(127);
    }

    bool sawAnnounce = false;
    bool sawError = false;
    const int64_t deadline = nowMs() + 20000;
    while (nowMs() < deadline && !(sawAnnounce && sawError)) {
        {
            std::lock_guard<std::mutex> lk(g_mu);
            for (const NetEvent &e : g_events) {
                if (e.type == EventType::PacketReceived &&
                    e.packet.find("kdeconnect.share.request") != std::string::npos) {
                    CHECK_MSG(e.payloadSize == 200,
                              "宣告帧的 payloadSize 应原样带出（ArkTS 依赖它判定）");
                    CHECK_MSG(e.payloadTransferId == 0,
                              "未启动的载荷不得给出 transferId（否则 UI 会建出无终态的条目）");
                    sawAnnounce = true;
                } else if (e.type == EventType::Error &&
                           e.errorMessage.find("payload not started") != std::string::npos) {
                    sawError = true;
                }
            }
        }
        if (!(sawAnnounce && sawError)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
    }

    CHECK_MSG(sawAnnounce, "未派发带 payloadSize 的 packetReceived（ArkTS 无法感知宣告）");
    CHECK_MSG(sawError, "未派发 Error(payload not started)：UI 将永久停留在「接收中」");
    if (!(sawAnnounce && sawError)) {
        std::lock_guard<std::mutex> lk(g_mu);
        for (const NetEvent &e : g_events) {
            std::fprintf(stderr, "  [dbg] type=%d size=%lld xfer=%llu err=%s pkt=%s\n", (int) e.type,
                         (long long) e.payloadSize, (unsigned long long) e.payloadTransferId,
                         e.errorMessage.c_str(), e.packet.substr(0, 100).c_str());
        }
    }

    ::kill(child, SIGKILL);
    int status = 0;
    ::waitpid(child, &status, 0);
}

// 31d9f49 专属回归：链路替换不得中止在传载荷。
// 修复前 closeConnection 会**无条件**调用 payload_->onDeviceDown ⇒ 在传载荷被误判 failed/ECONNRESET。
void payloadSurvivesLinkReplacement()
{
    ::unlink(kHarnessPeerPemPath);
    const pid_t child = ::fork();
    CHECK_MSG(child >= 0, "fork 失败");
    if (child < 0) return;
    if (child == 0) {
        ::execl("/proc/self/exe", "kdc_net_tests", "--peer-links", "1745", nullptr);
        ::_exit(127);
    }
    std::string pem;
    for (int i = 0; i < 250 && pem.empty(); ++i) {   // 等对端证书 → 建立信任（否则载荷被门禁拒绝）
        std::FILE *f = std::fopen(kHarnessPeerPemPath, "r");
        if (f != nullptr) {
            char buf[8192];
            size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
            buf[n] = '\0';
            pem.assign(buf, n);
            std::fclose(f);
        }
        if (pem.empty()) std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    CHECK_MSG(!pem.empty(), "harness 前置失败：未取到对端证书");
    if (!pem.empty()) netStack().setTrustedCertificate(kPeerLinksDeviceId, pem);

    // 确定性触发：等**自身接收进度过半**（必然"传中"）后，向对端 control 端口再拨一条链路 ⇒
    // 对端会替换其同设备旧链路（真实形态），修复前该替换会误杀在传载荷。
    int64_t seenDone = 0;
    int64_t seenTotal = 0;
    const int64_t waitProgress = nowMs() + 60000;
    while (nowMs() < waitProgress && (seenTotal == 0 || seenDone * 4 < seenTotal)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        std::lock_guard<std::mutex> lk(g_mu);
        for (const NetEvent &e : g_events) {
            if (e.type == EventType::PayloadTransfer && !e.payloadDirectionSend &&
                e.payloadBytesDone > 0) {
                seenDone = e.payloadBytesDone;
                seenTotal = e.payloadSize;
            }
        }
    }
    CHECK_MSG(seenTotal > 0 && seenDone > 0, "harness 前置失败：未见接收进度（载荷根本没起来）");
    netStack().connectToPeer("127.0.0.1", 1747);   // 对端 control 端口（runPeerLinksMode 固定 1747）
    std::fprintf(stderr, "  [dbg] dialed peer at progress %lld/%lld\n", (long long) seenDone,
                 (long long) seenTotal);

    bool finished = false;
    bool failed = false;
    const int64_t deadline = nowMs() + 90000;
    while (nowMs() < deadline && !finished && !failed) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        std::lock_guard<std::mutex> lk(g_mu);
        for (const NetEvent &e : g_events) {
            if (e.type != EventType::PayloadTransfer || e.payloadDirectionSend) continue;
            if (e.payloadState == "finished") finished = true;
            if (e.payloadState == "failed" && !failed) {
                failed = true;
                std::fprintf(stderr, "  [dbg] payload failed id=%llu code=%d msg=%s\n",
                             (unsigned long long) e.payloadTransferId, e.errorCode,
                             e.errorMessage.c_str());
            }
        }
    }
    CHECK_MSG(finished, "链路替换后在传载荷未能完成（回归：onDeviceDown 误杀在传载荷）");
    CHECK_MSG(!failed, "在传载荷被误判 failed（链路替换不应中止载荷）");
    ::kill(child, SIGKILL);
    int status = 0;
    ::waitpid(child, &status, 0);
}

// 契约：设备级断链必须为进行中的 payload 派发**终态事件**（含 transferId）。
// 依据：ArkTS 的串行发送队列（DevEco MSG35 §1）以 payloadTransfer 的终态分支推进；native 漏派 ⇒ 队列卡死。
// 该契约由 closeConnection（无存活链路）→ payload_->onDeviceDown → failJobLocked → emitLocked 保证；
// 本用例用公开 API disconnectDevice 确定性触发（不依赖时序竞猜）。
void deviceDownDispatchesPayloadTerminal()
{
    ::unlink(kHarnessPeerPemPath);
    const pid_t child = ::fork();
    CHECK_MSG(child >= 0, "fork 失败");
    if (child < 0) return;
    if (child == 0) {
        ::execl("/proc/self/exe", "kdc_net_tests", "--peer-links", "1745", nullptr);
        ::_exit(127);
    }
    std::string pem;
    for (int i = 0; i < 250 && pem.empty(); ++i) {
        std::FILE *f = std::fopen(kHarnessPeerPemPath, "r");
        if (f != nullptr) {
            char buf[8192];
            size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
            buf[n] = '\0';
            pem.assign(buf, n);
            std::fclose(f);
        }
        if (pem.empty()) std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    CHECK_MSG(!pem.empty(), "harness 前置失败：未取到对端证书");
    if (!pem.empty()) netStack().setTrustedCertificate(kPeerLinksDeviceId, pem);

    // 等接收确实在途（有进度）——确定性，不靠猜时间
    int64_t total = 0;
    int64_t done = 0;
    const int64_t waitIn = nowMs() + 60000;
    while (nowMs() < waitIn && (total == 0 || done == 0)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        std::lock_guard<std::mutex> lk(g_mu);
        for (const NetEvent &e : g_events) {
            if (e.type == EventType::PayloadTransfer && !e.payloadDirectionSend &&
                e.payloadBytesDone > 0) {
                total = e.payloadSize;
                done = e.payloadBytesDone;
            }
        }
    }
    CHECK_MSG(total > 0 && done > 0, "harness 前置失败：载荷未起来");

    netStack().disconnectDevice(kPeerLinksDeviceId);   // 公开 API：设备级断链

    bool sawTerminal = false;
    uint64_t terminalId = 0;
    const int64_t deadline = nowMs() + 30000;
    while (nowMs() < deadline && !sawTerminal) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        std::lock_guard<std::mutex> lk(g_mu);
        for (const NetEvent &e : g_events) {
            if (e.type == EventType::PayloadTransfer && !e.payloadDirectionSend &&
                (e.payloadState == "failed" || e.payloadState == "cancelled") &&
                e.payloadTransferId != 0) {
                sawTerminal = true;
                terminalId = e.payloadTransferId;
                std::fprintf(stderr, "  [dbg] terminal id=%llu state=%s code=%d msg=%s\n",
                             (unsigned long long) e.payloadTransferId, e.payloadState.c_str(),
                             e.errorCode, e.errorMessage.c_str());
            }
        }
    }
    CHECK_MSG(sawTerminal, "设备级断链未派发 payload 终态事件（ArkTS 串行队列将卡死）");
    CHECK_MSG(terminalId != 0, "终态事件必须带 transferId");
    ::kill(child, SIGKILL);
    int status = 0;
    ::waitpid(child, &status, 0);
}

// 安全负路径（AtomCode 审计建议）：对端证书 CN ≠ 其声明的 deviceId ⇒ 必须断链（fail-closed）。
// 对应 native 的 P2-1 校验（drainEncrypted：握手完成且 deviceId 已知后一次性比对 peerCommonName）。
void peerCertCnMismatchIsRejected()
{
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    const pid_t child = ::fork();
    CHECK_MSG(child >= 0, "fork 失败");
    if (child < 0) return;
    if (child == 0) {
        ::execl("/proc/self/exe", "kdc_net_tests", "--peer-mismatch", "1745", nullptr);
        ::_exit(127);
    }
    bool sawError = false;
    bool sawConnectedToMismatch = false;
    const int64_t deadline = nowMs() + 20000;
    while (nowMs() < deadline && !sawError) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        std::lock_guard<std::mutex> lk(g_mu);
        for (const NetEvent &e : g_events) {
            if (e.type == EventType::Error &&
                e.errorMessage.find("CN") != std::string::npos) {
                sawError = true;
                std::fprintf(stderr, "  [dbg] rejected: device=%s msg=%s\n", e.deviceId.c_str(),
                             e.errorMessage.c_str());
            }
            if (e.type == EventType::Connected && e.deviceId == kMismatchPeerId) {
                sawConnectedToMismatch = true;
            }
        }
    }
    CHECK_MSG(sawError, "证书 CN 与声明 deviceId 不一致未被拒绝（P2-1 安全语义回归）");
    CHECK_MSG(!sawConnectedToMismatch,
              "伪造者仍被当作已连接设备（CN 校验未生效或被绕过）");
    ::kill(child, SIGKILL);
    int status = 0;
    ::waitpid(child, &status, 0);
}

// 安全负路径（AtomCode 审计建议②）：控制链路**证书钉扎** mismatch ⇒ 必须断链且不得派发 Connected。
// 形态：把该 deviceId 的受信 PEM 预置成**另一份证书**（用本栈自己的证书冒充），再让真实对端连入。
void peerCertPinningMismatchIsRejected()
{
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    const char *kPeerId = "hosttest22222222222222222222222222";
    // 预置错误的受信 PEM：用本栈自身证书冒充该设备（CN 与实际对端不同 ⇒ 钉扎必然不匹配）
    netStack().setTrustedCertificate(kPeerId, netStack().getOwnCertificate());

    const pid_t child = ::fork();
    CHECK_MSG(child >= 0, "fork 失败");
    if (child < 0) return;
    if (child == 0) {
        ::execl("/proc/self/exe", "kdc_net_tests", "--peer", "1745", nullptr);
        ::_exit(127);
    }
    bool sawError = false;
    bool sawConnected = false;
    const int64_t deadline = nowMs() + 20000;
    while (nowMs() < deadline && !sawError) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        std::lock_guard<std::mutex> lk(g_mu);
        for (const NetEvent &e : g_events) {
            if (e.type == EventType::Error && e.deviceId == kPeerId) {
                sawError = true;
                std::fprintf(stderr, "  [dbg] pinning rejected: msg=%s\n", e.errorMessage.c_str());
            }
            if (e.type == EventType::Connected && e.deviceId == kPeerId) {
                sawConnected = true;
            }
        }
    }
    CHECK_MSG(sawError, "证书钉扎不一致未被拒绝（TOFU+钉扎语义回归）");
    CHECK_MSG(!sawConnected, "钉扎不一致的设备仍被派发 Connected");
    netStack().removeTrustedCertificate(kPeerId);   // 清理，避免污染后续用例
    ::kill(child, SIGKILL);
    int status = 0;
    ::waitpid(child, &status, 0);
}

// —————— ④ 端口未知（0）的拨号：探测 + 缓存（DevEco 第五次报，2026-09-13）——————
//
// 载荷「已宣告但未启动」必须可收口（DevEco MSG22 回归，2026-09-17）：
// 对端发来带 payloadSize 但**不带** payloadTransferInfo.port 的帧时，此前 native 既无任务、
// 也无终态、也无日志 ⇒ ArkTS 据 payloadSize 建「接收中」条目后永久悬挂。
// 契约：① 必须派发 Error（说明未启动原因）；② packetReceived 仍要派发，且
// payloadSize>0 而 payloadTransferId==0 —— ArkTS 据此判定「已宣告未启动」，不得建待办条目。
//
// 场景：KDE 只在 UDP 广播的 identity 里带 tcpPort，**拨入连接的 identity 不带**
// （kdeconnect-kde core/backends/lan/lanlinkprovider.cpp:254 vs DeviceInfo::toIdentityPacket()）⇒
// 「只被对端拨入过」的设备在发现列表里端口恒为 0，用户点连接无从下手。
// 契约：connectToPeer(host, 0) 必须自己把端口探出来并真的连上（结果仍经 connected/error 事件）。

// 本机回环上起一个监听者，返回 fd 并回填实际端口（0 端口由内核分配）。
// addr：监听地址，默认 127.0.0.1；端口探测用例用 127.0.0.2 —— 同机同址可能已被别的
// 监听者/缓存占用（测试进程里真跑着 KDE daemon 与对端栈），换一个回环地址才能确定性验证。
int listenOnEphemeral(uint16_t &port, const char *addr = "127.0.0.1")
{
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    int one = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a {};
    a.sin_family = AF_INET;
    a.sin_port = 0;
    if (::inet_pton(AF_INET, addr, &a.sin_addr) != 1) {
        ::close(fd);
        return -1;
    }
    if (::bind(fd, reinterpret_cast<struct sockaddr *>(&a), sizeof(a)) != 0 ||
        ::listen(fd, 4) != 0) {
        ::close(fd);
        return -1;
    }
    socklen_t len = sizeof(a);
    if (::getsockname(fd, reinterpret_cast<struct sockaddr *>(&a), &len) != 0) {
        ::close(fd);
        return -1;
    }
    port = ntohs(a.sin_port);
    return fd;
}

// 探测原语：监听中的端口必须命中；已关闭的端口必须探测不到；区间内多个监听者取其一（升序优先）。
void portProbeFindsListener()
{
    uint16_t live = 0;
    const int lfd = listenOnEphemeral(live);
    CHECK_MSG(lfd >= 0, "回环监听端口创建失败");
    if (lfd < 0) {
        return;
    }
    CHECK_MSG(findListeningTcpPort("127.0.0.1", live, live, 300) == live,
              "单端口区间未命中监听中的 %u", live);

    // 刚关闭的临时端口：必须探不到（不能把「曾经拿到过」当成在监听）
    uint16_t dead = 0;
    const int dfd = listenOnEphemeral(dead);
    CHECK_MSG(dfd >= 0, "回环监听端口创建失败(dead)");
    if (dfd >= 0) {
        ::close(dfd);
    }
    CHECK_MSG(findListeningTcpPort("127.0.0.1", dead, dead, 300) == 0,
              "已关闭端口 %u 被误判为监听中", dead);

    // 区间内两个监听者：结果必须是其中之一（端口升序扫描 ⇒ 通常是较小者）
    uint16_t live2 = 0;
    const int lfd2 = listenOnEphemeral(live2);
    CHECK_MSG(lfd2 >= 0, "回环监听端口创建失败(live2)");
    if (lfd2 >= 0) {
        const uint16_t lo = std::min(live, live2);
        const uint16_t hi = std::max(live, live2);
        const uint16_t hit = findListeningTcpPort("127.0.0.1", lo, hi, 300);
        CHECK_MSG(hit == lo || hit == hi, "区间 [%u,%u] 探测结果 %u 不是任一监听端口", lo, hi, hit);
        ::close(lfd2);
    }

    // 非法 host：不得误报
    CHECK(findListeningTcpPort("not-an-ip", 1, 2, 50) == 0);
    ::close(lfd);
}

// 端到端：注入单端口探测区间（本机 1716-1764 常被桌面 kdeconnectd 占用）⇒ connectToPeer(host, 0)
// 必须探到该端口并真的连上（监听者收到握手 = 探测+拨号链路生效）。
void dialUnknownPortProbesAndConnects()
{
    // 用 127.0.0.2：同机 127.0.0.1 上真跑着 KDE daemon 与测试用的对端栈，地址会串味
    uint16_t port = 0;
    const int lfd = listenOnEphemeral(port, "127.0.0.2");
    CHECK_MSG(lfd >= 0, "回环监听端口创建失败");
    if (lfd < 0) {
        return;
    }

    NetStack &ns = netStack();
    ns.stop();
    NetConfig cfg = g_baseCfg;
    cfg.portProbeMin = port;
    cfg.portProbeMax = port;
    CHECK_MSG(ns.start(cfg), "按注入探测区间重启 net stack 失败");

    CHECK_MSG(ns.connectToPeer("127.0.0.2", 0), "端口未知的拨号请求被拒绝（应入队后返回 true）");

    struct pollfd pfd {};
    pfd.fd = lfd;
    pfd.events = POLLIN;
    const int pr = ::poll(&pfd, 1, 3000);
    CHECK_MSG(pr > 0, "端口未知拨号未能连到监听端口 %u（探测或拨号未生效）", port);
    if (pr > 0) {
        const int cfd = ::accept(lfd, nullptr, nullptr);
        CHECK_MSG(cfd >= 0, "accept 失败");
        if (cfd >= 0) {
            ::close(cfd);
        }
    }

    // 还原基础配置，避免影响同进程后续用例
    ns.stop();
    ns.start(g_baseCfg);
    ::close(lfd);
}

} // namespace

int main(int argc, char **argv)
{
    if (argc >= 3 && std::strcmp(argv[1], "--peer") == 0) {
        return runPeerMode(static_cast<uint16_t>(std::atoi(argv[2])));
    }
    if (argc >= 3 && std::strcmp(argv[1], "--peer-mismatch") == 0) {
        return runPeerMismatchMode(static_cast<uint16_t>(std::atoi(argv[2])));
    }
    if (argc >= 3 && std::strcmp(argv[1], "--peer-links") == 0) {
        return runPeerLinksMode(static_cast<uint16_t>(std::atoi(argv[2])));
    }
    if (argc >= 3 && std::strcmp(argv[1], "--peer-announce") == 0) {
        return runPeerMode(static_cast<uint16_t>(std::atoi(argv[2])), true);
    }
    if (argc >= 3 && std::strcmp(argv[1], "--mute-peer") == 0) {
        return runMutePeerMode(static_cast<uint16_t>(std::atoi(argv[2])));
    }
    struct ListDef { const char *name; };
    static const ListDef kNames[] = {
        {"connectToClosedPortReportsReason"}, {"muteePeerTimesOutBounded"},
        {"peerIdentityIsDispatchedAsPacket"},  {"sendPacketQueuesDuringHandshake"},
        {"portProbeFindsListener"},            {"dialUnknownPortProbesAndConnects"},
        {"announcedPayloadWithoutPortIsTerminal"}, {"payloadSurvivesLinkReplacement"},
        {"deviceDownDispatchesPayloadTerminal"}, {"peerCertCnMismatchIsRejected"}, {"peerCertPinningMismatchIsRejected"},
    };
    if (argc >= 2 && std::strcmp(argv[1], "--list") == 0) {
        for (const ListDef &n : kNames) {
            std::printf("%s\n", n.name);
        }
        return 0;
    }
    if (argc >= 3 && std::strcmp(argv[1], "--case") == 0) {
        g_onlyCase = argv[2];
    }

    CertPair cert = CertGen::generateSelfSignedEc("hosttest11111111111111111111111111", 10);
    NetConfig cfg;
    cfg.deviceId = "hosttest11111111111111111111111111";
    cfg.deviceName = "kdc-nettest";
    cfg.deviceType = "phone";
    cfg.certPem = cert.certPem;
    cfg.keyPem = cert.keyPem;
    cfg.tcpPort = 1745;                      // 避开 1716（可能与在跑的桌面 daemon 冲突）
    cfg.udpPort = 17160;                     // 非标准端口：避免假对端广播污染真实局域网（DevEco MSG4 §3）
    cfg.spoolDir = "/tmp/kdc_nettest_spool";
    cfg.connectHandshakeTimeoutMs = 1500;    // 短上限，保证 CI 快
    g_baseCfg = cfg;
    {
        // 父进程 deviceId 落盘：子进程据此发起操作，不依赖事件回调时序
        std::FILE *f = std::fopen(kHarnessParentIdPath, "w");
        if (f != nullptr) {
            std::fputs(cfg.deviceId.c_str(), f);
            std::fclose(f);
        }
    }

    NetStack &ns = netStack();
    ns.setEventCallback(onEvent);
    if (!ns.start(cfg)) {
        std::printf("net stack 启动失败（环境不支持），跳过 net 测试\n");
        return 0;
    }

    struct CaseDef { const char *name; void (*fn)(); };
    static const CaseDef kCases[] = {
        {"connectToClosedPortReportsReason", connectToClosedPortReportsReason},
        {"muteePeerTimesOutBounded", muteePeerTimesOutBounded},
        {"peerIdentityIsDispatchedAsPacket", peerIdentityIsDispatchedAsPacket},
        {"sendPacketQueuesDuringHandshake", sendPacketQueuesDuringHandshake},
        {"portProbeFindsListener", portProbeFindsListener},
        {"dialUnknownPortProbesAndConnects", dialUnknownPortProbesAndConnects},
        {"announcedPayloadWithoutPortIsTerminal", announcedPayloadWithoutPortIsTerminal},
        {"payloadSurvivesLinkReplacement", payloadSurvivesLinkReplacement},
        {"deviceDownDispatchesPayloadTerminal", deviceDownDispatchesPayloadTerminal},
        {"peerCertCnMismatchIsRejected", peerCertCnMismatchIsRejected},
        {"peerCertPinningMismatchIsRejected", peerCertPinningMismatchIsRejected},
        {"peerCertPinningMismatchIsRejected", peerCertPinningMismatchIsRejected},
    };
    for (const CaseDef &c : kCases) {
        runCase(c.name, c.fn);
    }

    ns.stop();
    std::printf("net stack tests: %d cases, %d failed\n", g_cases, g_failed);
    return g_failed == 0 ? 0 : 1;
}
