#ifndef KDECONNECT_NET_INTERNAL_H
#define KDECONNECT_NET_INTERNAL_H

// 网络栈内部共享件（S5 拆 TU 前置）：从 net_stack.cpp 的匿名命名空间提取而来。
// 提取要点：
//   ① 匿名命名空间去掉并扁平化 —— 否则每个 TU 各持一份 thread_local 缓冲，
//      S2b 的 t_flushArmed/deferLogf 语义会被拆散（各 TU 独立缓冲）；
//   ② 命名空间级函数/变量一律 inline（含 inline thread_local、inline constexpr）
//      ⇒ 全程序单实例，跨 TU 共享同一份延迟日志缓冲；
//   ③ 调用点无需改动（名字不变、无需限定）。
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

#include "net_stack.h"

namespace kdeconnect {


// 事件循环 tick：定时器检查周期（REVIEW §4 P1-7 最小定时器基建）
// 出向连接失败时取真实原因：非阻塞 connect 的失败通过 SO_ERROR 暴露，
// 不看它就只能报出「写 identity 失败」这类对用户无意义的错误（实测：连不上时报
// code=5 "plain identity read failed"，App 无法提示「找不到对应 IP / 连接失败」）。
inline int socketSoError(int fd)
{
    int err = 0;
    socklen_t len = sizeof(err);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0) {
        return errno;
    }
    return err;
}

inline constexpr int LOOP_TICK_MS = 200;

// 仅接受私网地址直连（WP-2；公网/非法来源直接拒绝）—— 判定实现在 net_util.cpp
// （P1-1：172.16/12 边界曾写错，故独立成 host 可测单元并配边界回归用例）。

// 对端地址取自 socket（identity JSON 无 host 字段；REVIEW §3.4 建议 11）
inline std::string peerHostOf(int fd)
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


// 事件派发唯一收口。除转发外做两件事：
//  ① 按类型普查（[KDC-EVENTS] 随 NETLOOP 行输出）——用于判断"JS 线程被事件回调占住"的规模；
//  ② 同一设备 2s 内重复的 DeviceDiscovered 去重：UDP 广播（onUdpReadable）与对端拨入
//     （handlePlainIdentity）都会宣告同一设备，开屏期会成对放大 JS 侧处理量。
// ── 持锁分段计时（CodeArts MSG7 P0 / DevEco MSG11 §2.1）──
// 现象：真机 JS 线程等 connMutex_ 1.2~3.2s（maxJsLockWait 与慢 sendPacket 1:1），而套接字均为
// 非阻塞 ⇒ 只可能是「锁内长 CPU 工作」或「持锁时又等另一把锁（锁序）」。本守卫按调用点打标签，
// 超过阈值即打一行，并把窗口内最长的一次连同标签汇入 NETLOOP 行 —— 一次复跑即可指认凶手。
inline int64_t lockCpuMs()
{
    struct timespec ts {};
    if (::clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) {
        return -1;
    }
    return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

inline int64_t lockMonoMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

// 锁内子段计时（CodeArts MSG9 P0）：先定位「锁内长计算」到底花在哪一段，再谈移出锁。
// 只在总耗时超阈值时打一行，故对稳态零噪声。
inline int64_t monoMs();   // 定义见下方（供 PhaseAccum 使用）

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
        #if KDC_TELEMETRY   // S4：排查级埋点（release 关；累计量不受影响）
    if (total > 100) {
                LOGI("[KDC-PHASESPLIT] what=%{public}s total=%{public}lldms conns=%{public}d "
                     "plain=%{public}lldms tls=%{public}lldms ident=%{public}lldms "
                     "drain=%{public}lldms json=%{public}lldms flush=%{public}lldms",
                     what, (long long) total, conns, (long long) plain, (long long) tls,
                     (long long) ident, (long long) drain, (long long) json, (long long) flush);
            }
#endif
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
        #if KDC_TELEMETRY   // S4：排查级埋点（release 关；累计量不受影响）
    if (hold > LOCK_HOLD_LOG_MS) {
                LOGI("[KDC-LOCKHOLD] label=%{public}s hold=%{public}lldms cpu=%{public}lldms",
                     label, (long long) hold, (long long) (lockCpuMs() - cpu0));
            }
#endif
    }
};

// 本线程 CPU 时间（毫秒）。用途：区分「函数内真有活」与「线程未被调度/被阻塞」——
// 这是 DevEco ARKTS_ANALYSIS 与 NATIVE_ANALYSIS §2.4 约定的决定性判据。
inline int64_t threadCpuMs()
{
    struct timespec ts {};
    if (::clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) {
        return -1;
    }
    return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

// 自包含的单调毫秒（不依赖文件内其它定义，避免插入点可见性问题）
inline int64_t monoMs()
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
        #if KDC_TELEMETRY   // S4：排查级埋点（release 关；累计量不受影响）
    if (wall > ENTRY_SPLIT_LOG_MS) {
                LOGI("[KDC-ENTRY-SPLIT] sendPacket wall=%{public}lldms cpu=%{public}lldms "
                     "lock=%{public}lldms",
                     (long long) wall, (long long) (threadCpuMs() - cpu0), (long long) lockWaitMs);
            }
#endif
    }
};

} // namespace kdeconnect

#endif
