#ifndef KDECONNECT_NET_LOG_H
#define KDECONNECT_NET_LOG_H

#include "hilog/log.h"

#undef LOG_TAG
#define LOG_TAG "KDEConnect"

#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, 0x0001, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0001, LOG_TAG, __VA_ARGS__)


// —— S4（CodeArts MSG23 §3）：排查级埋点的编译期开关 ——
//   1（默认，宿主测试用）：全部埋点（PHASESPLIT/LOCKHOLD/ENTRY-SPLIT/LOCKWAIT/FRAMESPLIT/DRAINSPLIT…）；
//   0（release）：只留粗粒度哨兵 —— [KDC-NETLOOP] 汇总行（其 maxHold/maxJsLockWait 仍照常累计）。
// 注意：**累计量不受开关影响**（仅打印被去掉），故 NETLOOP 行在 release 下信息量不变。
#ifndef KDC_TELEMETRY
#define KDC_TELEMETRY 1
#endif

// —— S2/S2b：锁内日志延迟打（唯一实现，net 与 payload 两层共用；见 net_internal.h 的历史注释）——
// connMutex_ 等临界区内不得直接调 hilog（锁内零 I/O）。有冲刷出口的线程（网络线程的两处临界区入口）
// 用 thread_local 缓冲攒日志、由 DeferredLogFlush 析构统一打；无出口的线程（JS/NAPI）立即打，
// 否则缓冲无限增长且日志丢失（t_flushArmed 守卫，AtomCode S2b）。
#include <cstdarg>
#include <cstdio>
#include <string>

namespace kdeconnect {

inline thread_local std::string t_deferredLogs;
inline thread_local bool t_flushArmed = false;

inline void deferLogf(const char *level, const char *fmt, ...)
{
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    if (!t_flushArmed) {
        OH_LOG_Print(LOG_APP, *level == 'E' ? LOG_ERROR : LOG_INFO, 0x0001, LOG_TAG,
                     "%{public}s", msg);
        return;
    }
    if (!t_deferredLogs.empty()) {
        t_deferredLogs += '\n';
    }
    t_deferredLogs += level;
    t_deferredLogs += msg;
}

// 构造点必须在 lock_guard 之前 ⇒ 析构时锁已释放，可安全打日志。
struct DeferredLogFlush {
    DeferredLogFlush() { t_flushArmed = true; }
    ~DeferredLogFlush()
    {
        t_flushArmed = false;
        if (!t_deferredLogs.empty()) {
            OH_LOG_Print(LOG_APP, LOG_INFO, 0x0001, LOG_TAG, "%{public}s",
                         t_deferredLogs.c_str());
            t_deferredLogs.clear();
        }
    }
};

} // namespace kdeconnect

#endif // KDECONNECT_NET_LOG_H
