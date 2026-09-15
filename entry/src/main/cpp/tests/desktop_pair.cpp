// 手动运行的 host 集成工具（不进 CI）：用**真实 native 全栈**（NetStack + TLS + payload）
// 直连桌面 KDE，验证「手动连接 → identity → 配对 → 验证码 → 发文件」整条 native 链路。
//
// 为什么需要它：Win10 模拟器在 QEMU NAT 后（见 MSG59_TO_OMP），App 侧观测成本高；
// 而 native 栈本身不依赖 NAPI（事件出口是 std::function），可在宿主机直接跑，
// 于是「native 到底能不能和真桌面完成配对/传文件」可以在这台机器上证完，再谈 App 侧。
//
// 用法：
//   ./run_desktop.sh pair                    # 连 <host>:1716 并发起配对（桌面端需接受）
//   ./run_desktop.sh pair <host> <port>      # 指定对端
//   ./run_desktop.sh sendfile <path>         # 配对后发文件（桌面端会收到 share.request）
//   ./run_desktop.sh probe [host]            # 端口未知（0）拨号：native 自行探测并建链
//                                            # （KDE 拨入的 identity 不带 tcpPort，见 net_util.h）
//
// 退出码：0 = 成功（收到对端 {pair:true} / 传输 finished），1 = 失败/超时。

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "../json/cJSON.h"
#include "../net/cert_gen.h"
#include "../net/net_stack.h"
#include "../net/packet_io.h"

using namespace kdeconnect;

