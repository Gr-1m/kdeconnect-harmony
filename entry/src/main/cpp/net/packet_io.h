#ifndef KDECONNECT_PACKET_IO_H
#define KDECONNECT_PACKET_IO_H

#include "net_types.h"
#include <string>
#include <cstdint>

namespace kdeconnect {

class PacketIO {
public:
    // 从接收缓冲抽出一个完整帧（wire 形式，含结尾 '\n'）。
    //  - 成功：frame = 单个完整帧（含 '\n'），并从 buf 中移除；返回 true。
    //  - 半包：返回 false，buf 保持原样（等下次数据）。
    //  - 超限帧（> maxSize）：按「非法行丢弃」语义跳过，frame 置空并返回 true。
    // 调用方应对空 frame 跳过处理。纯函数，host 可测（WP-4 单测素材）。
    static bool extractFrame(std::string &buf, std::string &frame,
                             size_t maxSize = MAX_PACKET_SIZE);

    static std::string buildIdentity(const std::string &deviceId,
                                     const std::string &deviceName,
                                     const std::string &deviceType,
                                     uint16_t tcpPort,
                                     int protocolVersion = PROTOCOL_VERSION);

    static bool parseIdentity(const std::string &json, DeviceInfo &info);

    // deviceId 格式校验：^[a-zA-Z0-9_-]{32,38}$（协议三端一致，且 = 证书 CN）。
    // 抽出为纯函数，host 可测（WP-4 单测素材）；WP-2 信任存储用它派生存储键前必须过。
    static bool isValidDeviceId(const std::string &deviceId);

    // 解析 packet 的 type/body；可选输出 payload 元数据
    // （payloadSize：0 = 无 payload，-1 = 流式；payloadTransferPort：payloadTransferInfo.port）。
    static bool parsePacket(const std::string &json, std::string &type, std::string &body,
                            int64_t *payloadSize = nullptr,
                            uint16_t *payloadTransferPort = nullptr);
};

} // namespace kdeconnect

#endif
