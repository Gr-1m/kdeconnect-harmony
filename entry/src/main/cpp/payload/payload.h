#ifndef KDECONNECT_PAYLOAD_H
#define KDECONNECT_PAYLOAD_H

#include "../net/net_types.h"
#include "../net/packet_io.h"
#include "../net/tls_engine.h"

#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace kdeconnect {

// M1 简化：固定走应用沙箱 cacheDir（context.cacheDir 的 native 视角路径）；
// d.ts v2 若引入 NetConfig.spoolDir 则由 ArkTS 传入覆盖（WP1 设计 v0.2 §3）。
constexpr const char *kPayloadSpoolDirDefault =
    "/data/storage/el2/base/haps/entry/cache/kdeconnect_payloads";
constexpr int64_t PAYLOAD_ACCEPT_TIMEOUT_MS = 30000;  // 对齐 KDE compositeuploadjob
constexpr size_t PAYLOAD_CHUNK = 16 * 1024;
constexpr int64_t PAYLOAD_PROGRESS_INTERVAL_MS = 100; // 节流 ≤10Hz（WP1 设计 v0.2 §2）
// 传输级无进展超时：握手完成后 deadlineMs 会被清零（原设计只在建连/握手阶段设限），
// 若 FSM 因任何原因停摆（例如 EPOLLET 边沿耗尽），任务会永久停在「接收中」。
// 这里以「lastProgressMs 超过阈值无进展」判失败（AtomCode 全量排查 域5 P2-2/P2-3）。
constexpr int64_t PAYLOAD_STALL_TIMEOUT_MS = 30000;

// NetStack 实现的宿主钩子。payload 模块只依赖本接口（host 可测，CPP_GUIDE §2）。
//
// 锁序契约（P0-3 ABBA 防护，MSG57）：PayloadManager::mu_ 只保护本模块状态。
// mu_ → host 回调方向只允许「不取其他锁」的实现（epollAdd/epollDel/postPayloadEvent/nowMs）；
// 任何会反向取锁的 host 调用（sendControlFrame → NetStack::connMutex_；
// peerCertPem → NetStack::connMutex_/trustMutex_）**必须在持有 mu_ 之外调用**。
// 反例（已修）：startSend 曾持 mu_ 调 sendControlFrame，与网络线程
// connMutex_ → mu_（startReceive/onDeviceDown）构成 ABBA。
class PayloadHost {
public:
    virtual ~PayloadHost() = default;
    virtual bool epollAdd(int fd, uint32_t events) = 0;
    virtual void epollDel(int fd) = 0;
    // 按需改兴趣位（实现方恒定附加 EPOLLET）。payload fd **不再常驻 EPOLLOUT**：
    // EPOLLET 下「无待发内容却挂着 EPOLLOUT」会让 epoll_wait 反复上报（真机 wake[payload]=31,526），
    // 更糟的是边沿耗尽后读事件滞留 ⇒ 接收 FSM 停摆 ⇒「永远接收中」。返回 true 表示已应用。
    virtual bool epollMod(int fd, uint32_t events) = 0;
    virtual const std::string &certPem() = 0;
    virtual const std::string &keyPem() = 0;
    // 发送控制帧（含结尾 '\n' 由调用方负责拼接）。任意线程可调（内部有锁）。
    virtual bool sendControlFrame(const std::string &deviceId, const std::string &frame) = 0;
    // 事件出口（tsfn 桥，线程安全）。
    virtual void postPayloadEvent(NetEvent ev) = 0;
    virtual int64_t nowMs() = 0;
    // 已知的对端证书 PEM（信任存储/既有连接缓存；空 = 未知）。取锁，禁止在 mu_ 内调用。
    // 用途：send 方向作为 TLS server 需向对端宣告其证书 subject DN 作为可接受 CA 名。
    virtual std::string peerCertPem(const std::string &deviceId) = 0;
};