namespace {

std::mutex g_mu;
std::condition_variable g_cv;
std::string g_peerId;              // 对端（桌面）deviceId
bool g_connected = false;
bool g_pairAccepted = false;       // 收到对端 {pair:true}
bool g_pairRejected = false;       // 收到对端 {pair:false}
std::string g_verificationCode;    // 本机算出的验证码（与对端通知里的 Key 比对）
// 接受配对时对端的 deviceId/timestamp：**必须**留到主线程再算验证码 ——
// 事件回调运行在网络栈的事件循环线程上，在回调里调 netStack() 的任何方法都会与
// dispatchEvent 持有的锁自锁（实测：收到接受后进程永久卡住，reject 路径不调所以正常）。
std::string g_pairPeerId;
int64_t g_pairTimestamp = -1;
int64_t g_sentPairTs = -1;   // 我方发出的请求时间戳（v8 验证码用它；接受包不带 ts）
uint64_t g_xferId = 0;
std::string g_xferState;

int64_t nowMs()
{
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

void note(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char buf[1024];
    std::vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    std::printf("%s\n", buf);
    std::fflush(stdout);
}

std::string frameTypeOf(const std::string &frame)
{
    cJSON *root = cJSON_Parse(frame.c_str());
    if (root == nullptr) {
        return {};
    }
    cJSON *type = cJSON_GetObjectItemCaseSensitive(root, "type");
    std::string out = cJSON_IsString(type) ? type->valuestring : "";
    cJSON_Delete(root);
    return out;
}

// 从 kdeconnect.pair 帧里取 body.pair / body.timestamp
bool pairBodyOf(const std::string &frame, bool &pair, int64_t &ts)
{
    cJSON *root = cJSON_Parse(frame.c_str());
    if (root == nullptr) {
        return false;
    }
    cJSON *body = cJSON_GetObjectItemCaseSensitive(root, "body");
    cJSON *p = body != nullptr ? cJSON_GetObjectItemCaseSensitive(body, "pair") : nullptr;
    cJSON *t = body != nullptr ? cJSON_GetObjectItemCaseSensitive(body, "timestamp") : nullptr;
    bool ok = cJSON_IsBool(p);
    if (ok) {
        pair = cJSON_IsTrue(p);
        ts = cJSON_IsNumber(t) ? static_cast<int64_t>(t->valuedouble) : -1;
    }
    cJSON_Delete(root);
    return ok;
}

void onEvent(const NetEvent &e)
{
    switch (e.type) {
    case EventType::DeviceDiscovered:
        note("[event] deviceDiscovered  %s (%s) @ %s:%u",
             e.deviceId.c_str(), e.deviceName.c_str(), e.host.c_str(), e.tcpPort);
        break;
    case EventType::DeviceLost:
        note("[event] deviceLost        %s", e.deviceId.c_str());
        break;
    case EventType::PairingRequest:
        // TLS 握手层的 identity 帧（不是配对请求）
        note("[event] peer identity     %s (%s) type=%s", e.deviceId.c_str(),
             e.deviceName.c_str(), e.deviceType.c_str());
        {
            std::lock_guard<std::mutex> lk(g_mu);
            if (g_peerId.empty()) {
                g_peerId = e.deviceId;
            }
        }
        g_cv.notify_all();
        break;
    case EventType::Connected:
        note("[event] connected         %s name=%s role=%s", e.deviceId.c_str(),
             e.deviceName.c_str(), e.role == TlsRole::Server ? "server" : "client");
        {
            std::lock_guard<std::mutex> lk(g_mu);
            g_peerId = e.deviceId;
            g_connected = true;
        }
        g_cv.notify_all();
        break;
    case EventType::Disconnected:
        note("[event] disconnected      %s", e.deviceId.c_str());
        break;
    case EventType::PacketReceived:
        note("[event] packet            %s : %s", e.deviceId.c_str(),
             e.packet.substr(0, 160).c_str());
        if (frameTypeOf(e.packet) == "kdeconnect.pair") {
            bool pair = false;
            int64_t ts = -1;
            if (pairBodyOf(e.packet, pair, ts)) {
                std::lock_guard<std::mutex> lk(g_mu);
                if (pair) {
                    g_pairAccepted = true;
                    g_pairPeerId = e.deviceId;
                    g_pairTimestamp = ts;
                    note("[pair] 对端接受配对（timestamp=%lld）", static_cast<long long>(ts));
                } else {
                    g_pairRejected = true;
                    note("[pair] 对端拒绝/解除配对（pair:false）");
                }
            }
            g_cv.notify_all();
        }
        break;
    case EventType::PayloadTransfer:
        note("[payload] id=%llu dir=%s state=%s done=%lld/%lld err=%d %s",
             (unsigned long long) e.payloadTransferId, e.payloadDirectionSend ? "send" : "recv",
             e.payloadState.c_str(), (long long) e.payloadBytesDone, (long long) e.payloadSize,
             e.errorCode, e.errorMessage.c_str());
        {
            std::lock_guard<std::mutex> lk(g_mu);
            g_xferId = e.payloadTransferId;
            g_xferState = e.payloadState;
        }
        g_cv.notify_all();
        break;
    case EventType::Error:
        note("[event] error             %s code=%d msg=%s", e.deviceId.c_str(),
             e.errorCode, e.errorMessage.c_str());
        break;
    }
}

bool waitFor(const std::function<bool()> &pred, int timeoutMs, const char *what)
{
    const int64_t deadline = nowMs() + timeoutMs;
    std::unique_lock<std::mutex> lk(g_mu);
    while (!pred()) {
        if (g_cv.wait_for(lk, std::chrono::milliseconds(200)) == std::cv_status::timeout &&
            nowMs() > deadline) {
            note("[!] 等待超时: %s (%d ms)", what, timeoutMs);
            return false;
        }
        if (nowMs() > deadline) {
            note("[!] 等待超时: %s (%d ms)", what, timeoutMs);
            return false;
        }
    }
    return true;
}

std::string peerIdSnapshot()
{
    std::lock_guard<std::mutex> lk(g_mu);
    return g_peerId;
}

} // namespace

// 本工具的证书持久化在 /tmp：桌面端一旦信任该 deviceId，就会用缓存的证书做 VerifyPeer；
// 每次重新生成证书会导致「已信任设备换证书」→ 桌面端拒连。故跨运行复用同一份。
static CertPair loadOrCreateCert(const std::string &deviceId)
{
    const char *certPath = "/tmp/kdc_hosttest.crt";
    const char *keyPath = "/tmp/kdc_hosttest.key";
    auto slurp = [](const char *p, std::string &out) {
        FILE *f = ::fopen(p, "rb");
        if (f == nullptr) {
            return false;
        }
        char buf[4096];
        size_t n;
        while ((n = ::fread(buf, 1, sizeof buf, f)) > 0) {
            out.append(buf, n);
        }
        ::fclose(f);
        return true;
    };
    CertPair pair;
    if (slurp(certPath, pair.certPem) && slurp(keyPath, pair.keyPem) && !pair.certPem.empty() &&
        !pair.keyPem.empty()) {
        return pair;
    }
    pair = CertGen::generateSelfSignedEc(deviceId, 10);
    FILE *f = ::fopen(certPath, "wb");
    if (f != nullptr) {
        ::fwrite(pair.certPem.data(), 1, pair.certPem.size(), f);
        ::fclose(f);
    }
    f = ::fopen(keyPath, "wb");
    if (f != nullptr) {
        ::fwrite(pair.keyPem.data(), 1, pair.keyPem.size(), f);
        ::fclose(f);
    }
    return pair;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        note("用法: %s pair [host] [port] | sendfile <path> [host] [port]", argv[0]);
        return 2;
    }
    const std::string mode = argv[1];
    std::string host = "<host>";
    uint16_t port = 1716;
    std::string filePath;
    int serveSeconds = 60;
    if (mode == "sendfile") {
        if (argc < 3) {
            note("sendfile 需要文件路径");
            return 2;
        }
        filePath = argv[2];
        if (argc > 3) {
            host = argv[3];
        }
        if (argc > 4) {
            port = static_cast<uint16_t>(std::atoi(argv[4]));
        }
    } else if (mode == "serve") {
        if (argc > 2) {
            serveSeconds = std::atoi(argv[2]);
        }
        if (argc > 3) {
            host = argv[3];
        }
        if (argc > 4) {
            port = static_cast<uint16_t>(std::atoi(argv[4]));
        }
    } else {
        if (argc > 2) {
            host = argv[2];
        }
        if (argc > 3) {
            port = static_cast<uint16_t>(std::atoi(argv[3]));
        }
    }

