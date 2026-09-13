#include "napi_exports.h"
#include "net_stack.h"
#include "cert_gen.h"
#include "net_log.h"
#include <cstdio>
#include <string>

using namespace kdeconnect;

// 说明：事件桥的唯一实现是 napi/napi_events.cpp（由 napi_init.cpp 的 OnInit 挂接）。
// 本文件此前另有一套 JsInit/TsfnCallJs/TsfnFinalize，从未被注册（napi_init.cpp 明确
// 注释过），已删除——两套序列化实现并存曾导致 error 事件字段名漂移（REVIEW §4 P1-2）。

// 取参 helper（代码评审 F1）：**必须**检查 NAPI 返回码与类型。
// 旧实现静默回落 0/空串 ⇒「JS 传错参数」表现为「native 悄悄用默认值」，
// 例如 certPem 为空串要等到 NetStack::start() 才失败，失败原因又会被吞掉（见 JsStart）。
// 现在：属性缺失或类型不符 → 抛 TypeError（JS 侧立刻可见），调用方随后直接返回 nullptr。
static void throwFieldTypeError(napi_env env, const char *field, const char *want)
{
    char msg[160];
    std::snprintf(msg, sizeof(msg), "start(config): '%s' 缺失或类型错误（需要 %s）", field, want);
    napi_throw_type_error(env, "EINVAL", msg);
}

static bool napiGetString(napi_env env, napi_value obj, const char *name, std::string &out)
{
    napi_value val = nullptr;
    if (napi_get_named_property(env, obj, name, &val) != napi_ok) {
        throwFieldTypeError(env, name, "string");
        return false;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, val, &type) != napi_ok || type != napi_string) {
        throwFieldTypeError(env, name, "string");
        return false;
    }
    size_t len = 0;
    if (napi_get_value_string_utf8(env, val, nullptr, 0, &len) != napi_ok) {
        throwFieldTypeError(env, name, "string");
        return false;
    }
    std::string s(len, '\0');
    size_t written = 0;
    if (napi_get_value_string_utf8(env, val, s.data(), len + 1, &written) != napi_ok) {
        throwFieldTypeError(env, name, "string");
        return false;
    }
    s.resize(written);
    out.swap(s);
    return true;
}

static bool napiGetInt(napi_env env, napi_value obj, const char *name, int32_t &out)
{
    napi_value val = nullptr;
    if (napi_get_named_property(env, obj, name, &val) != napi_ok) {
        throwFieldTypeError(env, name, "number");
        return false;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, val, &type) != napi_ok || type != napi_number) {
        throwFieldTypeError(env, name, "number");
        return false;
    }
    if (napi_get_value_int32(env, val, &out) != napi_ok) {
        throwFieldTypeError(env, name, "number");
        return false;
    }
    return true;
}

napi_value JsStart(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, "EINVAL", "start requires config");
        return nullptr;
    }

    NetConfig cfg;
    int32_t tcpPort = 0;
    if (!napiGetString(env, args[0], "deviceId", cfg.deviceId) ||
        !napiGetString(env, args[0], "deviceName", cfg.deviceName) ||
        !napiGetString(env, args[0], "deviceType", cfg.deviceType) ||
        !napiGetString(env, args[0], "certPem", cfg.certPem) ||
        !napiGetString(env, args[0], "keyPem", cfg.keyPem) ||
        !napiGetInt(env, args[0], "tcpPort", tcpPort)) {
        return nullptr;   // 已抛 TypeError，交由 JS 侧 catch
    }
    cfg.tcpPort = (tcpPort > 0 && tcpPort <= 0xFFFF) ? static_cast<uint16_t>(tcpPort) : 0;

    // F1：把 start() 的真实结果返回给 JS —— 此前恒返回 undefined，
    // 端口冲突/UDP bind 失败/epoll 失败都被吞掉，UI 无条件显示 running。
    const bool ok = netStack().start(cfg);
    LOGI("native start: deviceId=%s ok=%d", cfg.deviceId.c_str(), ok);
    napi_value ret = nullptr;
    if (napi_get_boolean(env, ok, &ret) != napi_ok) {
        return nullptr;
    }
    return ret;
}

