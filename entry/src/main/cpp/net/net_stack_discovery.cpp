// SPDX-License-Identifier: GPL-2.0-or-later
#include "net_stack.h"
#include "event_queue_stat.h"
#include "net_internal.h"
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
#include "net_internal.h"

// net_stack_discovery.cpp —— 事件循环 eventLoop / UDP 发现 / 触发广播
// （S5-b：自 net_stack.cpp 原样搬入，仅新增 include；行为零变化）

namespace kdeconnect {

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
                 "conn[in=%{public}llu out=%{public}llu hup=%{public}llu] jsq=%{public}lld",
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
                 (unsigned long long) connHup_,
             (long long) kdeconnect::eventQueueDepth().load(std::memory_order_relaxed));
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
            std::unique_lock<std::mutex> lk(connMutex_);
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
                        drainEncrypted(lk, c);
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

void NetStack::triggerBroadcast()
{
    // UI「扫描 / 下拉刷新」入口（MSG73_TO_OMP 修复 4）。
    // **实现约束（代码评审 L1）**：本函数由 JS 线程调用，而 lastBroadcastMs_/broadcastCount_
    // 是事件循环线程私有状态，直接在这里改构成数据竞争。故只置标志 + 唤醒事件循环，
    // 真正广播由循环线程执行（延迟 ≤ 一个 tick，UI 无感）。
    forceBroadcast_.store(true);
    wakeLoop();
}

} // namespace kdeconnect
