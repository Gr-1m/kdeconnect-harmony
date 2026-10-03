// SPDX-License-Identifier: GPL-2.0-or-later
//
// 事件桥的**纯契约层**（header-only、不含任何 napi_* 调用）——T3 单测目标。
//
// 锁定三条契约（AtomCode MSG112 T3：drop 留痕语义 + 8 事件字段与 d.ts 逐字一致）：
//   ① 事件类型名数组：下标 = net_types.h 的 EventType 枚举值（顺序固定，勿错位），
//      取值与 types/libkdeconnect_napi/Index.d.ts 的 `NetEventType` 联合**逐字一致**；
//   ② 事件对象字段名：与 Index.d.ts 的 `NetEventBase` 声明**逐字一致**（曾误用 message/code，
//      见 REVIEW §4 P1-2 —— 该文件改动必须过 T3 门禁）；
//   ③ 事件队列深度（P2-A）：入队 +1；出队/丢弃 -1 且**下限收敛到 0**（不可为负）。
//
// napi/napi_events.cpp 直接复用本层（类型名数组、深度计数、字段名 debug 自检），
// 因此任何单侧漂移都会被 tests/test_main.cpp 的 T3 用例立即拦下。

#pragma once

#include <cstddef>
#include <cstring>
#include <atomic>
#include "../net/event_queue_stat.h"

namespace kdeconnect {
namespace napi_bridge {

// ① 8 类事件名。下标 = EventType（DeviceDiscovered=0 … PayloadTransfer=7），**顺序即契约**。
inline const char *const kEventTypeNames[] = {
    "deviceDiscovered", "deviceLost", "connected", "disconnected",
    "packetReceived", "pairingRequest", "error", "payloadTransfer",
};
inline constexpr std::size_t kEventTypeCount = sizeof(kEventTypeNames) / sizeof(kEventTypeNames[0]);

// ② 事件对象字段名（含 type）。与 Index.d.ts 的 NetEventBase 字段逐字一致（双向检查）。
inline const char *const kEventFieldNames[] = {
    "type",            // 事件对象必带；与 d.ts 的 NetEventBase.type 同名
    "deviceId", "deviceName", "deviceType", "host", "tcpPort", "role", "packet",
    "payloadTransferId", "errorCode", "errorMessage",
    "payloadDirection", "payloadState", "payloadSize", "payloadBytesDone",
    "payloadFileName", "payloadFilePath",
};
inline constexpr std::size_t kEventFieldCount =
    sizeof(kEventFieldNames) / sizeof(kEventFieldNames[0]);

// 字段名是否属于契约（debug 期自检用；历史错误名如 "message"/"code" 必须返回 false）。
inline bool isCanonicalEventField(const char *key)
{
    for (std::size_t i = 0; i < kEventFieldCount; ++i) {
        if (std::strcmp(key, kEventFieldNames[i]) == 0) {
            return true;
        }
    }
    return false;
}

// ③ 队列深度：入队 +1。
inline void eventEnqueued()
{
    kdeconnect::eventQueueDepth().fetch_add(1, std::memory_order_relaxed);
}

// ③ 队列深度：出队或丢弃 -1，**下限收敛到 0**（历史实现语义，避免计数为负）。
inline void eventDequeued()
{
    if (kdeconnect::eventQueueDepth().fetch_sub(1, std::memory_order_relaxed) <= 0) {
        kdeconnect::eventQueueDepth().store(0, std::memory_order_relaxed);
    }
}

} // namespace napi_bridge
} // namespace kdeconnect
