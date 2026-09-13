#include "cert_util.h"

#include <bearssl_hash.h>

#include <algorithm>
#include <cstring>

namespace kdeconnect {

namespace {
const char kB64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
}

std::string base64Encode(const uint8_t *data, size_t len)
{
    std::string out;
    out.reserve(((len + 2) / 3) * 4);
    size_t i = 0;
    for (; i + 3 <= len; i += 3) {
        uint32_t v = (uint32_t(data[i]) << 16) | (uint32_t(data[i + 1]) << 8) | data[i + 2];
        out.push_back(kB64[(v >> 18) & 0x3F]);
        out.push_back(kB64[(v >> 12) & 0x3F]);
        out.push_back(kB64[(v >> 6) & 0x3F]);
        out.push_back(kB64[v & 0x3F]);
    }
    if (i + 1 == len) {
        uint32_t v = uint32_t(data[i]) << 16;
        out.push_back(kB64[(v >> 18) & 0x3F]);
        out.push_back(kB64[(v >> 12) & 0x3F]);
        out.push_back('=');
        out.push_back('=');
    } else if (i + 2 == len) {
        uint32_t v = (uint32_t(data[i]) << 16) | (uint32_t(data[i + 1]) << 8);
        out.push_back(kB64[(v >> 18) & 0x3F]);
        out.push_back(kB64[(v >> 12) & 0x3F]);
        out.push_back(kB64[(v >> 6) & 0x3F]);
        out.push_back('=');
    }
    return out;
}

std::string derToPem(const std::string &label, const uint8_t *der, size_t len)
{
    const std::string b64 = base64Encode(der, len);
    std::string out = "-----BEGIN " + label + "-----\n";
    for (size_t i = 0; i < b64.size(); i += 64) {
        out.append(b64, i, std::min<size_t>(64, b64.size() - i));
        out.push_back('\n');
    }
    out += "-----END " + label + "-----\n";
    return out;
}

static int b64Val(char c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

std::string pemToDer(const std::string &pem, const std::string &label)
{
    const std::string begin = "-----BEGIN " + label + "-----";
    const std::string end = "-----END " + label + "-----";
    size_t b = pem.find(begin);
    if (b == std::string::npos) {
        return std::string();
    }
    b += begin.size();
    size_t e = pem.find(end, b);
    if (e == std::string::npos) {
        return std::string();
    }
    std::string der;
    der.reserve((e - b) / 4 * 3);
    unsigned acc = 0, bits = 0;   // 无符号：左移累积不触发有符号溢出 UB
    for (size_t i = b; i < e; ++i) {
        char c = pem[i];
        if (c == '\n' || c == '\r' || c == ' ' || c == '\t' || c == '=') {
            continue;  // '=' padding：长度可由位数推出，直接跳过
        }
        int v = b64Val(c);
        if (v < 0) {
            return std::string();
        }
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            der.push_back(char((acc >> bits) & 0xFF));
        }
    }
    return der;
}

namespace {

// 读取单个 TLV；返回内容区间并把 p 推进到下一元素
bool readTLV(const uint8_t *&p, const uint8_t *end, uint8_t &tag,
             const uint8_t *&content, size_t &contentLen,
             const uint8_t *&elemStart, size_t &elemLen)
{
    if (p + 2 > end) {
        return false;
    }
    elemStart = p;
    tag = *p++;
    size_t len = *p++;
    if (len & 0x80) {
        size_t n = len & 0x7F;
        if (n == 0 || n > 4 || p + n > end) {
            return false;
        }
        len = 0;
        for (size_t i = 0; i < n; ++i) {
            len = (len << 8) | *p++;
        }
    }
    if (p + len > end) {
        return false;
    }
    content = p;
    contentLen = len;
    p += len;
    elemLen = static_cast<size_t>(p - elemStart);
    return true;
}

} // namespace

namespace {

// tbsCertificate 字段序固定：version([0],可选) serial sigAlg issuer validity subject spki。
// 取 subject（第 5 个 = i==4）与 SPKI（第 6 个 = i==5）的完整元素 DER（含 tag+len）。
bool walkTbsFields(const uint8_t *certDer, size_t len, std::string *subjectOut,
                   std::string *spkiOut)
{
    const uint8_t *p = certDer;
    const uint8_t *end = certDer + len;
    uint8_t tag;
    const uint8_t *content;
    size_t contentLen;
    const uint8_t *elemStart;
    size_t elemLen;

    // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
    if (!readTLV(p, end, tag, content, contentLen, elemStart, elemLen) || tag != 0x30) {
        return false;
    }
    // tbsCertificate ::= SEQUENCE { ... }
    const uint8_t *tbs = content;
    const uint8_t *tbsEnd = content + contentLen;
    if (!readTLV(tbs, tbsEnd, tag, content, contentLen, elemStart, elemLen) || tag != 0x30) {
        return false;
    }
    const uint8_t *q = content;
    const uint8_t *qEnd = content + contentLen;
    // 可选 [0] version
    if (q < qEnd && *q == 0xA0) {
        if (!readTLV(q, qEnd, tag, content, contentLen, elemStart, elemLen)) {
            return false;
        }
    }
    // serial(0x02) → sigAlg(0x30) → issuer(0x30) → validity(0x30) → subject(0x30) → spki(0x30)
    for (int i = 0; i < 6; ++i) {
        if (!readTLV(q, qEnd, tag, content, contentLen, elemStart, elemLen)) {
            return false;
        }
        if (i >= 4) {
            if (tag != 0x30) {
                return false;
            }
            std::string &out = (i == 4) ? *subjectOut : *spkiOut;
            out.assign(reinterpret_cast<const char *>(elemStart), elemLen);
            if (i == 5) {
                return true;
            }
        }
    }
    return false;
}

} // namespace

std::string extractSpkiDer(const uint8_t *certDer, size_t len)
{
    std::string subject;
    std::string spki;
    if (!walkTbsFields(certDer, len, &subject, &spki)) {
        return std::string();
    }
    return spki;
}

std::string extractSubjectDnDer(const uint8_t *certDer, size_t len)
{
    std::string subject;
    std::string spki;
    if (!walkTbsFields(certDer, len, &subject, &spki)) {
        return std::string();
    }
    return subject;
}

std::string computeVerificationCode(const std::string &ownSpkiDer,
                                    const std::string &peerSpkiDer,
                                    int64_t pairingTimestamp)
{
    if (ownSpkiDer.empty() || peerSpkiDer.empty()) {
        return std::string();
    }
    // KDE：if (a < b) swap —— 大者在前（QByteArray 字节序比较）
    std::string a = ownSpkiDer;
    std::string b = peerSpkiDer;
    if (a < b) {
        std::swap(a, b);
    }
    br_sha256_context ctx;
    br_sha256_init(&ctx);
    br_sha256_update(&ctx, a.data(), a.size());
    br_sha256_update(&ctx, b.data(), b.size());
    // v8：十进制 timestamp 字符串（QByteArray::setNum 语义）
    const std::string ts = std::to_string(pairingTimestamp);
    br_sha256_update(&ctx, ts.data(), ts.size());
    unsigned char digest[32];
    br_sha256_out(&ctx, digest);

    static const char kHex[] = "0123456789ABCDEF";
    std::string out;
    for (int i = 0; i < 4; ++i) {
        out.push_back(kHex[(digest[i] >> 4) & 0xF]);
        out.push_back(kHex[digest[i] & 0xF]);
    }
    return out;
}

} // namespace kdeconnect