    // 固定测试 deviceId（符合 ^[a-zA-Z0-9_-]{32,38}$），便于桌面端定位该设备对象
    const std::string deviceId = "hosttest00000000000000000000000000";
    const CertPair cert = loadOrCreateCert(deviceId);

    NetConfig cfg;
    cfg.deviceId = deviceId;
    cfg.deviceName = "kdc-hosttest";
    cfg.deviceType = "phone";
    cfg.certPem = cert.certPem;
    cfg.keyPem = cert.keyPem;
    cfg.spoolDir = "/tmp/kdc_spool";   // 设备默认 spool 在 /data/storage/... 沙箱路径，host 上需注入
    cfg.tcpPort = 1735;   // 固定非 1716：本机同时跑着桌面 kdeconnectd（占 1716），
                          // 若本工具也广播 1716，局域网里其他设备会拨到错误的 daemon（实测混淆）

    NetStack &ns = netStack();
    ns.setEventCallback(onEvent);
    // 能力声明：对端据此决定是否把 packet 交插件处理。
    // 发文件要求 outgoing 里含 kdeconnect.share.request（KDE 侧
    // Device::privateReceivedPacket 按「对端 outgoingCaps」查插件映射；缺了会
    // 记 "discarding unsupported packet"，不会来拉 payload → 30s 超时）。
    // **与 App 同顺序：先 setCapabilities 再 start**（ArkTS 就是这么调的；也正因为如此，
    // MSG116 §3.1 的「广播 identity caps 为空」才长期存在）。native 现已把 caps 装进
    // 首次广播（MSG117 §3 修复），本工具正好把该路径走一遍。
    ns.setCapabilities({"kdeconnect.ping", "kdeconnect.identity", "kdeconnect.pair",
                        "kdeconnect.share.request", "kdeconnect.clipboard"},
                       {"kdeconnect.ping", "kdeconnect.share.request", "kdeconnect.clipboard"});
    if (!ns.start(cfg)) {
        note("[!] net stack start failed");
        return 1;
    }
    // MSG117 §3 第二条路径：start 之后 caps 变更必须**立即**重播一次（原实现要等周期广播，
    // 已建链时干脆不播）。这里再调一次，用于观察 UDP 上是否出现带 caps 的广播。
    ns.setCapabilities({"kdeconnect.ping", "kdeconnect.identity", "kdeconnect.pair",
                        "kdeconnect.share.request", "kdeconnect.clipboard"},
                       {"kdeconnect.ping", "kdeconnect.share.request", "kdeconnect.clipboard"});
    note("[*] 本机 deviceId=%s，连接 %s:%u ...", deviceId.c_str(), host.c_str(),
         mode == "probe" ? 0 : port);
    // probe：故意传 0，验证「端口未知 ⇒ native 自行探测（KDE 端口区间）⇒ 建链」这条路径
    if (!ns.connectToPeer(host, mode == "probe" ? 0 : port)) {
        note("[!] connectToPeer failed");
        ns.stop();
        return 1;
    }

    const bool connected = waitFor([] { return g_connected; }, 20000, "connected 事件");
    if (!connected) {
        note("[!] 未建立加密链路（identity/TLS 阶段失败）");
        ns.stop();
        return 1;
    }
    const std::string peer = peerIdSnapshot();
    note("[*] 对端 deviceId=%s", peer.c_str());

    // 模拟 App 侧「配对后把对端证书写入 TrustStore」（Index.ets handlePaired → AP-3）。
    // 若不登记：接收方向会被 P1-3 信任门禁拒绝（payload rejected: device not paired/trusted）。
    // 这里顺带验证 getPeerCertificate（对端证书捕获）在两种链路角色下都可用。
    if (mode != "pair") {
        const std::string peerPem = ns.getPeerCertificate(peer);
        note("[*] getPeerCertificate(%s) → %s", peer.c_str(),
             peerPem.empty() ? "(空!)" : "PEM 已获取");
        if (!peerPem.empty()) {
            ns.setTrustedCertificate(peer, peerPem);
            note("[*] 已登记信任证书（模拟 TrustStore 回灌）");
        }
    }

