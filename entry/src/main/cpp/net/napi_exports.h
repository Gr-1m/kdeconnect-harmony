#ifndef KDECONNECT_NAPI_EXPORTS_H
#define KDECONNECT_NAPI_EXPORTS_H

#include "napi/native_api.h"

#ifdef __cplusplus
extern "C" {
#endif

// 事件注册入口不在此处：init 由 napi_init.cpp 的 OnInit + napi/napi_events.cpp 实现
//（唯一事件桥，字段名以 Index.d.ts 为准）。
napi_value JsStart(napi_env env, napi_callback_info info);
napi_value JsStop(napi_env env, napi_callback_info info);
napi_value JsConnectToPeer(napi_env env, napi_callback_info info);
napi_value JsSendPacket(napi_env env, napi_callback_info info);
napi_value JsDisconnect(napi_env env, napi_callback_info info);
napi_value JsGenerateCert(napi_env env, napi_callback_info info);
// WP-1b payload（契约名以 Index.d.ts v2 定稿为准，当前按 WP1 设计 v0.2）
napi_value JsSendPayload(napi_env env, napi_callback_info info);
napi_value JsKeepPayload(napi_env env, napi_callback_info info);
napi_value JsDiscardPayload(napi_env env, napi_callback_info info);
napi_value JsCancelPayload(napi_env env, napi_callback_info info);
napi_value JsSetCapabilities(napi_env env, napi_callback_info info);
napi_value JsGetPeerCertificate(napi_env env, napi_callback_info info);
napi_value JsGetOwnCertificate(napi_env env, napi_callback_info info);
napi_value JsGetPairVerificationCode(napi_env env, napi_callback_info info);

#ifdef __cplusplus
}
#endif

#endif