napi_value JsStop(napi_env env, napi_callback_info info)
{
    (void) env; (void) info;
    netStack().stop();
    LOGI("native stop");
    return nullptr;
}

napi_value JsConnectToPeer(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_error(env, "EINVAL", "connectToPeer requires host and port");
        return nullptr;
    }

    size_t hostLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &hostLen);
    std::string host(hostLen, '\0');
    napi_get_value_string_utf8(env, args[0], host.data(), hostLen + 1, &hostLen);

    int32_t port = 0;
    napi_get_value_int32(env, args[1], &port);

    netStack().connectToPeer(host, static_cast<uint16_t>(port));
    return nullptr;
}

napi_value JsSendPacket(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_error(env, "EINVAL", "sendPacket requires deviceId and packetJson");
        return nullptr;
    }

    auto getStr = [&](napi_value v) -> std::string {
        size_t len = 0;
        napi_get_value_string_utf8(env, v, nullptr, 0, &len);
        std::string s(len, '\0');
        napi_get_value_string_utf8(env, v, s.data(), len + 1, &len);
        return s;
    };

    std::string deviceId = getStr(args[0]);
    std::string packet   = getStr(args[1]);

    bool ok = netStack().sendPacket(deviceId, packet);
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value JsDisconnect(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, "EINVAL", "disconnect requires deviceId");
        return nullptr;
    }

    size_t len = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
    std::string deviceId(len, '\0');
    napi_get_value_string_utf8(env, args[0], deviceId.data(), len + 1, &len);

    netStack().disconnectDevice(deviceId);
    return nullptr;
}

napi_value JsGenerateCert(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, "EINVAL", "generateCert requires deviceId");
        return nullptr;
    }

    size_t len = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
    std::string deviceId(len, '\0');
    napi_get_value_string_utf8(env, args[0], deviceId.data(), len + 1, &len);

    CertPair pair = CertGen::generateSelfSignedEc(deviceId);

    napi_value result;
    napi_create_object(env, &result);

    napi_value certVal;
    napi_create_string_utf8(env, pair.certPem.c_str(), NAPI_AUTO_LENGTH, &certVal);
    napi_set_named_property(env, result, "certPem", certVal);

    napi_value keyVal;
    napi_create_string_utf8(env, pair.keyPem.c_str(), NAPI_AUTO_LENGTH, &keyVal);
    napi_set_named_property(env, result, "keyPem", keyVal);

    return result;
}

// —————— WP-1b payload（WP1 设计 v0.2 §3；d.ts v2 定稿后逐字对齐）——————
namespace {

bool jsGetString(napi_env env, napi_value v, std::string &out)
{
    size_t len = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    out.resize(len);
    return napi_get_value_string_utf8(env, v, out.data(), len + 1, &len) == napi_ok;
}

bool jsGetDouble(napi_env env, napi_value v, double &out)
{
    return napi_get_value_double(env, v, &out) == napi_ok;
}

} // namespace

napi_value JsSendPayload(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double result = 0;
    if (argc >= 4) {
        std::string deviceId, type, body, path;
        if (jsGetString(env, args[0], deviceId) && jsGetString(env, args[1], type) &&
            jsGetString(env, args[2], body) && jsGetString(env, args[3], path)) {
            result = static_cast<double>(
                netStack().sendPayload(deviceId, type, body, path));
        }
    }
    napi_value out = nullptr;
    napi_create_double(env, result, &out);
    return out;
}

napi_value JsKeepPayload(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double id = 0;
    std::string dest;
    bool ok = false;
    if (argc >= 2 && jsGetDouble(env, args[0], id) && jsGetString(env, args[1], dest)) {
        ok = netStack().payloadSettle(static_cast<uint64_t>(id), dest, true);
    }
    napi_value out = nullptr;
    napi_get_boolean(env, ok, &out);
    return out;
}

