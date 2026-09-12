#include "napi/native_api.h"
#include "hilog/log.h"
#include "net/napi_exports.h"
#include "net/net_stack.h"
#include "napi/napi_events.h"

// 占位 init 已由事件桥接管：注册 ArkTS 事件回调（threadsafe function）。
// 注意：napi_threadsafe_function 必须在主线程创建，init 只能被 ArkTS 主线程调用。
static napi_value OnInit(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_valuetype cbType = napi_undefined;
    if (argc >= 1) {
        napi_typeof(env, args[0], &cbType);
    }
    if (cbType != napi_function) {
        napi_throw_type_error(env, nullptr, "init(callback): callback must be a function");
        return nullptr;
    }
    if (!kdeconnect::napi_bridge::Init(env, args[0])) {
        napi_throw_error(env, nullptr, "init: event bridge already initialized");
        return nullptr;
    }
    // 事件通路唯一接点：net 层事件 → 桥 → ArkTS 回调。
    // 注意：napi_exports.cpp 的 JsInit 未被注册（init 由本文件 OnInit 承接），
    // 不要在别处再调 setEventCallback。
    kdeconnect::netStack().setEventCallback(
        [](const kdeconnect::NetEvent &event) { kdeconnect::napi_bridge::Emit(event); });
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0001, LOG_TAG, "event bridge initialized");
    return nullptr;
}

static napi_value RegisterModule(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"init", nullptr, OnInit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"start", nullptr, JsStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, JsStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"connectToPeer", nullptr, JsConnectToPeer, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"sendPacket", nullptr, JsSendPacket, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"disconnect", nullptr, JsDisconnect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"generateCert", nullptr, JsGenerateCert, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"sendPayload", nullptr, JsSendPayload, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"keepPayload", nullptr, JsKeepPayload, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"discardPayload", nullptr, JsDiscardPayload, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"cancelPayload", nullptr, JsCancelPayload, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"setCapabilities", nullptr, JsSetCapabilities, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"getPeerCertificate", nullptr, JsGetPeerCertificate, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"getOwnCertificate", nullptr, JsGetOwnCertificate, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"getPairVerificationCode", nullptr, JsGetPairVerificationCode, nullptr, nullptr,
         nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

// 模块名必须与文件名一致（libkdeconnect_napi.so -> kdeconnect_napi）。
// OpenHarmony 运行时只认 napi_module_register（constructor 约定），
// 不认 Node 风格的 napi_register_module_v1 符号。
NAPI_MODULE(kdeconnect_napi, RegisterModule)
