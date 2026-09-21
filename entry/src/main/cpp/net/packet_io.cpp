// SPDX-License-Identifier: GPL-2.0-or-later
// R1（MSG93_TO_CODEARTS）：packet_io 的实现已迁移到 Rust（rust/kdc_core/src/packet.rs）。
// 本文件只保留**薄 shim**：公开签名与语义逐字不变（net/packet_io.h 未改动，调用方零改动）。
// 行为对照证据见 R1 报告：Rust 与迁移前 C++ 实现的 golden 输出逐行 diff 完全一致
// （含 extractFrame 四态、buildIdentity 带/不带 caps、parseIdentity 回读、parsePacket 三例）。
#include "packet_io.h"

#include "rust_shim.h"

#include <utility>
#include <memory>
#include <vector>

namespace kdeconnect {

bool PacketIO::extractFrame(std::string &buf, std::string &frame, size_t maxSize)
{
    frame.clear();
    // Rust 侧就地处理接收缓冲（取帧/丢帧后写回剩余内容）⇒ 用工作副本，成功才回写 buf。
    // 性能（2026-09-16 真机定位）：原实现**每次调用**都新建 `out(maxSize+2)`（= 32MiB 零初始化）
    // 外加一份 work 拷贝；dispatchFrames 对**每一帧**都会调用本函数 ⇒ 收包突发时成为持 connMutex_
    // 的纯 CPU 大头（真机 json_dispatch 1.3~3.3s，cpu≈hold）。改为线程局部复用（本函数仅网络线程调用）。
    static thread_local std::vector<uint8_t> work;
    // out 用「不做零初始化」的分配：vector::resize/assign 会 memset 整块，而这里只需要容量。
    // 真机实测：32MiB 缓冲的首次分配 + 清零 + 页故障，正是修后残余的那次 ~384ms 持锁尖峰
    // （frames=1 bytes=2294 total=384ms ⇒ 每帧固定开销 ≫ 数据量）。new[] 对 POD 不初始化、
    // 页按需触碰 ⇒ 只付出实际用到的那几页；Rust 侧仍需 out 容量 ≥ maxSize+2（逻辑长度语义不变）。
    static thread_local std::unique_ptr<uint8_t[]> out;
    static thread_local size_t outCap = 0;
    work.assign(buf.begin(), buf.end());
    if (outCap < maxSize + 2) {
        out.reset(new uint8_t[maxSize + 2]);
        outCap = maxSize + 2;
    }
    size_t newLen = work.size();
    const int32_t rc =
        kdc_extract_frame(work.data(), work.size(), maxSize, out.get(), outCap, &newLen);
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
    frame.assign(reinterpret_cast<const char *>(out.get()), static_cast<size_t>(rc));
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