    int rc = 0;
    if (mode == "pair") {
        const int64_t ts = static_cast<int64_t>(::time(nullptr));
        g_sentPairTs = ts;
        char frame[256];
        std::snprintf(frame, sizeof frame,
                      "{\"id\":%lld,\"type\":\"kdeconnect.pair\","
                      "\"body\":{\"pair\":true,\"timestamp\":%lld}}\n",
                      (long long) nowMs(), (long long) ts);
        note("[*] 发送配对请求 timestamp=%lld，本机验证码='%s'", (long long) ts,
             ns.getPairVerificationCode(peer, ts).c_str());
        if (!ns.sendPacket(peer, frame)) {
            note("[!] sendPacket 失败（链路未 Encrypted？）");
            ns.stop();
            return 1;
        }
        if (waitFor([] { return g_pairAccepted || g_pairRejected; }, 45000, "对端配对应答")) {
            rc = g_pairAccepted ? 0 : 1;
            if (g_pairAccepted) {
                // 回到主线程再算（回调线程里算会自锁，见 g_pairPeerId 处注释）
                // 对端接受包不带 timestamp（v8 语义）⇒ 用我方请求的 ts 算验证码
                const int64_t codeTs = g_pairTimestamp >= 0 ? g_pairTimestamp : g_sentPairTs;
                g_verificationCode = ns.getPairVerificationCode(g_pairPeerId, codeTs);
                note("[*] 本机验证码='%s'（应与桌面端弹窗里的 Key 一致）", g_verificationCode.c_str());
            }
        } else {
            rc = 1;
        }
    } else if (mode == "sendfile") {
        const uint64_t id = ns.sendPayload(peer, "kdeconnect.share.request",
                                           "{\"filename\":\"hosttest.bin\"}", filePath);
        if (id == 0) {
            note("[!] sendPayload 失败");
            ns.stop();
            return 1;
        }
        note("[*] 发送任务 id=%llu，等待对端拉取...", (unsigned long long) id);
        if (waitFor([] { return g_xferState == "finished"; }, 60000, "payload finished")) {
            rc = 0;
        } else {
            rc = 1;
        }
    } else if (mode == "ping") {
        // A9：配对完成后「我方能否主动发 ping 给对端」的 native 半边（对端插件加载情况用
        // 桌面端 DBus `device.loadedPlugins` / `kdeconnect-cli --ping` 侧证）。
        char frame[256];
        std::snprintf(frame, sizeof frame,
                      "{\"id\":%lld,\"type\":\"kdeconnect.ping\",\"body\":{}}\n",
                      (long long) nowMs());
        const bool sent = ns.sendPacket(peer, frame);
        note("[*] sendPacket(kdeconnect.ping) → %s", sent ? "OK" : "FAILED");
        rc = sent ? 0 : 1;
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
    } else if (mode == "serve") {
        // 保持连接 N 秒，并把收到的 payload 落盘（模拟 ArkTS 的 keep 决策），
        // 用于验证接收方向：桌面端执行
        //   kdeconnect-cli -d hosttest00000000000000000000000000 --share <file>
        const int seconds = serveSeconds > 0 ? serveSeconds : 60;
        note("[*] serve %d 秒：等待对端发文件（payload 接收 → settle 落盘）", seconds);
        const int64_t deadline = nowMs() + static_cast<int64_t>(seconds) * 1000;
        uint64_t lastSettled = 0;
        while (nowMs() < deadline) {
            uint64_t id = 0;
            {
                std::lock_guard<std::mutex> lk(g_mu);
                if (g_xferState == "finished" && g_xferId != 0 && g_xferId != lastSettled) {
                    id = g_xferId;
                }
            }
            if (id != 0) {
                const std::string dest = "/tmp/kdc_received_" + std::to_string(id) + ".bin";
                const bool ok = ns.payloadSettle(id, dest, true);
                note("[*] settle(id=%llu) → %s : %s", (unsigned long long) id, dest.c_str(),
                     ok ? "OK" : "FAILED");
                lastSettled = id;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }
        rc = 0;
    } else if (mode == "probe") {
        // 建链成功即证明：端口探测命中了真实监听端口（对端 identity/TLS 都过了）
        note("[*] 端口未知拨号成功：native 探测到对端端口并完成 TLS + identity 交换");
        rc = 0;
    } else {
        note("[!] 未知模式: %s", mode.c_str());
        rc = 2;
    }

    note("[*] 结束（rc=%d）", rc);
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    ns.stop();
    return rc;
}
