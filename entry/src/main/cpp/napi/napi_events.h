#ifndef KDECONNECT_NAPI_EVENTS_H
#define KDECONNECT_NAPI_EVENTS_H

#include "napi/native_api.h"
#include "net/net_types.h"

// NAPI 事件桥：native 线程（epoll 事件循环）通过线程安全函数把 NetEvent 投递到 ArkTS 主线程。
// 用法：
//   1. ArkTS 调 init(callback) 时，napi_init.cpp 调 NapiEventBridgeInit(env, callback)
//   2. net 层任何线程调 NapiEventBridgeEmit(event) 发事件（事件需已完全填充）
//   3. stop/退出时调 NapiEventBridgeShutdown()
namespace kdeconnect {
namespace napi_bridge {

// 注册 ArkTS 事件回调（创建 threadsafe function）。重复调用返回 false 且不覆盖。
bool Init(napi_env env, napi_value callback);

// 从任意 native 线程发一个事件。event 会被拷贝，返回后即可释放。
// 未 Init 或已 Shutdown 时静默丢弃。
void Emit(const NetEvent &event);

// 释放 threadsafe function（排空队列后 finalize）。幂等。
void Shutdown();

} // namespace napi_bridge
} // namespace kdeconnect

#endif // KDECONNECT_NAPI_EVENTS_H