struct PayloadJob {
    uint64_t id = 0;
    std::string deviceId;
    std::string fileName;
    bool send = true;               // true = 本机提供（监听等待对端拉取）
    int listenFd = -1;              // send 专用；首个连入后即关闭（单传输）
    int sockFd = -1;
    std::unique_ptr<TlsEngine> tls;
    int fileFd = -1;                // send: 源文件只读；receive: spool 只写
    int64_t total = 0;              // payloadSize（-1 = 流式）
    int64_t done = 0;
    int64_t deadlineMs = 0;         // 建连/握手阶段的 30s 超时；流式阶段清零
    int64_t lastProgressMs = 0;
    std::string pending;            // send：TLS 引擎未接收的剩余字节
    std::string spoolPath;          // receive 专用
    // send 专用（P0-2）：对端证书 subject DN 的 DER（写入 CertificateRequest 的可接受 CA 名）。
    // 空 = 未知 → 占位名 + 容忍缺失，最终由 CN 校验兜底。
    std::vector<uint8_t> peerCaDnDer;
    bool started = false;
    bool finished = false;
    // 落盘进行中（settle 在锁外做文件 I/O 时置位）：阻止并发 settle，并让 finishJobLocked
    // 不再去动 spool（避免拷贝源在过程中被清理，见 PayloadManager::settle 注释）。
    bool settling = false;
    // 最近一次对外派发的状态字面量 + 错误码/原因（仅供埋点诊断，见 [KDC-PAYLOAD]）。
    // 原因入埋点：DevEco MSG22 只看到 state=failed 而无法判定失败环节，故补 code/msg。
    std::string lastState = "pending";
    int lastCode = 0;
    std::string lastMsg;
    // EPOLLOUT 兴趣是否已挂（仅 mu_ 内读写）：只在状态变化时 epoll_ctl(MOD)
    bool writeArmed = false;
};

class PayloadManager {
public:
    PayloadManager(PayloadHost *host, std::string spoolDir);

    // —— 任意线程（NAPI）——
    // 组帧发送：native 注入 payloadSize/payloadTransferInfo.port（WP1 设计 v0.2 §3）。
    // 返回 transferId（0 = 失败）。
    uint64_t startSend(const std::string &deviceId, const std::string &type,
                       const std::string &bodyJson, const std::string &filePath);
    // 已 finished 的接收任务：keep=true 时 rename 到 destPath，否则删除 spool。
    bool settle(uint64_t id, const std::string &destPath, bool keep);
    void cancel(uint64_t id);

    // —— 仅网络线程 ——
    uint64_t startReceive(const std::string &deviceId, const std::string &host,
                          uint16_t port, int64_t payloadSize, const std::string &bodyJson);
    bool handlesFd(int fd) const;
    void onReadable(int fd);
    void onWritable(int fd);
    void onTick(int64_t nowMs);
    void onDeviceDown(const std::string &deviceId);

private:
    uint64_t allocIdLocked();
    void failJobLocked(PayloadJob &job, int code, const char *msg);
    void finishJobLocked(PayloadJob &job, const char *state, int code, const char *msg);
    void closeSocketsLocked(PayloadJob &job);
    void emitLocked(PayloadJob &job, const char *state, int code, const char *msg);
    // EPOLLOUT 兴趣按需刷新（仅 mu_ 内调用）
    void updateWriteInterestLocked(PayloadJob &job);
    void startHandshakeLocked(PayloadJob &job);
    void pumpSendLocked(PayloadJob &job);
    void drainReceiveLocked(PayloadJob &job);
    static bool verifyPeerLocked(PayloadJob &job);

    PayloadHost *host_;
    std::string spoolDir_;
    mutable std::mutex mu_;
    std::map<int, uint64_t> fdIndex_;     // sockFd/listenFd → jobId
    std::map<uint64_t, std::unique_ptr<PayloadJob>> jobs_;
    uint64_t nextId_ = 1;
    int64_t lastStatsMs_ = 0;   // [KDC-PAYLOAD] 埋点节流（仅 mu_ 内读写）
};

} // namespace kdeconnect

#endif
