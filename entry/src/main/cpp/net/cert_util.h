// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef KDECONNECT_CERT_UTIL_H
#define KDECONNECT_CERT_UTIL_H

#include <cstdint>
#include <string>
#include <vector>

namespace kdeconnect {

// 证书/密钥相关纯函数（host 可测，WP-4 单测素材；WP-1c/AP-1b 验证码用）

// base64 编码（标准字母表，带 padding）
std::string base64Encode(const uint8_t *data, size_t len);

// DER → PEM（BEGIN/END label，每 64 字符换行）
std::string derToPem(const std::string &label, const uint8_t *der, size_t len);

// 取 PEM 首个 label 段的 base64 body 并解码为 DER；失败返回空
std::string pemToDer(const std::string &pem, const std::string &label);

// 从 X.509 证书 DER 提取 SubjectPublicKeyInfo 的完整 DER 编码（含 tag+len）。
// 只依赖最小 ASN.1 TLV 行走：CERT(tbs(sigAlg,...)) 内 version([0],可选) 后的第 6 个
// 元素即 SPKI（serial/sigAlg/issuer/validity/subject/spki）。失败返回空。
std::string extractSpkiDer(const uint8_t *certDer, size_t len);

// 从 X.509 证书 DER 提取 subject 字段（DN）的完整 DER 编码（含 tag+len）——同一行走，
// 取 subject（第 5 个元素）。用途：作为 TLS server 端 CertificateRequest 的可接受 CA 名，
// 与 KDE（Qt setCaCertificates）/Android（Java keyStore 信任项）把「对端证书主体」
// 作为 CA 列表的行为对等；对端 OpenSSL/SunJSSE 客户端据此决定是否出示自身证书。
std::string extractSubjectDnDer(const uint8_t *certDer, size_t len);

// KDE PairingHandler::verificationKey 的等价实现（三端互操作锚点）：
//   a,b = 双方证书公钥 SPKI DER，按字节序排序（大者在前）
//   SHA256(a || b [+ 十进制 timestamp 字符串（v8）]) → hex 前 8 位大写
std::string computeVerificationCode(const std::string &ownSpkiDer,
                                    const std::string &peerSpkiDer,
                                    int64_t pairingTimestamp);

} // namespace kdeconnect

#endif
