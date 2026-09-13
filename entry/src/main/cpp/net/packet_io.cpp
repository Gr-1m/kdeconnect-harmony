// R1（MSG93_TO_CODEARTS）：packet_io 的实现已迁移到 Rust（rust/kdc_core/src/packet.rs）。
// 本文件只保留**薄 shim**：公开签名与语义逐字不变（net/packet_io.h 未改动，调用方零改动）。
// 行为对照证据见 R1 报告：Rust 与迁移前 C++ 实现的 golden 输出逐行 diff 完全一致
// （含 extractFrame 四态、buildIdentity 带/不带 caps、parseIdentity 回读、parsePacket 三例）。
#include "packet_io.h"

#include "rust_shim.h"

#include <utility>
#include <vector>

namespace kdeconnect {

bool PacketIO::extractFrame(std::string &buf, std::string &frame, size_t maxSize)
{
    frame.clear();
    // Rust 侧就地处理接收缓冲（取帧/丢帧后写回剩余内容）⇒ 用工作副本，成功才回写 buf。
    std::vector<uint8_t> work(buf.begin(), buf.end());
    // 完整帧长度必 ≤ maxSize（更长的按超限丢弃）⇒ 帧缓冲一次给足，无需长度重试。
    std::vector<uint8_t> out(maxSize + 2);
    size_t newLen = work.size();
    const int32_t rc =
        kdc_extract_frame(work.data(), work.size(), maxSize, out.data(), out.size(), &newLen);
    if (rc == 0) {
        return false; // 半包：buf 原样，等下一批数据
    }
    if (rc == -2) {
        buf.assign(reinterpret_cast<const char *>(work.data()), newLen); // 超限帧已丢弃
        return true;
    }
    if (rc < 0) {
        return false; // 参数错误（不应发生）
    }
    frame.assign(reinterpret_cast<const char *>(out.data()), static_cast<size_t>(rc));
    buf.assign(reinterpret_cast<const char *>(work.data()), newLen);
    return true;
}

std::string PacketIO::buildIdentity(const std::string &deviceId, const std::string &deviceName,
                                    const std::string &deviceType, uint16_t tcpPort,
                                    int protocolVersion,
                                    const std::vector<std::string> &incomingCaps,
                                    const std::vector<std::string> &outgoingCaps)
{
    // capability 数组按「并排数组」传给 C ABI（见 rust/kdc_core/src/ffi.rs 注释）
    auto pack = [](const std::vector<std::string> &caps,
                   std::vector<const uint8_t *> &ptrs,
                   std::vector<size_t> &lens) {
        ptrs.reserve(caps.size());
        lens.reserve(caps.size());
        for (const std::string &c : caps) {
            ptrs.push_back(reinterpret_cast<const uint8_t *>(c.data()));
            lens.push_back(c.size());
        }
    };
    std::vector<const uint8_t *> inPtrs, outPtrs;
    std::vector<size_t> inLens, outLens;
    pack(incomingCaps, inPtrs, inLens);
    pack(outgoingCaps, outPtrs, outLens);

    return rustshim::callRetry([&](uint8_t *out, size_t cap) {
        return kdc_build_identity(
            reinterpret_cast<const uint8_t *>(deviceId.data()), deviceId.size(),
            reinterpret_cast<const uint8_t *>(deviceName.data()), deviceName.size(),
            reinterpret_cast<const uint8_t *>(deviceType.data()), deviceType.size(), tcpPort,
            protocolVersion, inPtrs.data(), inLens.data(), inPtrs.size(), outPtrs.data(),
            outLens.data(), outPtrs.size(), out, cap);
    });
}

bool PacketIO::parseIdentity(const std::string &json, DeviceInfo &info)
{
    uint16_t tcpPort = 0;
    const std::string blob = rustshim::callRetry([&](uint8_t *out, size_t cap) {
        return kdc_parse_identity(reinterpret_cast<const uint8_t *>(json.data()), json.size(), out,
                                  cap, &tcpPort);
    });
    if (blob.empty()) {
        return false;
    }
    std::string fields[3];
    rustshim::splitNul(blob, fields, 3);
    info.deviceId = std::move(fields[0]);
    info.deviceName = std::move(fields[1]);
    info.deviceType = std::move(fields[2]);
    info.tcpPort = tcpPort;
    return true;
}

bool PacketIO::isValidDeviceId(const std::string &deviceId)
{
    return kdc_is_valid_device_id(reinterpret_cast<const uint8_t *>(deviceId.data()),
                                  deviceId.size()) == 1;
}

bool PacketIO::parsePacket(const std::string &json, std::string &type, std::string &body,
                           int64_t *payloadSize, uint16_t *payloadTransferPort)
{
    int64_t size = 0;
    uint16_t port = 0;
    const std::string blob = rustshim::callRetry([&](uint8_t *out, size_t cap) {
        return kdc_parse_packet(reinterpret_cast<const uint8_t *>(json.data()), json.size(), out, cap,
                                &size, &port);
    });
    if (blob.empty()) {
        return false;
    }
    std::string fields[2];
    rustshim::splitNul(blob, fields, 2);
    type = std::move(fields[0]);
    body = std::move(fields[1]);
    if (payloadSize != nullptr) {
        *payloadSize = size;
    }
    if (payloadTransferPort != nullptr) {
        *payloadTransferPort = port;
    }
    return true;
}

} // namespace kdeconnect
