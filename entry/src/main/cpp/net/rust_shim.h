// R1（MSG93_TO_CODEARTS §4）：Rust 迁移后的 C++/Rust 边界胶水。
//
// 本头文件只做两件事：
//   1. 声明 rust/kdc_core 暴露的 C ABI（约定见 rust/kdc_core/src/ffi.rs 头注释）；
//   2. 提供统一的「容量不足则扩容重试」调用助手 —— Rust 返回所需长度、负数表示语义失败，
//      故 C++ 侧无需关心具体长度，直接拿 std::string 即可。
//
// 注意：公开契约（net/packet_io.h、net/cert_util.h）与本头文件无关，前者逐字未改。
#ifndef KDECONNECT_RUST_SHIM_H
#define KDECONNECT_RUST_SHIM_H

#include <cstddef>
#include <cstdint>
#include <string>

extern "C" {
int32_t kdc_b64_encode(const uint8_t *data, size_t len, uint8_t *out, size_t out_cap);
int32_t kdc_der_to_pem(const uint8_t *label, size_t label_len, const uint8_t *der, size_t der_len,
                       uint8_t *out, size_t out_cap);
int32_t kdc_pem_to_der(const uint8_t *pem, size_t pem_len, const uint8_t *label, size_t label_len,
                       uint8_t *out, size_t out_cap);
int32_t kdc_extract_spki(const uint8_t *der, size_t len, uint8_t *out, size_t out_cap);
int32_t kdc_extract_subject_dn(const uint8_t *der, size_t len, uint8_t *out, size_t out_cap);
int32_t kdc_verification_code(const uint8_t *own, size_t own_len, const uint8_t *peer,
                              size_t peer_len, int64_t pairing_timestamp, uint8_t *out,
                              size_t out_cap);
int32_t kdc_extract_frame(uint8_t *buf, size_t buf_len, size_t max_size, uint8_t *out,
                          size_t out_cap, size_t *new_len);
int32_t kdc_build_identity(const uint8_t *device_id, size_t device_id_len, const uint8_t *device_name,
                           size_t device_name_len, const uint8_t *device_type,
                           size_t device_type_len, uint16_t tcp_port, int32_t protocol_version,
                           const uint8_t *const *in_ptrs, const size_t *in_lens, size_t in_count,
                           const uint8_t *const *out_ptrs, const size_t *out_lens, size_t out_count,
                           uint8_t *out, size_t out_cap);
int32_t kdc_parse_identity(const uint8_t *json, size_t json_len, uint8_t *out, size_t out_cap,
                           uint16_t *tcp_port);
int32_t kdc_is_valid_device_id(const uint8_t *id, size_t len);
int32_t kdc_parse_packet(const uint8_t *json, size_t json_len, uint8_t *out, size_t out_cap,
                         int64_t *payload_size, uint16_t *payload_port);
} // extern "C"

namespace kdeconnect {
namespace rustshim {

// 调用 Rust 并取回字符串结果：失败（负返回）→ 空串；容量不足 → 按其所需扩容重试。
template <typename F>
inline std::string callRetry(F fn)
{
    std::string buf(256, '\0');
    for (int attempt = 0; attempt < 8; ++attempt) {
        const int32_t need = fn(reinterpret_cast<uint8_t *>(buf.data()), buf.size());
        if (need < 0) {
            return std::string();
        }
        if (static_cast<size_t>(need) <= buf.size()) {
            buf.resize(static_cast<size_t>(need));
            return buf;
        }
        buf.resize(static_cast<size_t>(need));
    }
    return std::string();
}

// 把 `a\0b\0c\0` 形态的返回缓冲切成字段（Rust 侧多字段输出的约定）。
inline void splitNul(const std::string &blob, std::string *fields, size_t count)
{
    size_t pos = 0;
    for (size_t i = 0; i < count; ++i) {
        const size_t end = blob.find('\0', pos);
        const size_t stop = end == std::string::npos ? blob.size() : end;
        fields[i] = blob.substr(pos, stop - pos);
        pos = stop + 1;
    }
}

} // namespace rustshim
} // namespace kdeconnect

#endif
