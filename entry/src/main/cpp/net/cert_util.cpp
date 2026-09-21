// SPDX-License-Identifier: GPL-2.0-or-later
// R1（MSG93_TO_CODEARTS）：cert_util 的实现已迁移到 Rust（rust/kdc_core/src/cert.rs）。
// 本文件只保留**薄 shim**：公开签名与语义逐字不变（net/cert_util.h 未改动，调用方零改动）。
// 行为对照证据见 R1 报告：Rust 与迁移前 C++ 实现做了 ~7900 组差分（含 TLV 变异/随机 DER），逐字节一致。
#include "cert_util.h"

#include "rust_shim.h"

namespace kdeconnect {

std::string base64Encode(const uint8_t *data, size_t len)
{
    return rustshim::callRetry(
        [&](uint8_t *out, size_t cap) { return kdc_b64_encode(data, len, out, cap); });
}

std::string derToPem(const std::string &label, const uint8_t *der, size_t len)
{
    return rustshim::callRetry([&](uint8_t *out, size_t cap) {
        return kdc_der_to_pem(reinterpret_cast<const uint8_t *>(label.data()), label.size(), der, len,
                              out, cap);
    });
}

std::string pemToDer(const std::string &pem, const std::string &label)
{
    return rustshim::callRetry([&](uint8_t *out, size_t cap) {
        return kdc_pem_to_der(reinterpret_cast<const uint8_t *>(pem.data()), pem.size(),
                              reinterpret_cast<const uint8_t *>(label.data()), label.size(), out,
                              cap);
    });
}

std::string extractSpkiDer(const uint8_t *certDer, size_t len)
{
    return rustshim::callRetry(
        [&](uint8_t *out, size_t cap) { return kdc_extract_spki(certDer, len, out, cap); });
}

std::string extractSubjectDnDer(const uint8_t *certDer, size_t len)
{
    return rustshim::callRetry(
        [&](uint8_t *out, size_t cap) { return kdc_extract_subject_dn(certDer, len, out, cap); });
}

std::string computeVerificationCode(const std::string &ownSpkiDer, const std::string &peerSpkiDer,
                                    int64_t pairingTimestamp)
{
    return rustshim::callRetry([&](uint8_t *out, size_t cap) {
        return kdc_verification_code(reinterpret_cast<const uint8_t *>(ownSpkiDer.data()),
                                     ownSpkiDer.size(),
                                     reinterpret_cast<const uint8_t *>(peerSpkiDer.data()),
                                     peerSpkiDer.size(), pairingTimestamp, out, cap);
    });
}

} // namespace kdeconnect
