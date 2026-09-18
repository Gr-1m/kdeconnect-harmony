#include "payload/payload.h"

#include <arpa/inet.h>
#include <sys/epoll.h>
#include <cerrno>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../json/cJSON.h"
#include "../net/cert_util.h"
#include "../net/net_log.h"

namespace kdeconnect {

namespace {

int64_t fileSizeOf(int fd)
{
    struct stat st {};
    if (fstat(fd, &st) != 0) {
        return -1;
    }
    return static_cast<int64_t>(st.st_size);
}

// 从 packet body 提取 filename（展示用；spool 名用 transferId，防路径注入）
std::string bodyFileName(const std::string &bodyJson)
{
    std::string out;
    cJSON *body = cJSON_Parse(bodyJson.c_str());
    if (body != nullptr) {
        cJSON *name = cJSON_GetObjectItemCaseSensitive(body, "filename");
        if (cJSON_IsString(name) && name->valuestring != nullptr) {
            out = name->valuestring;
        }
        cJSON_Delete(body);
    }
    return out;
}

bool writeAll(int fd, const uint8_t *data, size_t len)
{
    size_t off = 0;
    while (off < len) {
        ssize_t n = ::write(fd, data + off, len - off);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        off += static_cast<size_t>(n);
    }
    return true;
}

} // namespace

// 跨文件系统保存兜底：`rename()` 跨挂载点（EXDEV）必然失败，而设备上 spool 在 cacheDir、
// 目标常在不同挂载点 ⇒ 必须支持「拷贝 + 删源」。成功才删源，失败清理半成品。
bool copyFileAndRemove(const std::string &src, const std::string &dst)
{
    const int in = ::open(src.c_str(), O_RDONLY | O_CLOEXEC);
    if (in < 0) {
        return false;
    }
    const int out = ::open(dst.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (out < 0) {
        ::close(in);
        return false;
    }
    char buf[PAYLOAD_CHUNK];
    bool ok = true;
    for (;;) {
        const ssize_t n = ::read(in, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            ok = false;
            break;
        }
        if (n == 0) {
            break;
        }
        if (!writeAll(out, reinterpret_cast<const uint8_t *>(buf), static_cast<size_t>(n))) {
            ok = false;
            break;
        }
    }
    ::close(out);
    ::close(in);
    if (ok) {
        // 源文件可能已被并发清理（例如会话断开走 finishJobLocked 清半成品；而本拷贝持有源 fd、
        // 已完整读完）。此时 unlink 失败属**预期**，绝不能因此删掉刚写好的目标文件。
        if (::unlink(src.c_str()) != 0 && errno != ENOENT) {
            LOGI("copyFileAndRemove: source unlink failed (errno=%d) but copy succeeded", errno);
        }
    } else {
        ::unlink(dst.c_str());   // 拷贝确实失败：清掉半成品目标
    }
    return ok;
}

// F4（代码评审）：清理上次运行遗留的 spool 孤儿。进程重启后不存在对应的接收任务，
// 这些文件永远不会被 settle() 消费。只删本模块自己的命名模式（payload_*.bin），
// 避免误删 spool 目录里的其他内容。
static void purgeStaleSpool(const std::string &dir)
{
    DIR *d = ::opendir(dir.c_str());
    if (d == nullptr) {
        return;
    }
    int removed = 0;
    while (struct dirent *e = ::readdir(d)) {
        const std::string name = e->d_name;
        if (name.rfind("payload_", 0) != 0 || name.size() <= 8 ||
            name.compare(name.size() - 4, 4, ".bin") != 0) {
            continue;
        }
        if (::unlink((dir + "/" + name).c_str()) == 0) {
            ++removed;
        }
    }
    ::closedir(d);
    if (removed > 0) {
        LOGI("payload spool: purged %d stale file(s) in %s", removed, dir.c_str());
    }
}


namespace {
// 持锁计时（与 net_stack 同款）：payload 的 mu_ 若被长持有，会让「持 connMutex_ 的网络线程」在
// 锁内等待（锁序 connMutex_ → mu_），进而让 JS 线程的 sendPacket 等数秒（DevEco MSG11）。
struct HoldTimer {
    const char *label;
    int64_t t0;
    int64_t cpu0;
    explicit HoldTimer(const char *l)
        : label(l),
          t0(std::chrono::duration_cast<std::chrono::milliseconds>(
                 std::chrono::steady_clock::now().time_since_epoch()).count()),
          cpu0(clockCpuMs())
    {
    }
    static int64_t clockCpuMs()
    {
        struct timespec ts {};
        if (::clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) {
            return -1;
        }
        return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
    }
    ~HoldTimer()
    {
        const int64_t hold = std::chrono::duration_cast<std::chrono::milliseconds>(
                                 std::chrono::steady_clock::now().time_since_epoch()).count() - t0;
        if (hold > LOCK_HOLD_LOG_MS) {
            LOGI("[KDC-LOCKHOLD] label=%{public}s hold=%{public}lldms cpu=%{public}lldms",
                 label, (long long) hold, (long long) (clockCpuMs() - cpu0));
        }
    }
};
}  // namespace

PayloadManager::PayloadManager(PayloadHost *host, std::string spoolDir)
    : host_(host), spoolDir_(std::move(spoolDir))
{
    // 确保多级目录存在（mkdir 逐级，已存在则忽略）
    std::string p = spoolDir_;
    for (size_t i = 1; i < p.size(); ++i) {
        if (p[i] == '/') {
            p[i] = '\0';
            ::mkdir(p.c_str(), 0755);
            p[i] = '/';
        }
    }
    ::mkdir(p.c_str(), 0755);
    purgeStaleSpool(spoolDir_);
}

uint64_t PayloadManager::allocIdLocked()
{
    return nextId_++;
}

void PayloadManager::closeSocketsLocked(PayloadJob &job)
{
    auto delFd = [this](int fd) {
        if (fd >= 0) {
            host_->epollDel(fd);
            ::close(fd);
            fdIndex_.erase(fd);
        }
    };
    delFd(job.listenFd);
    job.listenFd = -1;
    delFd(job.sockFd);
    job.sockFd = -1;
    job.tls.reset();
    if (job.fileFd >= 0) {
        ::close(job.fileFd);
        job.fileFd = -1;
    }
}

void PayloadManager::emitLocked(PayloadJob &job, const char *state,
                                int code, const char *msg)
{
    job.lastState = state != nullptr ? state : "?";
    job.lastCode = code;
    job.lastMsg = msg != nullptr ? msg : "";
    NetEvent ev {};
    ev.type = EventType::PayloadTransfer;
    ev.deviceId = job.deviceId;
    ev.payloadTransferId = job.id;
    ev.payloadDirectionSend = job.send;
    ev.payloadState = state;
    ev.payloadFileName = job.fileName;
    ev.payloadFilePath = job.spoolPath;
    ev.payloadSize = job.total;
    ev.payloadBytesDone = job.done;
    ev.errorCode = code;
    ev.errorMessage = msg != nullptr ? msg : "";
    host_->postPayloadEvent(std::move(ev));
}

void PayloadManager::finishJobLocked(PayloadJob &job, const char *state,
                                     int code, const char *msg)
{
    if (job.finished) {
        return;
    }
    job.finished = true;
    job.pending.clear();
    closeSocketsLocked(job);
    if (!job.send && job.spoolPath.size() > 0 &&
        (std::strcmp(state, "finished") != 0)) {
        ::unlink(job.spoolPath.c_str());   // 未完成的接收：清理半成品
        job.spoolPath.clear();
    }
    emitLocked(job, state, code, msg);
}

void PayloadManager::failJobLocked(PayloadJob &job, int code, const char *msg)
{
    finishJobLocked(job, "failed", code, msg);
}

bool PayloadManager::verifyPeerLocked(PayloadJob &job)
{
    // 设计 v0.2 §5：payload 通道对端证书 CN 必须等于期望 deviceId
    const std::string cn = job.tls != nullptr ? job.tls->peerCommonName() : std::string();
    if (cn.empty() || cn != job.deviceId) {
        LOGE("payload peer CN mismatch: got '%s', expect '%s'",
             cn.c_str(), job.deviceId.c_str());
        return false;
    }
    return true;
}

uint64_t PayloadManager::startSend(const std::string &deviceId, const std::string &type,
                                   const std::string &bodyJson, const std::string &filePath)
{
    if (!PacketIO::isValidDeviceId(deviceId)) {
        return 0;
    }
    int fileFd = ::open(filePath.c_str(), O_RDONLY | O_CLOEXEC);
    if (fileFd < 0) {
        return 0;
    }
    const int64_t total = fileSizeOf(fileFd);
    if (total < 0) {
        ::close(fileFd);
        return 0;
    }

    int listenFd = -1;
    uint16_t bound = 0;
    if (total != 0) {
        listenFd = ::socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
        int one = 1;
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        for (uint16_t p = PAYLOAD_PORT_MIN; p <= TCP_PORT_MAX && listenFd >= 0; ++p) {
            sockaddr_in addr {};
            addr.sin_family = AF_INET;
            addr.sin_addr.s_addr = htonl(INADDR_ANY);
            addr.sin_port = htons(p);
            if (::bind(listenFd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) == 0 &&
                ::listen(listenFd, 1) == 0) {
                bound = p;
                break;
            }
        }
        if (bound == 0) {
            ::close(listenFd);
            ::close(fileFd);
            return 0;
        }
    }

    cJSON *root = cJSON_CreateObject();
    cJSON_AddNumberToObject(root, "id", 0);
    cJSON_AddStringToObject(root, "type", type.c_str());
    cJSON *body = cJSON_Parse(bodyJson.c_str());
    if (body == nullptr) {
        body = cJSON_CreateObject();
    }
    cJSON_AddItemToObject(root, "body", body);
    cJSON_AddNumberToObject(root, "payloadSize", static_cast<double>(total));
    if (total != 0) {
        cJSON *ti = cJSON_CreateObject();
        cJSON_AddNumberToObject(ti, "port", bound);
        cJSON_AddItemToObject(root, "payloadTransferInfo", ti);
    }
    char *printed = cJSON_PrintUnformatted(root);
    std::string frame = printed != nullptr ? printed : "{}";
    cJSON_free(printed);
    cJSON_Delete(root);
    frame.push_back('\n');

    // P0-2：取对端证书 subject DN（TLS server 端 CertificateRequest 的可接受 CA 名）。
    // 必须在 mu_ 之外调 host_：peerCertPem → NetStack::connMutex_/trustMutex_，
    // 持 mu_ 调用会与网络线程的 connMutex_ → mu_ 构成 ABBA（P0-3）。
    std::vector<uint8_t> peerCaDn;
    {
        const std::string peerPem = host_->peerCertPem(deviceId);
        if (!peerPem.empty()) {
            const std::string der = pemToDer(peerPem, "CERTIFICATE");
            if (!der.empty()) {
                const std::string dn = extractSubjectDnDer(
                    reinterpret_cast<const uint8_t *>(der.data()), der.size());
                peerCaDn.assign(dn.begin(), dn.end());
            }
        }
        if (peerCaDn.empty()) {
            LOGE("payload send: peer cert unknown for %s (degraded client-auth)",
                 deviceId.c_str());
        }
    }

    // 控制帧必须在 mu_ 之外发（同 P0-3：sendControlFrame → NetStack::connMutex_）。
    // 对端只在本帧送达后才会连入，故先发帧、后注册 listen fd 不会丢连接
    // （listen 已在监听，连接最多在 backlog 中短暂等待一次 epollAdd）。
    if (!host_->sendControlFrame(deviceId, frame)) {
        ::close(listenFd);
        ::close(fileFd);
        return 0;
    }

    HoldTimer _hold("payload::startSend");
    std::lock_guard<std::mutex> lk(mu_);
    auto job = std::make_unique<PayloadJob>();
    job->id = allocIdLocked();
    job->deviceId = deviceId;
    job->fileName = bodyFileName(bodyJson);
    job->send = true;
    job->fileFd = fileFd;
    job->total = total;
    job->listenFd = listenFd;
    job->peerCaDnDer = std::move(peerCaDn);
    job->deadlineMs = host_->nowMs() + PAYLOAD_ACCEPT_TIMEOUT_MS;
    job->started = true;
    if (listenFd >= 0) {
        // epollAdd 只碰 epoll fd，不取其他锁 → 允许在 mu_ 内调用（锁序契约见 payload.h）
        if (!host_->epollAdd(listenFd, EPOLLIN)) {
            closeSocketsLocked(*job);
            return 0;
        }
        fdIndex_[listenFd] = job->id;
    }
    const uint64_t id = job->id;
    jobs_[id] = std::move(job);
    emitLocked(*jobs_[id], "started", 0, nullptr);
    return id;
}

uint64_t PayloadManager::startReceive(const std::string &deviceId, const std::string &host,
                                  uint16_t port, int64_t payloadSize,
                                  const std::string &fileName)
{
    HoldTimer _hold("payload::startReceive");
    std::lock_guard<std::mutex> lk(mu_);
    if (!PacketIO::isValidDeviceId(deviceId) || spoolDir_.empty()) {
        return 0;
    }
    auto job = std::make_unique<PayloadJob>();
    job->id = allocIdLocked();
    job->deviceId = deviceId;
    job->fileName = bodyFileName(fileName);
    job->send = false;
    job->total = payloadSize;
    job->sockFd = ::socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    job->spoolPath = spoolDir_ + "/payload_" + std::to_string(job->id) + ".bin";
    job->fileFd = ::open(job->spoolPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (job->sockFd < 0 || job->fileFd < 0) {
        finishJobLocked(*job, "failed", EIO, "payload receive: fd setup failed");
        return 0;
    }
    sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (::inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1 ||
        ::connect(job->sockFd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0) {
        if (errno != EINPROGRESS) {
            failJobLocked(*job, errno, "payload connect failed");
            return 0;
        }
    }
    // 注册时**带 EPOLLOUT**：epoll_ctl(ADD) 会对"当前可写"立即上报一次，这正是握手首飞
    // （ServerHello/ClientHello）的触发点；随即登记 writeInterest.armed，之后由 updateWriteInterestLocked
    // 在状态变化时按需摘掉 —— 避免"无可写内容仍常驻 EPOLLOUT"的 ET 空转（真机 wake[payload]=31,526）。
    host_->epollAdd(job->sockFd, EPOLLIN | EPOLLOUT);
    job->writeInterest.armed = true;   // S3：注册时已带 EPOLLOUT
    fdIndex_[job->sockFd] = job->id;
    job->deadlineMs = host_->nowMs() + PAYLOAD_ACCEPT_TIMEOUT_MS;
    job->started = true;
    
    uint64_t id = job->id;
    jobs_[id] = std::move(job);
    // started 事件带 fileName/total；此处查回引用发送
    emitLocked(*jobs_[id], "started", 0, nullptr);
    return id;
}

void PayloadManager::startHandshakeLocked(PayloadJob &job)
{
    job.tls = std::make_unique<TlsEngine>(job.sockFd,
                                          job.send ? TlsRole::Server : TlsRole::Client);
    // P0-2：send 方向（本机 = TLS server）启用客户端证书认证——对端必须出示证书，
    // 其 subject CN 必须等于 deviceId（verifyPeerLocked）。对端证书未知时降级为
    // 占位 CA 名 + 容忍缺失，由 CN 校验兜底（Qt/OpenSSL 客户端不按 CA 列表过滤）。
    ServerClientAuth clientAuth;
    const ServerClientAuth *authArg = nullptr;
    if (job.send) {
        clientAuth.caDnDer = job.peerCaDnDer;
        clientAuth.tolerateNoCert = job.peerCaDnDer.empty();
        authArg = &clientAuth;
    }
    if (!job.tls->init(host_->certPem(), host_->keyPem(), authArg)) {
        failJobLocked(job, EIO, "payload tls init failed");
        return;
    }
    // B1（REVIEW §3.2）：payload 角色显式传入，不复用 tlsRole() 推导
    if (job.tls->doHandshake()) {
        if (!verifyPeerLocked(job)) {
            failJobLocked(job, EACCES, "payload peer cert mismatch");
            return;
        }
        job.deadlineMs = 0;
    }
}

// EPOLLOUT 按需挂/摘（与连接侧 P0-b2-c 同源）。
// **关键教训**：刷新点必须与「推进 TLS 引擎」同址 —— 载荷两个方向都要写握手记录，
// 首飞之前若没有任何一处刷新，EPOLLOUT 永不挂上 ⇒ 握手停摆（本机 harness 实测：接收侧 done=0 卡住）。
// 因此刷新放在 onReadable/onWritable 的**函数退出**（RAII）+ onTick。
void PayloadManager::updateWriteInterestLocked(PayloadJob &job)
{
    if (job.sockFd < 0) {
        return;
    }
    // 需要可写：有待发应用字节，或引擎还有待写记录，或握手尚未完成（首飞要写）。
    // 不纳入 SENDAPP：它几乎常真，会让 EPOLLOUT 变回常驻。
    const bool want = !job.pending.empty() ||
                      (job.tls != nullptr && (!job.tls->handshakeDone() || job.tls->wantsWrite()));
    // S3：与连接侧共用同一设施（宿主经 PayloadHost::epollMod 下发，恒定附加 EPOLLET）
    applyWriteInterest(job.writeInterest, job.sockFd, want, EPOLLIN,
                       [&](int f, uint32_t events) { return host_->epollMod(f, events); });
}

void PayloadManager::pumpSendLocked(PayloadJob &job)
{
    // 任意 return 路径都刷新写兴趣（局部 RAII，避免在多个返回点重复写）
    uint8_t buf[PAYLOAD_CHUNK];
    while (true) {
        if (!job.pending.empty()) {
            ssize_t w = job.tls->write(reinterpret_cast<const uint8_t *>(job.pending.data()),
                                       job.pending.size());
            if (w < 0) {
                failJobLocked(job, EIO, "payload tls write failed");
                return;
            }
            if (w == 0) {
                return;  // 引擎满，等 EPOLLOUT/tick
            }
            job.pending.erase(0, static_cast<size_t>(w));
            job.done += w;
        }
        if (job.total >= 0 && job.done >= job.total) {
            finishJobLocked(job, "finished", 0, nullptr);
            return;
        }
        if (job.pending.empty()) {
            ssize_t n = ::read(job.fileFd, buf, sizeof(buf));
            if (n < 0) {
                failJobLocked(job, errno, "payload source read failed");
                return;
            }
            if (n == 0) {
                // 源文件比声明短：KDE 接收侧会等 EOF 判定，这里直接失败并断开
                failJobLocked(job, EIO, "payload source shorter than payloadSize");
                return;
            }
            job.pending.append(reinterpret_cast<const char *>(buf), static_cast<size_t>(n));
        }
    }
}

void PayloadManager::drainReceiveLocked(PayloadJob &job)
{
    std::vector<uint8_t> buf(PAYLOAD_CHUNK);
    while (true) {
        ssize_t r = job.tls->read(buf);
        if (r == 0) {
            return;  // 等更多数据
        }
        if (r < 0) {
            // EOF：流式或足量视为完成
            if (job.total < 0 || job.done >= job.total) {
                finishJobLocked(job, "finished", 0, nullptr);
            } else {
                failJobLocked(job, ECONNRESET, "payload peer closed early");
            }
            return;
        }
        if (!writeAll(job.fileFd, buf.data(), static_cast<size_t>(r))) {
            // 落盘失败：中止并断开（REVIEW §3.4 建议 8）
            failJobLocked(job, errno, "payload spool write failed");
            return;
        }
        job.done += r;
        if (job.total >= 0 && job.done >= job.total) {
            finishJobLocked(job, "finished", 0, nullptr);
            return;
        }
    }
}

bool PayloadManager::handlesFd(int fd) const
{
    HoldTimer _hold("payload::handlesFd");
    std::lock_guard<std::mutex> lk(mu_);
    return fdIndex_.count(fd) != 0;
}

void PayloadManager::onReadable(int fd)
{
    HoldTimer _hold("payload::onReadable");
    std::lock_guard<std::mutex> lk(mu_);
    auto it = fdIndex_.find(fd);
    if (it == fdIndex_.end()) {
        return;
    }
    auto j = jobs_.find(it->second);
    if (j == jobs_.end() || j->second->finished) {
        return;
    }
    PayloadJob &job = *j->second;
    // 任意 return 路径都刷新写兴趣（RAII）：刷新点必须在**推进 TLS 引擎的入口**上，
    // 否则握手首飞前 EPOLLOUT 永不挂上（见 updateWriteInterestLocked 注释）。
    struct InterestGuard {
        PayloadManager *m;
        PayloadJob *j;
        ~InterestGuard() { m->updateWriteInterestLocked(*j); }
    } interestGuard{this, &job};

    if (job.send && job.listenFd == fd) {
        // 对端连入：只接受一个连接（KDE CompositeUploadJob 同语义）
        int cfd = ::accept4(fd, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (cfd < 0) {
            return;
        }
        host_->epollDel(fd);
        ::close(fd);
        fdIndex_.erase(fd);
        job.listenFd = -1;
        job.sockFd = cfd;
        fdIndex_[cfd] = job.id;
        // P0-1：新 fd 必须注册进 epoll，否则 TCP 已建但握手永不推进
        // （EPOLLET + 未注册 → 只能等 onTick 30s 超时）。
        if (!host_->epollAdd(cfd, EPOLLIN | EPOLLOUT)) {   // 同上：ADD 的上报即首飞触发点
            failJobLocked(job, EIO, "payload accept: epoll add failed");
            return;
        }
        job.writeInterest.armed = true;   // S3：注册时已带 EPOLLOUT
        startHandshakeLocked(job);
        return;
    }
    if (job.sockFd != fd || job.tls == nullptr) {
        return;
    }
    if (!job.tls->handshakeDone()) {
        if (job.tls->doHandshake()) {
            if (!verifyPeerLocked(job)) {
                failJobLocked(job, EACCES, "payload peer cert mismatch");
                return;
            }
            job.deadlineMs = 0;
            if (job.send) {
                pumpSendLocked(job);
            }
        }
        return;
    }
    if (job.send) {
        // 引擎可能带出对端关闭信号：读侧排空，驱动完成/失败判定
        std::vector<uint8_t> sink(PAYLOAD_CHUNK);
        ssize_t r = job.tls->read(sink);
        if (r < 0 && job.done < job.total) {
            failJobLocked(job, ECONNRESET, "payload peer closed during send");
            return;
        }
        pumpSendLocked(job);
    } else {
        drainReceiveLocked(job);
    }
}

void PayloadManager::onWritable(int fd)
{
    HoldTimer _hold("payload::onWritable");
    std::lock_guard<std::mutex> lk(mu_);
    auto it = fdIndex_.find(fd);
    if (it == fdIndex_.end()) {
        return;
    }
    auto j = jobs_.find(it->second);
    if (j == jobs_.end() || j->second->finished) {
        return;
    }
    PayloadJob &job = *j->second;
    // 任意 return 路径都刷新写兴趣（RAII）：刷新点必须在**推进 TLS 引擎的入口**上，
    // 否则握手首飞前 EPOLLOUT 永不挂上（见 updateWriteInterestLocked 注释）。
    struct InterestGuard {
        PayloadManager *m;
        PayloadJob *j;
        ~InterestGuard() { m->updateWriteInterestLocked(*j); }
    } interestGuard{this, &job};

    if (job.sockFd != fd) {
        return;
    }
    if (job.tls == nullptr) {
        // 非阻塞 connect 完成：查 SO_ERROR 后进入握手
        int err = 0;
        socklen_t len = sizeof(err);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
        if (err != 0) {
            failJobLocked(job, err, "payload connect failed");
            return;
        }
        startHandshakeLocked(job);
        return;
    }
    if (!job.tls->handshakeDone()) {
        if (job.tls->doHandshake()) {
            if (!verifyPeerLocked(job)) {
                failJobLocked(job, EACCES, "payload peer cert mismatch");
                return;
            }
            job.deadlineMs = 0;
            if (job.send) {
                pumpSendLocked(job);
            }
        }
        return;
    }
    if (job.send && !job.pending.empty()) {
        pumpSendLocked(job);
    }
}

void PayloadManager::onTick(int64_t nowMs)
{
    HoldTimer _hold("payload::onTick");
    std::lock_guard<std::mutex> lk(mu_);
    for (auto &p : jobs_) {
        PayloadJob &job = *p.second;
        if (job.finished) {
            continue;
        }
        if (job.deadlineMs > 0 && nowMs > job.deadlineMs) {
            failJobLocked(job, ETIMEDOUT, "payload handshake/accept timeout");
            continue;
        }
        if (job.tls != nullptr && job.tls->handshakeDone() && job.done > 0 &&
            nowMs - job.lastProgressMs >= PAYLOAD_PROGRESS_INTERVAL_MS) {
            job.lastProgressMs = nowMs;
            emitLocked(job, "progress", 0, nullptr);
        }
        // TX 滞留兜底：引擎可写但无边沿时由 tick 推动（与控制连接 tick 同思路）
        if (job.send && job.tls != nullptr && job.tls->handshakeDone() &&
            !job.pending.empty()) {
            pumpSendLocked(job);
        }
        // 传输级无进展超时：握手完成后 deadlineMs 已被清零，若 FSM 因任何原因停摆
        // （例如 EPOLLET 边沿耗尽），任务会永久停在「接收中」（AtomCode 域5 P2-2/P2-3）。
        if (job.lastProgressMs == 0) {
            job.lastProgressMs = nowMs;   // 首次进入 tick 起算
        }
        if (job.tls != nullptr && job.tls->handshakeDone() &&
            nowMs - job.lastProgressMs > PAYLOAD_STALL_TIMEOUT_MS) {
            failJobLocked(job, ETIMEDOUT, "payload stalled (no progress)");
            continue;
        }
        // 写兴趣兜底刷新（正常路径由 onReadable/onWritable 的 RAII 负责）
        updateWriteInterestLocked(job);
    }
    // FSM 埋点（DevEco MSG179 §2「文件永远停在接收中」定位用；CodeArts MSG4 §3 授权）：
    // 每 5s 每任务一行 —— 直接区分「少收字节」与「终态没发」。
    if (nowMs - lastStatsMs_ >= 5000) {
        lastStatsMs_ = nowMs;
        for (auto &p : jobs_) {
            PayloadJob &job = *p.second;
            LOGI("[KDC-PAYLOAD] id=%{public}llu send=%{public}d finished=%{public}d "
                 "total=%{public}lld done=%{public}lld pending=%{public}llu tlsDone=%{public}d "
                 "spool=%{public}s state=%{public}s code=%{public}d msg=%{public}s",
                 (unsigned long long) job.id, job.send ? 1 : 0, job.finished ? 1 : 0,
                 (long long) job.total, (long long) job.done,
                 (unsigned long long) job.pending.size(),
                 (job.tls != nullptr && job.tls->handshakeDone()) ? 1 : 0,
                 job.spoolPath.c_str(), job.lastState.c_str(), job.lastCode,
                 job.lastMsg.c_str());
        }
    }
}

void PayloadManager::onDeviceDown(const std::string &deviceId)
{
    HoldTimer _hold("payload::onDeviceDown");
    std::lock_guard<std::mutex> lk(mu_);
    for (auto &p : jobs_) {
        PayloadJob &job = *p.second;
        if (!job.finished && job.deviceId == deviceId) {
            failJobLocked(job, ECONNRESET, "control connection closed");
        }
    }
}

bool PayloadManager::settle(uint64_t id, const std::string &destPath, bool keep)
{
    std::string spool;
    {
        HoldTimer _hold("payload::settle");
        std::lock_guard<std::mutex> lk(mu_);
        auto j = jobs_.find(id);
        if (j == jobs_.end() || !j->second->finished || j->second->send) {
            return false;
        }
        if (j->second->settling) {
            return false;   // 已有一次落盘在进行：拒绝并发（比让调用方干等更好）
        }
        if (keep && (destPath.empty() || destPath.find("..") != std::string::npos)) {
            // 路径非法：**不擦除任务**，App 可以换一个合法路径重试
            LOGE("payload settle: invalid destPath '%s' (id=%llu)", destPath.c_str(),
                 (unsigned long long) id);
            return false;
        }
        spool = j->second->spoolPath;
        j->second->settling = true;   // 锁外阶段由本函数独占该任务的文件操作
    }

    // ——— 锁外做文件 I/O ———
    // 这里可能耗时到秒级（跨文件系统 = copyFileAndRemove 整文件拷贝）。**绝不能持 mu_**：
    // 该锁同时保护 payload 引擎的 FSM（onReadable/onWritable/onTick），持锁做 I/O 会让
    // 进行中的传输（例如媒体页正在拉取的专辑封面）整体停摆；本函数又是由 JS 线程经
    // JsKeepPayload 调用的，持锁还会连带拖住 UI（此前的"保存大文件卡顿"是同源问题）。
    // 拷贝期间源文件被 finishJobLocked 并发 unlink 是安全的：copyFileAndRemove 保持源 fd
    // 打开，POSIX 下 inode 存活到 close，拷贝仍能读完。
    bool ok = true;
    if (!keep) {
        if (::unlink(spool.c_str()) != 0) {
            LOGE("payload settle: discard failed id=%llu spool='%s' err=%d(%s)",
                 (unsigned long long) id, spool.c_str(), errno, strerror(errno));
            ok = false;
        }
    } else if (::rename(spool.c_str(), destPath.c_str()) != 0) {
        const int err = errno;
        // 跨文件系统（EXDEV）等场景 rename 必失败 —— 设备上 spool 在 cacheDir，
        // 目标常在不同挂载点，必须退回「拷贝 + 删除 spool」，否则「保存」静默失败。
        if (!copyFileAndRemove(spool, destPath)) {
            LOGE("payload settle: save failed id=%llu '%s' -> '%s' rename_err=%d(%s)",
                 (unsigned long long) id, spool.c_str(), destPath.c_str(), err, strerror(err));
            ok = false;   // 保留任务与 spool，允许 App 重试
        } else {
            LOGI("payload settle: saved via copy id=%llu rename_err=%d(%s) -> '%s'",
                 (unsigned long long) id, err, strerror(err), destPath.c_str());
        }
    }

    // ——— 回到锁内收尾 ———
    {
        HoldTimer _hold("payload::settle");
        std::lock_guard<std::mutex> lk(mu_);
        auto j = jobs_.find(id);
        if (j == jobs_.end()) {
            // 锁外期间任务被销毁（设备断开等）：文件操作结果仍然有效，按结果返回即可
            return ok;
        }
        j->second->settling = false;
        if (ok) {
            jobs_.erase(j);
        }
    }
    return ok;
}

void PayloadManager::cancel(uint64_t id)
{
    HoldTimer _hold("payload::cancel");
    std::lock_guard<std::mutex> lk(mu_);
    auto j = jobs_.find(id);
    if (j == jobs_.end() || j->second->finished) {
        return;
    }
    // 关闭 payload socket 即对端可见的取消信号（REVIEW §3.4 建议 9）
    finishJobLocked(*j->second, "cancelled", ECONNABORTED, "cancelled by local user");
}

} // namespace kdeconnect
