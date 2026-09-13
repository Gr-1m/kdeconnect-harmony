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
#include <sys/socket.h>
#include <unistd.h>

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

using namespace kdeconnect;

namespace {

int g_failed = 0;
int g_cases = 0;
const char *g_case = "?";

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
    const int64_t deadline = nowMs() + 12000;
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

// 子进程入口：起一个对端栈并拨入父进程
int runPeerMode(uint16_t targetPort)
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
    cfg.spoolDir = "/tmp/kdc_nettest_spool";

    NetStack &ns = netStack();
    // 对端侧只保留一行摘要（CI 失败时可据此判断是对端没发、还是被测栈没收）
    ns.setEventCallback([](const NetEvent &e) {
        if (e.type == EventType::PacketReceived || e.type == EventType::Connected) {
            std::fprintf(stderr, "[peer] type=%d device=%s role=%s\n", (int) e.type,
                         e.deviceId.c_str(), e.role == TlsRole::Server ? "server" : "client");
        }
    });
    if (!ns.start(cfg)) {
        return 1;
    }
    ns.connectToPeer("127.0.0.1", targetPort);
    std::this_thread::sleep_for(std::chrono::milliseconds(8000));
    ns.stop();
    return 0;
}

} // namespace

int main(int argc, char **argv)
{
    if (argc >= 3 && std::strcmp(argv[1], "--peer") == 0) {
        return runPeerMode(static_cast<uint16_t>(std::atoi(argv[2])));
    }
    CertPair cert = CertGen::generateSelfSignedEc("hosttest11111111111111111111111111", 10);
    NetConfig cfg;
    cfg.deviceId = "hosttest11111111111111111111111111";
    cfg.deviceName = "kdc-nettest";
    cfg.deviceType = "phone";
    cfg.certPem = cert.certPem;
    cfg.keyPem = cert.keyPem;
    cfg.tcpPort = 1745;                      // 避开 1716（可能与在跑的桌面 daemon 冲突）
    cfg.spoolDir = "/tmp/kdc_nettest_spool";
    cfg.connectHandshakeTimeoutMs = 1500;    // 短上限，保证 CI 快

    NetStack &ns = netStack();
    ns.setEventCallback(onEvent);
    if (!ns.start(cfg)) {
        std::printf("net stack 启动失败（环境不支持），跳过 net 测试\n");
        return 0;
    }

    runCase("connectToClosedPortReportsReason", connectToClosedPortReportsReason);
    runCase("muteePeerTimesOutBounded", muteePeerTimesOutBounded);
    runCase("peerIdentityIsDispatchedAsPacket", peerIdentityIsDispatchedAsPacket);

    ns.stop();
    std::printf("net stack tests: %d cases, %d failed\n", g_cases, g_failed);
    return g_failed == 0 ? 0 : 1;
}
