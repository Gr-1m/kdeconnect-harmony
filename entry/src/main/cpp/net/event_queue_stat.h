#ifndef KDECONNECT_EVENT_QUEUE_STAT_H
#define KDECONNECT_EVENT_QUEUE_STAT_H

#include <atomic>
#include <cstdint>

namespace kdeconnect {

// NAPI 事件队列积压深度（P2-A，AtomCode REVIEW_OMP_NATIVE_FULL P2-A）。
//
// 背景：tsfn 以 `max_queue_size = 0`（不限制）创建 —— 语义上**正确**（payload 终态事件不可丢），
// 但"无界"本身不可观测：一旦 JS 侧长期跟不上，只能看到内存增长而无从判断。
// 本计数把「无界」变成「**可见的无界**」：入队 +1、JS 侧取出 -1，并由 NETLOOP 行定期打印（jsq=…）。
//
// 放在**独立头**里（header-only、inline）是为了让 net 层（打印）与 napi 层（计数）共用同一份状态，
// 而不引入 net → napi 的反向依赖。
inline std::atomic<int64_t> &eventQueueDepth()
{
    static std::atomic<int64_t> depth{0};
    return depth;
}

} // namespace kdeconnect

#endif
