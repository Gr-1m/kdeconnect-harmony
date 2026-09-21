// SPDX-License-Identifier: GPL-2.0-or-later
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
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <functional>
#include <string>
#include <thread>
#include <vector>

#include "../json/cJSON.h"
#include "../net/cert_gen.h"
#include "../net/cert_util.h"
#include "../net/tcp_connection.h"
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

    // 兴趣位变更（payload EPOLLOUT 按需挂/摘）：与生产实现同语义（EPOLLET 恒定附加）
    bool epollMod(int fd, uint32_t events) override
    {
        epoll_event ev {};
        ev.events = events | EPOLLET;
        ev.data.fd = fd;
        return epoll_ctl(epfd_, EPOLL_CTL_MOD, fd, &ev) == 0;
    }

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

// —————— 4. 控制连接的对端证书捕获（TLS server 角色）——————
//
// 回归点：本机主动发起的连接（手动连接主路径）是 TLS **server** 角色，server 侧必须请求对端证书，
// 否则 peerCommonName()/peerLeafCertDer() 为空 → 配对弹窗无验证码、TrustStore 存不到证书（钉扎失效）、
// payload 发送方向只能降级。修前 host 集成工具与真 KDE 配对时验证码为空串（实测）。
// 本用例走真实产品路径 TcpConnection::startTlsHandshake（isIncoming=false → TlsRole::Server），
// 因此回退该修复会红。
void tlsServerCapturesPeerCert()
{
    int sv[2];
    CHECK(::socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);

    CertPair serverCert = CertGen::generateSelfSignedEc(kIdA, 10);   // CN = kIdA
    CertPair clientCert = CertGen::generateSelfSignedEc(kIdB, 10);   // CN = kIdB

    // server 侧：控制连接的出向连接（isIncoming=false）
    TcpConnection server(sv[0], false);
    CHECK(server.startTlsHandshake(serverCert.certPem, serverCert.keyPem));

    // client 侧：裸 TlsEngine 扮演对端（KDE/Qt 客户端同样会出示证书）
    TlsEngine client(sv[1], TlsRole::Client);
    CHECK(client.init(clientCert.certPem, clientCert.keyPem, nullptr));

    std::atomic<bool> serverDone{false};
    std::atomic<bool> clientDone{false};
    std::thread ts([&] {
        for (int i = 0; i < 400 && !serverDone.load(); ++i) {
            if (server.doTlsHandshake()) {
                serverDone.store(true);
            } else {
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
        }
    });
    std::thread tc([&] {
        for (int i = 0; i < 400 && !clientDone.load(); ++i) {
            if (client.doHandshake()) {
                clientDone.store(true);
            } else {
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
        }
    });
    ts.join();
    tc.join();
    ::close(sv[0]);
    ::close(sv[1]);

    CHECK_MSG(serverDone.load(), "server 侧握手未完成");
    CHECK_MSG(clientDone.load(), "client 侧握手未完成");

    TlsEngine *srvTls = server.tlsEngine();
    CHECK(srvTls != nullptr);
    if (srvTls != nullptr) {
        // server 角色拿到对端（client）证书 CN 与叶证书 DER
        CHECK_MSG(srvTls->peerCommonName() == kIdB, "server 未捕获对端 CN：'%s'（期望 %s）",
                  srvTls->peerCommonName().c_str(), kIdB);
        CHECK_MSG(!srvTls->peerLeafCertDer().empty(), "server 未捕获对端叶证书 DER");
    }
    // client 角色（对端发起连接时）同样要拿到 server 的 CN
    CHECK_MSG(client.peerCommonName() == kIdA, "client 未捕获对端 CN：'%s'（期望 %s）",
              client.peerCommonName().c_str(), kIdA);
}

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

// —————— 5. spool 孤儿清理（评审 F4）——————
//
// 进程重启后，上次运行遗留的 payload_*.bin 永远不会被 settle() 消费 ⇒ 启动时清理。
// 必须只删本模块命名模式，不能误删同目录其他文件。
void spoolPurgesStaleOrphans()
{
    const std::string dir = makeTempDir("payload_spool");
    CHECK(!dir.empty());
    auto touch = [&](const std::string &name) {
        FILE *f = ::fopen((dir + "/" + name).c_str(), "wb");
        CHECK(f != nullptr);
        if (f != nullptr) {
            ::fwrite("x", 1, 1, f);
            ::fclose(f);
        }
    };
    touch("payload_42.bin");     // 孤儿（应被清）
    touch("payload_7.bin");      // 孤儿（应被清）
    touch("keepme.txt");         // 无关文件（应保留）
    touch("payload_note.log");   // 名字前缀像但不是 .bin（应保留）

    FakeHost host(kIdA, dir);    // ctor 内构造 PayloadManager → 触发清理
    (void) host;

    struct stat st {};
    CHECK_MSG(::stat((dir + "/payload_42.bin").c_str(), &st) != 0, "孤儿 payload_42.bin 未被清理");
    CHECK_MSG(::stat((dir + "/payload_7.bin").c_str(), &st) != 0, "孤儿 payload_7.bin 未被清理");
    CHECK_MSG(::stat((dir + "/keepme.txt").c_str(), &st) == 0, "无关文件 keepme.txt 被误删");
    CHECK_MSG(::stat((dir + "/payload_note.log").c_str(), &st) == 0,
              "非 .bin 文件 payload_note.log 被误删");
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

    // —— P2 泄漏修复回归（CodeArts MSG26 §1）：发送任务终态后应被回收，接收任务须留到 settle ——
    // 背景：jobs_ 的 erase 原本只在 settle() 内（它拒绝 send 任务、cancel 对 finished 亦提前返回）
    // ⇒ 每发一个文件永久泄漏一个 PayloadJob（连带 TlsEngine）。现在 onTick 延迟清扫 send 任务。
    // 用"未来时间戳"调用 onTick 触发清扫（无需真睡 PAYLOAD_JOB_REAP_MS）。
    {
        const size_t senderBefore = a.manager().jobCount();
        const size_t recvBefore = b.manager().jobCount();
        const int64_t future = monoMs() + PAYLOAD_JOB_REAP_MS + 1000;
        a.manager().onTick(future);
        b.manager().onTick(future);
        CHECK_MSG(a.manager().jobCount() < senderBefore,
                  "发送侧已终态的任务未被回收（jobs_ 泄漏回归）：before=%zu after=%zu",
                  senderBefore, a.manager().jobCount());
        CHECK_MSG(b.manager().jobCount() == recvBefore,
                  "接收侧任务**不得**被清扫（必须留到 settle 取走落盘结果）：before=%zu after=%zu",
                  recvBefore, b.manager().jobCount());
    }

    const std::string dest = destDir + "/received.bin";
    CHECK(b.manager().settle(id, dest, true));
    CHECK_MSG(readFileEquals(dest, src), "落盘内容与源文件不一致");
    // 注（P2-B）：24h 兜底回收只对"**从未 settle**"的接收任务生效；成功 settle 本身即 erase 任务
    // （settle 内的 jobs_.erase）⇒ 要覆盖该分支需另传一次文件（成本高、价值低），故此处不设断言，
    // 行为由 payload.cpp 的注释与提交说明记录。
}

// —————— 1b. 跨文件系统保存（spool 与目标不同挂载点）——————
//
// 回归点：设备的 spool 在 cacheDir，目标常在不同挂载点 ⇒ `rename()` 返回 EXDEV，
// 旧实现直接 return false（App 只看到「保存失败」且无诊断）。用例把目标放到另一个
// 挂载点（/dev/shm 与 /tmp 是两个独立 tmpfs），强制走「拷贝 + 删源」兜底。
void payloadSettleCrossFilesystem()
{
    if (!std::ifstream("/dev/shm").good()) {
        std::printf("  [skip] 无 /dev/shm，无法构造跨挂载点场景\n");
        return;
    }
    const std::string sendDir = makeTempDir("payload_x_send");   // /tmp（tmpfs）
    const std::string recvDir = makeTempDir("payload_x_recv");   // spool 在 /tmp
    char destDirTmpl[] = "/dev/shm/kdc_xdst_XXXXXX";
    char *destDirRaw = ::mkdtemp(destDirTmpl);
    CHECK_MSG(destDirRaw != nullptr, "mkdtemp(/dev/shm) 失败");
    if (destDirRaw == nullptr) {
        return;
    }
    const std::string destDir = destDirRaw;

    const std::string src = writeSourceFile(sendDir, 256 * 1024);
    CHECK(!src.empty());

    FakeHost a(kIdA, sendDir);
    FakeHost b(kIdB, recvDir);
    a.setPeerCertPem(kIdB, b.ownCertPem());
    b.setPeerCertPem(kIdA, a.ownCertPem());
    a.onFrame_ = [&](const std::string &deviceId, const std::string &frame) {
        (void) deviceId;
        pullOnFrame(b, kIdA, frame);
    };
    a.start();
    b.start();

    const uint64_t id = a.manager().startSend(kIdB, "kdeconnect.share.request",
                                             "{\"filename\":\"x.bin\"}", src);
    CHECK(id != 0);
    const bool recvOk = b.waitState("finished", false, 15000);
    CHECK_MSG(recvOk, "接收侧未 finished");
    if (!recvOk) {
        dumpEvents("receiver", b);
        return;
    }

    const std::string dest = destDir + "/received.bin";
    CHECK_MSG(b.manager().settle(id, dest, true), "跨文件系统保存失败（应为拷贝兜底）");
    CHECK_MSG(readFileEquals(dest, src), "跨文件系统落盘内容与源不一致");
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

// 探针（DevEco MSG38：连续 payload 成功/失败严格交替，code=110）：
// 复现 ArkTS 串行队列的语义 —— 「上一次终态 → 立刻发起下一个」，连发 4 次，
// 逐次记录终态与两侧在册任务数。用于验证「端口复用/槽位未释放」假设是否在宿主侧可复现。
void payloadConsecutiveSends()
{
    const std::string sendDir = makeTempDir("cons_send");
    const std::string recvDir = makeTempDir("cons_recv");
    CHECK(!sendDir.empty() && !recvDir.empty());
    const std::string src = writeSourceFile(sendDir, 256 * 1024);
    CHECK(!src.empty());

    FakeHost a(kIdA, sendDir);
    FakeHost b(kIdB, recvDir);
    a.setPeerCertPem(kIdB, b.ownCertPem());
    b.setPeerCertPem(kIdA, a.ownCertPem());
    a.onFrame_ = [&](const std::string &deviceId, const std::string &frame) {
        (void) deviceId;
        pullOnFrame(b, kIdA, frame);
    };
    a.start();
    b.start();

    int nFinished = 0;
    int nFailed = 0;
    for (int i = 0; i < 4; ++i) {
        const uint64_t id = a.manager().startSend(kIdB, "kdeconnect.share.request",
                                                 "{\"filename\":\"cons.bin\"}", src);
        CHECK_MSG(id != 0, "第 %d 次 startSend 返回 0", i);
        const bool ok = a.waitState("finished", true, 8000);
        bool thisFailed = false;
        for (const NetEvent &e : a.snapshot()) {
            if (e.type == EventType::PayloadTransfer && e.payloadDirectionSend &&
                e.payloadTransferId == id && e.payloadState == "failed") {
                thisFailed = true;
                std::fprintf(stderr, "       code=%d msg=%s\n", e.errorCode,
                             e.errorMessage.c_str());
            }
        }
        if (ok) {
            ++nFinished;
        } else if (thisFailed) {
            ++nFailed;
        }
        std::fprintf(stderr, "  [cons] #%d id=%llu -> %s (jobs a=%zu b=%zu)\n", i,
                     (unsigned long long) id,
                     ok ? "finished" : (thisFailed ? "failed" : "未知(超时)"),
                     a.manager().jobCount(), b.manager().jobCount());
    }
    std::fprintf(stderr, "  [cons] 汇总: finished=%d/4 failed=%d\n", nFinished, nFailed);
    CHECK_MSG(nFinished == 4, "连续 payload 未全部成功（finished=%d failed=%d）", nFinished,
              nFailed);
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
    runCase("payloadSettleCrossFilesystem", payloadSettleCrossFilesystem);
    runCase("payloadPeerCertMismatch", payloadPeerCertMismatch);
    runCase("payloadLockOrder", payloadLockOrder);
    runCase("tlsServerCapturesPeerCert", tlsServerCapturesPeerCert);
    runCase("spoolPurgesStaleOrphans", spoolPurgesStaleOrphans);
    runCase("payloadConsecutiveSends", payloadConsecutiveSends);
    std::printf("payload integration tests (host): %d cases, %d failed\n", g_cases, g_failed);
    return g_failed == 0 ? 0 : 1;
}
