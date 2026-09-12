#include "napi/napi_events.h"

#include <memory>
#include <mutex>

#include "hilog/log.h"

namespace kdeconnect {
namespace napi_bridge {

namespace {

// 与 ArkTS 侧 NetEvent.type 字符串一一对应。
// 下标 = net_types.h EventType 枚举值，顺序固定（DeviceDiscovered=0 ... Error=6），勿错位。
const char *kEventTypeNames[] = {
    "deviceDiscovered", "deviceLost", "connected", "disconnected",
    "packetReceived", "pairingRequest", "error", "payloadTransfer",
};

struct BridgeState {
    std::mutex mu;
    bool inited = false;
    bool shutDown = false;
    napi_threadsafe_function tsfn = nullptr;
};

BridgeState g_state;

// 把 NetEvent 序列化成扁平的 JS 对象。各字段只在对应事件类型下有值，
// 其余置 null（ArkTS 侧按 type 分支取值）。
napi_value BuildEventObject(napi_env env, const NetEvent &event)
{
    napi_value obj = nullptr;
    napi_create_object(env, &obj);

    napi_value typeVal = nullptr;
    napi_create_string_utf8(env, kEventTypeNames[static_cast<int>(event.type)],
                            NAPI_AUTO_LENGTH, &typeVal);
    napi_set_named_property(env, obj, "type", typeVal);

    auto setField = [env, obj](const char *key, const std::string &value) {
        napi_value v = nullptr;
        if (value.empty()) {
            napi_get_null(env, &v);
        } else {
            napi_create_string_utf8(env, value.c_str(), NAPI_AUTO_LENGTH, &v);
        }
        napi_set_named_property(env, obj, key, v);
    };

    auto setIntField = [env, obj](const char *key, double value) {
        napi_value v = nullptr;
        napi_create_double(env, value, &v);
        napi_set_named_property(env, obj, key, v);
    };

    setField("deviceId", event.deviceId);
    setField("deviceName", event.deviceName);
    setField("deviceType", event.deviceType);
    setField("host", event.host);
    setField("packet", event.packet);
    // 字段名必须与 Index.d.ts 逐字一致（曾误用 message/code，见 REVIEW §4 P1-2）
    setField("errorMessage", event.errorMessage);
    setIntField("tcpPort", event.tcpPort);
    setIntField("errorCode", event.errorCode);
    // WP-1b payload 字段（payloadTransfer 事件 / packetReceived 关联）
    setField("payloadState", event.payloadState);
    setField("payloadFilePath", event.payloadFilePath);
    setField("payloadFileName", event.payloadFileName);
    setField("payloadDirection",
             event.type == EventType::PayloadTransfer
                 ? (event.payloadDirectionSend ? "send" : "receive") : std::string());
    setIntField("payloadSize", static_cast<double>(event.payloadSize));
    setIntField("payloadBytesDone", static_cast<double>(event.payloadBytesDone));
    setIntField("payloadTransferId", static_cast<double>(event.payloadTransferId));

    napi_value role = nullptr;
    if (event.type == EventType::Connected) {
        std::string roleName = (event.role == TlsRole::Server) ? "server" : "client";
        napi_create_string_utf8(env, roleName.c_str(), NAPI_AUTO_LENGTH, &role);
        napi_set_named_property(env, obj, "role", role);
    } else {
        napi_get_null(env, &role);
        napi_set_named_property(env, obj, "role", role);
    }
    return obj;
}

// 由 ArkTS 主线程执行：把 NetEvent 对象交给用户回调。
void CallJs(napi_env env, napi_value callback, void *context, void *data)
{
    if (env == nullptr || callback == nullptr) {
        // env/callback 为空表示正在关闭，丢弃事件但必须释放 data。
        if (data != nullptr) {
            delete static_cast<std::unique_ptr<NetEvent> *>(data);
        }
        return;
    }
    auto *eventPtr = static_cast<std::unique_ptr<NetEvent> *>(data);
    if (eventPtr != nullptr) {
        napi_value eventObj = BuildEventObject(env, **eventPtr);
        napi_value result = nullptr;
        napi_value args[] = {eventObj};
        (void) napi_call_function(env, nullptr, callback, 1, args, &result);
        delete eventPtr;
    }
}

} // namespace

bool Init(napi_env env, napi_value callback)
{
    std::lock_guard<std::mutex> lock(g_state.mu);
    if (g_state.inited) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0x0001, "KDEConnect",
                     "napi event bridge already initialized, ignore");
        return false;
    }
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "kdeconnectNetEvents", NAPI_AUTO_LENGTH, &resourceName);

    // max_queue_size=0 无限队列，initial_thread_count=1（native 网络线程调用方）。
    if (napi_create_threadsafe_function(env, callback, nullptr, resourceName, 0, 1,
                                        nullptr, nullptr, nullptr, CallJs,
                                        &g_state.tsfn) != napi_ok) {
        g_state.tsfn = nullptr;
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0001, "KDEConnect",
                     "napi_create_threadsafe_function failed");
        return false;
    }
    g_state.inited = true;
    return true;
}

void Emit(const NetEvent &event)
{
    napi_threadsafe_function tsfn = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        if (!g_state.inited || g_state.shutDown) {
            return;
        }
        tsfn = g_state.tsfn;
    }
    if (tsfn == nullptr) {
        return;
    }
    auto data = new std::unique_ptr<NetEvent>(std::make_unique<NetEvent>(event));
    // nonblocking：队列满时丢弃而非阻塞网络线程（queue 设为 0 不会满，防御性处理）。
    if (napi_call_threadsafe_function(tsfn, data, napi_tsfn_nonblocking) != napi_ok) {
        delete data;
    }
}

void Shutdown()
{
    napi_threadsafe_function tsfn = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        if (!g_state.inited || g_state.shutDown) {
            return;
        }
        g_state.shutDown = true;
        tsfn = g_state.tsfn;
    }
    if (tsfn != nullptr) {
        napi_release_threadsafe_function(tsfn, napi_tsfn_release);
        g_state.inited = false;
        g_state.tsfn = nullptr;
    }
}

} // namespace napi_bridge
} // namespace kdeconnect
