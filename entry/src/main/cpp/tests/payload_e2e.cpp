// WP-4 native 集成测试（host）：payload 通道端到端 + P0 回归。
//
// 覆盖（MSG57_TO_ZCODE P0-1/P0-2/P0-3）：
//   1. payloadE2eSendReceive —— 真实 PayloadManager + TlsEngine 双端（send = TLS server，
//      receive = TLS client）走完「控制帧 → TCP → 双向证书握手 → 证书 CN 校验 → 传输 → 落盘」。
//      回归点：P0-1（accept 后新 fd 未注册 epoll → 握手永不推进 → 30s 超时）；
//              P0-2（server 端未请求/未校验客户端证书 → EACCES "peer cert mismatch"）。
//   2. payloadPeerCertMismatch —— 对端证书 CN ≠ 期望 deviceId 必须被拒（EACCES），
//      且必须在握手后立即失败（不是 30s 超时）。
//   3. payloadLockOrder —— P0-3 ABBA：JS 线程 startSend 与网络线程（持 connMutex_）
//      startReceive 并发时不得互锁（死锁由看门狗超时判定）。
//
// 构建/运行：tests/run.sh（g++ + vendored BearSSL；不依赖 SDK/cJSON 之外的任何东西）。

#include <arpa/inet.h>
#include <fcntl.h>
#include <sys/epoll.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <thread>
#include <vector>

#include "../json/cJSON.h"
#include "../net/cert_gen.h"
#include "../net/cert_util.h"
#include "../payload/payload.h"

using namespace kdeconnect;

