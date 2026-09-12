#include "packet_io.h"
#include "../json/cJSON.h"
#include "net_log.h"
#include <cstring>

namespace kdeconnect {

// 从接收缓冲抽出一个完整帧（含结尾 '\n'）。纯函数，host 可测。
bool PacketIO::extractFrame(std::string &buf, std::string &frame, size_t maxSize)
{
    frame.clear();
    if (buf.empty()) {
        return false;
    }

    const size_t pos = buf.find('\n');
    if (pos == std::string::npos) {
        // 尚无完整行：超限则丢弃（防缓冲无限增长 / OOM），否则等后续数据
        if (buf.size() > maxSize) {
            LOGE("extractFrame: dropping oversized partial line (%zu bytes)", buf.size());
            buf.clear();
            return true; // frame 为空：调用方跳过
        }
        return false;
    }

    const size_t frameLen = pos + 1;
    if (frameLen > maxSize) {
        LOGE("extractFrame: dropping oversized frame (%zu bytes)", frameLen);
        buf.erase(0, frameLen);
        return true; // frame 为空：调用方跳过
    }

    frame.assign(buf, 0, frameLen);
    buf.erase(0, frameLen);
    return true;
}

std::string PacketIO::buildIdentity(const std::string &deviceId,
                                    const std::string &deviceName,
                                    const std::string &deviceType,
                                    uint16_t tcpPort,
                                    int protocolVersion)
{
    cJSON *root = cJSON_CreateObject();
    cJSON_AddNumberToObject(root, "id", 0);
    cJSON_AddStringToObject(root, "type", "kdeconnect.identity");
    cJSON_AddNumberToObject(root, "version", protocolVersion);

    cJSON *body = cJSON_CreateObject();
    cJSON_AddStringToObject(body, "deviceId", deviceId.c_str());
    cJSON_AddStringToObject(body, "deviceName", deviceName.c_str());
    cJSON_AddStringToObject(body, "deviceType", deviceType.c_str());
    cJSON_AddNumberToObject(body, "tcpPort", tcpPort);
    cJSON_AddNumberToObject(body, "protocolVersion", protocolVersion);
    // protocol v8 要求 incomingCapabilities / outgoingCapabilities
    cJSON *inCaps = cJSON_CreateArray();
    cJSON_AddItemToObject(body, "incomingCapabilities", inCaps);
    cJSON *outCaps = cJSON_CreateArray();
    cJSON_AddItemToObject(body, "outgoingCapabilities", outCaps);
    cJSON_AddItemToObject(root, "body", body);

    char *str = cJSON_PrintUnformatted(root);
    std::string result(str);
    free(str);
    cJSON_Delete(root);

    // 协议规定 packet 以换行分隔：KDE 的 accept 路径用 canReadLine()/readLine() 读明文
    // identity，帧尾缺 \n 会导致其 1s 超时 abort。UDP 收发两侧对帧尾 \n 均容忍（guest
    // 的 readIdentity 会 pop_back，KDE 用 fromJson 不要求 \n），故统一在帧尾追加。
    result.push_back('\n');

    return result;
}

bool PacketIO::isValidDeviceId(const std::string &deviceId)
{
    // 协议：^[a-zA-Z0-9_-]{32,38}$（三端一致；WP-2 信任存储以它为键前必须校验）
    if (deviceId.size() < 32 || deviceId.size() > 38) {
        return false;
    }
    for (char c : deviceId) {
        const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                        (c >= '0' && c <= '9') || c == '_' || c == '-';
        if (!ok) {
            return false;
        }
    }
    return true;
}

bool PacketIO::parseIdentity(const std::string &json, DeviceInfo &info)
{
    cJSON *root = cJSON_Parse(json.c_str());
    if (!root) return false;

    cJSON *type = cJSON_GetObjectItem(root, "type");
    if (!type || !cJSON_IsString(type) ||
        std::strcmp(type->valuestring, "kdeconnect.identity") != 0) {
        cJSON_Delete(root);
        return false;
    }

    cJSON *body = cJSON_GetObjectItem(root, "body");
    if (!body) {
        cJSON_Delete(root);
        return false;
    }

    cJSON *deviceId = cJSON_GetObjectItem(body, "deviceId");
    cJSON *deviceName = cJSON_GetObjectItem(body, "deviceName");
    cJSON *deviceType = cJSON_GetObjectItem(body, "deviceType");
    cJSON *tcpPort = cJSON_GetObjectItem(body, "tcpPort");

    if (deviceId && cJSON_IsString(deviceId)) {
        info.deviceId = deviceId->valuestring;
    }
    if (deviceName && cJSON_IsString(deviceName)) {
        info.deviceName = deviceName->valuestring;
    }
    if (deviceType && cJSON_IsString(deviceType)) {
        info.deviceType = deviceType->valuestring;
    }
    if (tcpPort && cJSON_IsNumber(tcpPort)) {
        info.tcpPort = static_cast<uint16_t>(tcpPort->valuedouble);
    }

    cJSON_Delete(root);

    // deviceId 必须存在且格式合法（REVIEW §4 P2-4：格式校验一处收口）
    if (!isValidDeviceId(info.deviceId)) {
        LOGE("parseIdentity: invalid deviceId (len=%zu)", info.deviceId.size());
        info.deviceId.clear();
        return false;
    }
    return true;
}

bool PacketIO::parsePacket(const std::string &json, std::string &type, std::string &body,
                           int64_t *payloadSize, uint16_t *payloadTransferPort)
{
    cJSON *root = cJSON_Parse(json.c_str());
    if (!root) return false;

    cJSON *t = cJSON_GetObjectItem(root, "type");
    cJSON *b = cJSON_GetObjectItem(root, "body");

    if (t && cJSON_IsString(t)) {
        type = t->valuestring;
    }
    if (b) {
        char *str = cJSON_PrintUnformatted(b);
        body = str;
        free(str);
    }

    // payload 元数据（WP-1b payload 传输的前置解析能力）：
    // payloadSize: 0 = 无 payload；-1 = 流式；>0 = 字节数
    if (payloadSize != nullptr) {
        cJSON *ps = cJSON_GetObjectItem(root, "payloadSize");
        *payloadSize = (ps && cJSON_IsNumber(ps))
                           ? static_cast<int64_t>(ps->valuedouble)
                           : 0;
    }
    if (payloadTransferPort != nullptr) {
        *payloadTransferPort = 0;
        cJSON *info = cJSON_GetObjectItem(root, "payloadTransferInfo");
        if (info && cJSON_IsObject(info)) {
            cJSON *port = cJSON_GetObjectItem(info, "port");
            if (port && cJSON_IsNumber(port)) {
                *payloadTransferPort = static_cast<uint16_t>(port->valuedouble);
            }
        }
    }

    cJSON_Delete(root);
    return !type.empty();
}

} // namespace kdeconnect
