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

// NetStack 实现的宿主钩子。payload 模块只依赖本接口（host 可测，CPP_GUIDE §2）。
class PayloadHost {
public:
    virtual ~PayloadHost() = default;
    virtual bool epollAdd(int fd, uint32_t events) = 0;
    virtual void epollDel(int fd) = 0;
    virtual const std::string &certPem() = 0;
    virtual const std::string &keyPem() = 0;
    // 发送控制帧（含结尾 '\n' 由调用方负责拼接）。任意线程可调（内部有锁）。
    virtual bool sendControlFrame(const std::string &deviceId, const std::string &frame) = 0;
    // 事件出口（tsfn 桥，线程安全）。
    virtual void postPayloadEvent(NetEvent ev) = 0;
    virtual int64_t nowMs() = 0;
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
    bool started = false;
    bool finished = false;
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
    void emitLocked(const PayloadJob &job, const char *state, int code, const char *msg);
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
};

} // namespace kdeconnect

#endif