napi_value JsDiscardPayload(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double id = 0;
    bool ok = false;
    if (argc >= 1 && jsGetDouble(env, args[0], id)) {
        ok = netStack().payloadSettle(static_cast<uint64_t>(id), std::string(), false);
    }
    napi_value out = nullptr;
    napi_get_boolean(env, ok, &out);
    return out;
}

napi_value JsCancelPayload(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double id = 0;
    if (argc >= 1 && jsGetDouble(env, args[0], id)) {
        netStack().payloadCancel(static_cast<uint64_t>(id));
    }
    napi_value out = nullptr;
    napi_get_undefined(env, &out);
    return out;
}

napi_value JsSetCapabilities(napi_env env, napi_callback_info info)
{
    // d.ts v2：setCapabilities(incoming: string[], outgoing: string[])
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc >= 2) {
        std::vector<std::string> caps[2];
        bool ok = true;
        for (int i = 0; i < 2 && ok; ++i) {
            uint32_t len = 0;
            if (napi_get_array_length(env, args[i], &len) != napi_ok) {
                ok = false;
                break;
            }
            for (uint32_t k = 0; k < len && ok; ++k) {
                napi_value item = nullptr;
                if (napi_get_element(env, args[i], k, &item) != napi_ok) {
                    ok = false;
                    break;
                }
                std::string cap;
                if (!jsGetString(env, item, cap)) {
                    ok = false;
                    break;
                }
                caps[i].push_back(std::move(cap));
            }
        }
        if (ok) {
            netStack().setCapabilities(caps[0], caps[1]);
        }
    }
    napi_value out = nullptr;
    napi_get_undefined(env, &out);
    return out;
}

napi_value JsGetPeerCertificate(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string pem;
    if (argc >= 1) {
        std::string deviceId;
        if (jsGetString(env, args[0], deviceId)) {
            pem = netStack().getPeerCertificate(deviceId);
        }
    }
    napi_value out = nullptr;
    napi_create_string_utf8(env, pem.c_str(), pem.size(), &out);
    return out;
}

napi_value JsGetPairVerificationCode(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string code;
    if (argc >= 2) {
        std::string deviceId;
        double ts = 0;
        if (jsGetString(env, args[0], deviceId) && jsGetDouble(env, args[1], ts)) {
            code = netStack().getPairVerificationCode(deviceId,
                                                      static_cast<int64_t>(ts));
        }
    }
    napi_value out = nullptr;
    napi_create_string_utf8(env, code.c_str(), code.size(), &out);
    return out;
}

napi_value JsGetOwnCertificate(napi_env env, napi_callback_info info)
{
    std::string pem = netStack().getOwnCertificate();
    napi_value out = nullptr;
    napi_create_string_utf8(env, pem.c_str(), pem.size(), &out);
    return out;
}

// —— WP-2 信任设备证书钉扎（持久化在 ArkTS TrustStore/Preferences，启动时回灌）——
napi_value JsSetTrustedCertificate(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc >= 2) {
        std::string deviceId, pem;
        if (jsGetString(env, args[0], deviceId) && jsGetString(env, args[1], pem)) {
            netStack().setTrustedCertificate(deviceId, pem);
        }
    }
    napi_value out = nullptr;
    napi_get_undefined(env, &out);
    return out;
}

napi_value JsRemoveTrustedCertificate(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc >= 1) {
        std::string deviceId;
        if (jsGetString(env, args[0], deviceId)) {
            netStack().removeTrustedCertificate(deviceId);
        }
    }
    napi_value out = nullptr;
    napi_get_undefined(env, &out);
    return out;
}

// —————— UDP 发现：UI 主动触发一次广播（CodeArts MSG73_TO_OMP 修复 4）——————
napi_value JsTriggerBroadcast(napi_env env, napi_callback_info info)
{
    (void) info;
    netStack().triggerBroadcast();
    napi_value out = nullptr;
    napi_get_undefined(env, &out);
    return out;
}