namespace {

int g_failed = 0;
int g_cases = 0;
const char *g_case = "?";

// 用例不使用「静态对象构造即运行」的写法：这些用例会起线程/跑 TLS，
// 在静态初始化期执行既不可控（跨 TU 初始化顺序）也无意义。
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

int64_t monoMs()
{
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

const char *kIdA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";  // 32 字符，符合 deviceId 正则
const char *kIdB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

// —————— 假宿主：模拟 NetStack 提供给 payload 模块的能力 ——————
//
// connMutex 对应 NetStack::connMutex_（在 sendControlFrame/peerCertPem 内取用），
// epoll 循环对应 NetStack::eventLoop 的 payload 分支 + onTick 定时器。
class FakeHost : public PayloadHost {
public:
    FakeHost(std::string id, std::string spoolDir)
        : id_(std::move(id)), cert_(CertGen::generateSelfSignedEc(id_, 10)),
          mgr_(this, spoolDir)
    {
        epfd_ = epoll_create1(EPOLL_CLOEXEC);
    }

    ~FakeHost() override { stop(); }

    PayloadManager &manager() { return mgr_; }
    const std::string &id() const { return id_; }
    const std::string &ownCertPem() const { return cert_.certPem; }
    // 模拟 NetStack 的「已知对端证书」（信任存储 / 连接缓存）：只对登记过的 deviceId 有效
    void setPeerCertPem(std::string peerId, std::string pem)
    {
        peerId_ = std::move(peerId);
        peerPem_ = std::move(pem);
    }

    void start()
    {
        running_.store(true);
        loop_ = std::thread([this] { loopMain(); });
    }

    void stop()
    {
        if (!running_.exchange(false)) {
            return;
        }
        if (loop_.joinable()) {
            loop_.join();
        }
        if (epfd_ >= 0) {
            ::close(epfd_);
            epfd_ = -1;
        }
    }

    // —— PayloadHost ——
    bool epollAdd(int fd, uint32_t events) override
    {
        epoll_event ev {};
        ev.events = events | EPOLLET;
        ev.data.fd = fd;
        return epoll_ctl(epfd_, EPOLL_CTL_ADD, fd, &ev) == 0;
    }

    void epollDel(int fd) override { epoll_ctl(epfd_, EPOLL_CTL_DEL, fd, nullptr); }

    const std::string &certPem() override { return cert_.certPem; }
    const std::string &keyPem() override { return cert_.keyPem; }

    bool sendControlFrame(const std::string &deviceId, const std::string &frame) override
    {
        // 锁序测试用闸门：让 JS 线程停在「已进入 host 回调」处，由网络线程先持有 connMutex_。
        if (gateOnStartReceive_.load()) {
            const int64_t deadline = monoMs() + 3000;
            while (!peerInStartReceive_.load() && monoMs() < deadline) {
                std::this_thread::sleep_for(std::chrono::microseconds(500));
            }
        }
        std::lock_guard<std::mutex> lk(connMutex);  // 模拟 NetStack::sendPacket 取 connMutex_
        if (onFrame_) {
            onFrame_(deviceId, frame);
        }
        return true;
    }

    void postPayloadEvent(NetEvent ev) override
    {
        std::lock_guard<std::mutex> lk(evMu_);
        events.push_back(std::move(ev));
    }

    int64_t nowMs() override { return monoMs(); }

    std::string peerCertPem(const std::string &deviceId) override
    {
        std::lock_guard<std::mutex> lk(connMutex);
        return (!peerPem_.empty() && deviceId == peerId_) ? peerPem_ : std::string();
    }

    // —— 测试钩子 ——
    std::function<void(const std::string &, const std::string &)> onFrame_;
    std::mutex connMutex;
    std::atomic<bool> gateOnStartReceive_{false};
    std::atomic<bool> peerInStartReceive_{false};

    std::vector<NetEvent> snapshot()
    {
        std::lock_guard<std::mutex> lk(evMu_);
        return events;
    }

    // 等待某个 payload 状态出现（轮询事件表）
    bool waitState(const char *state, bool sendDir, int timeoutMs)
    {
        const int64_t deadline = monoMs() + timeoutMs;
        while (monoMs() < deadline) {
            {
                std::lock_guard<std::mutex> lk(evMu_);
                for (const NetEvent &e : events) {
                    if (e.type == EventType::PayloadTransfer && e.payloadState == state &&
                        e.payloadDirectionSend == sendDir) {
                        return true;
                    }
                }
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        return false;
    }

private:
    void loopMain()
    {
        epoll_event evs[32];
        while (running_.load()) {
            int n = epoll_wait(epfd_, evs, 32, 50);
            for (int i = 0; i < n; ++i) {
                const int fd = evs[i].data.fd;
                if (evs[i].events & (EPOLLIN | EPOLLERR | EPOLLHUP)) {
                    mgr_.onReadable(fd);
                }
                if (evs[i].events & EPOLLOUT) {
                    mgr_.onWritable(fd);
                }
            }
            mgr_.onTick(nowMs());
        }
    }

    std::string id_;
    CertPair cert_;
    PayloadManager mgr_;
    int epfd_ = -1;
    std::atomic<bool> running_{false};
    std::thread loop_;
    std::mutex evMu_;
    std::vector<NetEvent> events;
    std::string peerPem_;
    std::string peerId_;
};

void dumpEvents(const char *tag, FakeHost &h)
{
    const std::vector<NetEvent> ev = h.snapshot();
    std::fprintf(stderr, "--- %s events (%zu) ---\n", tag, ev.size());
    for (const NetEvent &e : ev) {
        if (e.type != EventType::PayloadTransfer) {
            std::fprintf(stderr, "  type=%d device=%s err=%d msg=%s\n", (int) e.type,
                         e.deviceId.c_str(), e.errorCode, e.errorMessage.c_str());
            continue;
        }
        std::fprintf(stderr, "  payload id=%llu dir=%s state=%s done=%lld/%lld err=%d msg=%s\n",
                     (unsigned long long) e.payloadTransferId,
                     e.payloadDirectionSend ? "send" : "recv", e.payloadState.c_str(),
                     (long long) e.payloadBytesDone, (long long) e.payloadSize, e.errorCode,
                     e.errorMessage.c_str());
    }
    std::fflush(stderr);
}

std::string makeTempDir(const char *tag)
{
    char tmpl[128];
    std::snprintf(tmpl, sizeof tmpl, "/tmp/kdc_%s_XXXXXX", tag);
    char *d = ::mkdtemp(tmpl);
    return d != nullptr ? std::string(d) : std::string();
}

std::string writeSourceFile(const std::string &dir, size_t bytes)
{
    const std::string path = dir + "/source.bin";
    FILE *f = ::fopen(path.c_str(), "wb");
    if (f == nullptr) {
        return {};
    }
    std::string data;
    data.reserve(bytes);
    uint32_t x = 123456789u;  // 确定性 LCG：内容可复现，便于 sha 对比
    for (size_t i = 0; i < bytes; ++i) {
        x = x * 1103515245u + 12345u;
        data.push_back(static_cast<char>((x >> 16) & 0xFF));
    }
    std::fwrite(data.data(), 1, data.size(), f);
    std::fclose(f);
    return path;
}

bool readFileEquals(const std::string &path, const std::string &refPath)
{
    auto slurp = [](const std::string &p, std::string &out) {
        FILE *f = ::fopen(p.c_str(), "rb");
        if (f == nullptr) {
            return false;
        }
        char buf[65536];
        size_t n;
        while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) {
            out.append(buf, n);
        }
        ::fclose(f);
        return true;
    };
    std::string a, b;
    return slurp(path, a) && slurp(refPath, b) && a == b;
}

// 收到控制帧后由接收侧解析并拉取（对应 ArkTS PacketRouter 的自动拉取 + NetStack 信任门禁后的 startReceive）
void pullOnFrame(FakeHost &receiver, const std::string &senderId,
                 const std::string &frame)
{
    cJSON *root = cJSON_Parse(frame.c_str());
    if (root == nullptr) {
        return;
    }
    cJSON *size = cJSON_GetObjectItemCaseSensitive(root, "payloadSize");
    cJSON *ti = cJSON_GetObjectItemCaseSensitive(root, "payloadTransferInfo");
    cJSON *port = ti != nullptr ? cJSON_GetObjectItemCaseSensitive(ti, "port") : nullptr;
    cJSON *body = cJSON_GetObjectItemCaseSensitive(root, "body");
    if (cJSON_IsNumber(size) && cJSON_IsNumber(port)) {
        char *bodyJson = body != nullptr ? cJSON_PrintUnformatted(body) : nullptr;
        receiver.manager().startReceive(senderId, "127.0.0.1",
                                        static_cast<uint16_t>(port->valuedouble),
                                        static_cast<int64_t>(size->valuedouble),
                                        bodyJson != nullptr ? bodyJson : "{}");
        if (bodyJson != nullptr) {
            cJSON_free(bodyJson);
        }
    }
    cJSON_Delete(root);
}

// —————— 1. 端到端：发送 → 接收 → 落盘 ——————

void payloadE2eSendReceive()
{
    const std::string sendDir = makeTempDir("payload_send");
    const std::string recvDir = makeTempDir("payload_recv");
    const std::string destDir = makeTempDir("payload_dest");
    CHECK(!sendDir.empty() && !recvDir.empty() && !destDir.empty());

    const std::string src = writeSourceFile(sendDir, 1024 * 1024);
    CHECK(!src.empty());

    FakeHost a(kIdA, sendDir);
    FakeHost b(kIdB, recvDir);
    a.setPeerCertPem(kIdB, b.ownCertPem());   // 控制连接阶段已互相见过证书（WP-2 钉扎/缓存）
    b.setPeerCertPem(kIdA, a.ownCertPem());
    a.onFrame_ = [&](const std::string &deviceId, const std::string &frame) {
        // 收到控制帧的一侧按「控制连接的对端 deviceId」建拉取任务（生产：
        // NetStack 传 conn.deviceId()），即发送方自己的 id；帧里的 deviceId 是收件人。
        (void) deviceId;
        pullOnFrame(b, kIdA, frame);
    };
    a.start();
    b.start();

    const uint64_t id = a.manager().startSend(kIdB, "kdeconnect.share.request",
                                             "{\"filename\":\"source.bin\"}", src);
    CHECK_MSG(id != 0, "startSend 返回 0");

    const bool sendOk = a.waitState("finished", true, 15000);
    const bool recvOk = b.waitState("finished", false, 15000);
    CHECK_MSG(sendOk, "发送侧未在 15s 内 finished（P0-1/P0-2 回归）");
    CHECK_MSG(recvOk, "接收侧未在 15s 内 finished");
    if (!sendOk || !recvOk) {
        dumpEvents("sender", a);
        dumpEvents("receiver", b);
    }

    const std::vector<NetEvent> ev = b.snapshot();
    std::string spoolPath;
    for (const NetEvent &e : ev) {
        if (e.type == EventType::PayloadTransfer && e.payloadState == "finished" &&
            !e.payloadDirectionSend) {
            spoolPath = e.payloadFilePath;
            CHECK_MSG(e.payloadTransferId == id, "payloadTransferId 不一致: %llu vs %llu",
                      (unsigned long long) e.payloadTransferId, (unsigned long long) id);
            CHECK(e.payloadSize == 1024 * 1024);
        }
    }
    CHECK_MSG(!spoolPath.empty(), "finished 事件缺少 payloadFilePath");

    const std::string dest = destDir + "/received.bin";
    CHECK(b.manager().settle(id, dest, true));
    CHECK_MSG(readFileEquals(dest, src), "落盘内容与源文件不一致");
}

// —————— 2. 对端证书 CN 不匹配必须被拒（P0-2 的反面） ——————

void payloadPeerCertMismatch()
{
    const std::string sendDir = makeTempDir("payload_mm_send");
    const std::string recvDir = makeTempDir("payload_mm_recv");
    const std::string src = writeSourceFile(sendDir, 4096);
    CHECK(!src.empty());

    FakeHost a(kIdA, sendDir);
    FakeHost b(kIdB, recvDir);
    a.setPeerCertPem(kIdB, b.ownCertPem());
    b.setPeerCertPem(kIdA, a.ownCertPem());
    a.onFrame_ = [&](const std::string &deviceId, const std::string &frame) {
        // 对端仍然来拉取（模拟「证书不是我们要的那个设备」）
        pullOnFrame(b, deviceId, frame);
    };
    a.start();
    b.start();

    // 期望 deviceId = 一个符合格式但非对端 CN 的 id → A 侧必须 EACCES 拒绝
    const std::string bogus = "cccccccccccccccccccccccccccccccc";
    const int64_t t0 = monoMs();
    const uint64_t id = a.manager().startSend(bogus, "kdeconnect.share.request",
                                             "{\"filename\":\"source.bin\"}", src);
    CHECK(id != 0);
    CHECK_MSG(a.waitState("failed", true, 10000), "CN 不匹配未产生 failed 事件");

    int code = 0;
    {
        const std::vector<NetEvent> ev = a.snapshot();
        for (const NetEvent &e : ev) {
            if (e.type == EventType::PayloadTransfer && e.payloadState == "failed" &&
                e.payloadDirectionSend) {
                code = e.errorCode;
            }
        }
    }
    CHECK_MSG(code == EACCES, "期望 EACCES，实际 %d（%s）", code,
              code == ETIMEDOUT ? "30s 超时 = 握手根本没推进" : "其他错误");
    CHECK_MSG(monoMs() - t0 < 9000, "拒绝耗时 %lld ms（疑似走了 30s 超时路径）",
              (long long) (monoMs() - t0));
}

// —————— 3. P0-3：锁序（JS 线程 ↔ 网络线程）不得 ABBA ——————

void payloadLockOrder()
{
    const std::string dir = makeTempDir("payload_lock");
    const std::string src = writeSourceFile(dir, 4096);
    CHECK(!src.empty());

    FakeHost a(kIdA, dir);
    a.setPeerCertPem(kIdB, a.ownCertPem());
    a.gateOnStartReceive_.store(true);
    a.start();

    std::atomic<bool> jsDone{false};
    std::thread js([&] {
        // 修复前：本线程会先持 PayloadManager::mu_ 再进 sendControlFrame（取 connMutex_）
        a.manager().startSend(kIdB, "kdeconnect.share.request", "{\"filename\":\"s.bin\"}", src);
        jsDone.store(true);
    });

    std::this_thread::sleep_for(std::chrono::milliseconds(150));

    std::atomic<bool> netDone{false};
    std::thread net([&] {
        // 网络线程：持 connMutex_ 调 payload_->startReceive（内部取 mu_）→ 生产代码同序
        std::lock_guard<std::mutex> lk(a.connMutex);
        a.peerInStartReceive_.store(true);
        a.manager().startReceive(kIdA, "127.0.0.1", 65000, -1, "{}");
        netDone.store(true);
    });

    const int64_t deadline = monoMs() + 5000;
    while (monoMs() < deadline && !(jsDone.load() && netDone.load())) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    const bool ok = jsDone.load() && netDone.load();
    CHECK_MSG(ok, "ABBA 死锁：js=%d net=%d（P0-3 回归）", jsDone.load() ? 1 : 0,
              netDone.load() ? 1 : 0);
    if (!ok) {
        // 互锁的两线程无法 join；直接退出，避免测试进程挂死
        std::fflush(stderr);
        std::_Exit(1);
    }
    js.join();
    net.join();
    a.stop();
}

void runCase(const char *name, void (*fn)())
{
    g_case = name;
    ++g_cases;
    const int before = g_failed;
    fn();
    std::printf("%-28s %s\n", name, g_failed == before ? "OK" : "FAILED");
    std::fflush(stdout);
}

} // namespace

int main()
{
    runCase("payloadE2eSendReceive", payloadE2eSendReceive);
    runCase("payloadPeerCertMismatch", payloadPeerCertMismatch);
    runCase("payloadLockOrder", payloadLockOrder);
    std::printf("payload integration tests (host): %d cases, %d failed\n", g_cases, g_failed);
    return g_failed == 0 ? 0 : 1;
}
