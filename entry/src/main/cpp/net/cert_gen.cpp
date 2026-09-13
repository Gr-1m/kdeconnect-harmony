#include "cert_gen.h"
#include "cert_util.h"
#include <cassert>
#include "net_log.h"
#include <bearssl.h>
#include <bearssl_ec.h>
#include <bearssl_hash.h>
#include <bearssl_rand.h>
#include <cstring>
#include <ctime>
#include <vector>
#include <sys/random.h>

namespace kdeconnect {

// 用内核 CSPRNG 填充 DRBG 种子。原实现把未初始化的栈内存当种子，
// keygen 熵质量不可靠；getrandom 失败时退回 /dev/urandom。
static bool seedDrbg(uint8_t *seed, size_t len)
{
    if (getrandom(seed, len, 0) == static_cast<ssize_t>(len)) {
        return true;
    }
    FILE *f = fopen("/dev/urandom", "rb");
    if (f == nullptr) {
        return false;
    }
    size_t r = fread(seed, 1, len, f);
    fclose(f);
    return r == len;
}

static bool getRandomBytes(uint8_t *out, size_t len)
{
    return seedDrbg(out, len);  // getrandom 直读，长度 ≤64 无需 DRBG 展开
}

static const char PEM_CERT_HEADER[] = "-----BEGIN CERTIFICATE-----";
static const char PEM_CERT_FOOTER[] = "-----END CERTIFICATE-----";
static const char PEM_KEY_HEADER[]  = "-----BEGIN EC PRIVATE KEY-----";
static const char PEM_KEY_FOOTER[]  = "-----END EC PRIVATE KEY-----";

// 区间内的闰日数（供有效期计算与单测；纯整数运算，无时区/闰年陷阱）
int leapDaysBetween(int startYear, int years)
{
    int leap = 0;
    for (int y = startYear + 1; y <= startYear + years; ++y) {
        if ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) {
            ++leap;
        }
    }
    return leap;
}

static std::string derToPemWrapped(const std::vector<uint8_t> &der,
                                   const char *header, const char *footer)
{
    std::string b64 = base64Encode(der.data(), der.size());
    std::string pem = header;
    pem += "\n";
    for (size_t i = 0; i < b64.size(); i += 64) {
        pem += b64.substr(i, 64);
        pem += "\n";
    }
    pem += footer;
    pem += "\n";
    return pem;
}

static void derAppend(std::vector<uint8_t> &out, const uint8_t *data, size_t len)
{
    out.insert(out.end(), data, data + len);
}

static void derAddTag(std::vector<uint8_t> &out, uint8_t tag, const uint8_t *content, size_t len)
{
    // F3（代码评审）：长度只支持 1/2 字节形式（≤65535）。当前所有调用方传入的都是
    // OID/DN/公钥等小字段，远小于 64KB ⇒ 该分支不可达；加断言防止将来有人传入大 buffer 后
    // 被静默截断成畸形 DER（截断的证书会以「配对验证码不一致」等形式在很远的地方暴露）。
    assert(len < 0x10000);
    out.push_back(tag);
    if (len < 0x80) {
        out.push_back(static_cast<uint8_t>(len));
    } else if (len < 0x100) {
        out.push_back(0x81);
        out.push_back(static_cast<uint8_t>(len));
    } else {
        out.push_back(0x82);
        out.push_back(static_cast<uint8_t>(len >> 8));
        out.push_back(static_cast<uint8_t>(len));
    }
    derAppend(out, content, len);
}

static void derAddInteger(std::vector<uint8_t> &out, const uint8_t *val, size_t len)
{
    std::vector<uint8_t> content;
    if (len > 0 && val[0] & 0x80) {
        content.push_back(0x00);
    }
    content.insert(content.end(), val, val + len);
    derAddTag(out, 0x02, content.data(), content.size());
}

static void derAddSmallInteger(std::vector<uint8_t> &out, int val)
{
    if (val == 0) {
        uint8_t zero = 0;
        derAddInteger(out, &zero, 1);
    } else {
        std::vector<uint8_t> bytes;
        while (val > 0) {
            bytes.insert(bytes.begin(), static_cast<uint8_t>(val & 0xFF));
            val >>= 8;
        }
        derAddInteger(out, bytes.data(), bytes.size());
    }
}

CertPair CertGen::generateSelfSignedEc(const std::string &deviceId, int validYears)
{
    LOGI("generating self-signed EC cert for deviceId=%s", deviceId.c_str());

    uint8_t rngState[64];
    if (!seedDrbg(rngState, sizeof(rngState))) {
        LOGE("DRBG seed failed (getrandom/urandom)");
        return {};
    }
    br_hmac_drbg_context rng;
    br_hmac_drbg_init(&rng, &br_sha256_vtable, rngState, sizeof(rngState));

    uint8_t keyBuffer[BR_EC_KBUF_PRIV_MAX_SIZE];
    uint8_t pubBuffer[BR_EC_KBUF_PUB_MAX_SIZE];
    br_ec_private_key sk;
    br_ec_public_key pk;

    const br_ec_impl *ec = &br_ec_p256_m15;
    br_ec_keygen(&rng.vtable, ec, &sk, keyBuffer, BR_EC_secp256r1);
    br_ec_compute_pub(ec, &pk, pubBuffer, &sk);

    std::vector<uint8_t> pubKeyBytes(pk.q, pk.q + pk.qlen);

    std::vector<uint8_t> certDer = buildSelfSignedCertDer(
        deviceId, pubKeyBytes, sk, validYears);

    // ECPrivateKey（RFC 5915）。外层 SEQUENCE 长度按内容计算——
    // 原实现硬编码 0x67（103），实际内容 119 字节，标准 DER 解析必然失败。
    std::vector<uint8_t> keyContent;
    static const uint8_t ecPrivHdr[] = {
        0x02, 0x01, 0x01,
        0x04, 0x20
    };
    derAppend(keyContent, ecPrivHdr, sizeof(ecPrivHdr));
    derAppend(keyContent, sk.x, sk.xlen);
    static const uint8_t oidP256[] = {
        0xA0, 0x0A, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07
    };
    derAppend(keyContent, oidP256, sizeof(oidP256));
    // [1] { BIT STRING (00 || point) }：长度随 qlen 计算（P-256 未压缩点 65 字节）
    keyContent.push_back(0xA1);
    keyContent.push_back(static_cast<uint8_t>(2 + 1 + pk.qlen));
    keyContent.push_back(0x03);
    keyContent.push_back(static_cast<uint8_t>(1 + pk.qlen));
    keyContent.push_back(0x00);
    derAppend(keyContent, pk.q, pk.qlen);

    std::vector<uint8_t> keyDer;
    derAddTag(keyDer, 0x30, keyContent.data(), keyContent.size());

    CertPair pair;
    pair.certPem = derToPemWrapped(certDer, PEM_CERT_HEADER, PEM_CERT_FOOTER);
    pair.keyPem  = derToPemWrapped(keyDer, PEM_KEY_HEADER, PEM_KEY_FOOTER);

    LOGI("cert generated: cert=%zu bytes, key=%zu bytes",
         pair.certPem.size(), pair.keyPem.size());
    return pair;
}

std::vector<uint8_t> CertGen::buildSelfSignedCertDer(
    const std::string &cn,
    const std::vector<uint8_t> &pubKey,
    const br_ec_private_key &sk,
    int validYears)
{
    static const uint8_t oidSha256[] = {
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02
    };
    static const uint8_t oidEcP256[] = {
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07
    };
    static const uint8_t oidCn[] = {
        0x06, 0x03, 0x55, 0x04, 0x03
    };

    std::vector<uint8_t> tbs;

    // version = v2：RFC 5280 要求 [0] EXPLICIT 包裹（A0 03 02 01 02）。
    // 上下文标签 [0] 构造形式 = 0xA0（不是 0xA3=[3]）；裸 INTEGER 会被
    // 标准解析器当成 serialNumber，整证解析失败。
    std::vector<uint8_t> verInner;
    derAddSmallInteger(verInner, 2);
    std::vector<uint8_t> ver;
    derAddTag(ver, 0xA0, verInner.data(), verInner.size());
    derAppend(tbs, ver.data(), ver.size());

    // serialNumber：随机 16 字节正整数。RFC 5280 要求正整数，硬编码 0
    // 会被部分校验器拒绝；derAddInteger 在首字节最高位为 1 时补 0x00 保证为正。
    uint8_t serialBytes[16];
    if (!getRandomBytes(serialBytes, sizeof(serialBytes))) {
        LOGE("serialNumber random bytes failed");
        return {};
    }
    serialBytes[0] |= 0x01;  // 确保非零
    std::vector<uint8_t> serial;
    derAddInteger(serial, serialBytes, sizeof(serialBytes));
    derAppend(tbs, serial.data(), serial.size());

    std::vector<uint8_t> sigAlg;
    derAddTag(sigAlg, 0x30, oidSha256, sizeof(oidSha256));

    derAppend(tbs, sigAlg.data(), sigAlg.size());

    std::vector<uint8_t> subject;
    {
        // Name = SEQUENCE OF RDN；RDN = SET OF AttributeTypeAndValue；
        // AttributeTypeAndValue = SEQUENCE { OID, value }（RFC 5280 §4.1.2.4）
        std::vector<uint8_t> cnVal;
        derAddTag(cnVal, 0x0C,
            reinterpret_cast<const uint8_t *>(cn.c_str()), cn.size());
        std::vector<uint8_t> atvContent;
        derAppend(atvContent, oidCn, sizeof(oidCn));
        derAppend(atvContent, cnVal.data(), cnVal.size());
        std::vector<uint8_t> atv;
        derAddTag(atv, 0x30, atvContent.data(), atvContent.size());
        std::vector<uint8_t> rdn;
        derAddTag(rdn, 0x31, atv.data(), atv.size());
        derAddTag(subject, 0x30, rdn.data(), rdn.size());
    }
    derAppend(tbs, subject.data(), subject.size());

    std::vector<uint8_t> validity;
    {
        const time_t now = time(nullptr);
        // C1：gmtime 返回静态缓冲，非线程安全 → gmtime_r
        struct tm tmNow {};
        gmtime_r(&now, &tmNow);
        // C2：按日历年推进（365×N 会漏算区间闰日，10 年偏差 2~3 天，偏离 RFC 5280 语义）
        const int years = validYears > 0 ? validYears : 1;
        const time_t later = now + (static_cast<time_t>(years) * 365 +
                                    leapDaysBetween(tmNow.tm_year + 1900, years)) * 86400;
        struct tm tmLater {};
        gmtime_r(&later, &tmLater);
        char bufNow[16], bufLater[16];
        strftime(bufNow, sizeof(bufNow), "%y%m%d%H%M%SZ", &tmNow);
        strftime(bufLater, sizeof(bufLater), "%y%m%d%H%M%SZ", &tmLater);
        std::vector<uint8_t> notBefore, notAfter;
        derAddTag(notBefore, 0x17, reinterpret_cast<const uint8_t *>(bufNow), 13);
        derAddTag(notAfter, 0x17, reinterpret_cast<const uint8_t *>(bufLater), 13);
        std::vector<uint8_t> valContent;
        derAppend(valContent, notBefore.data(), notBefore.size());
        derAppend(valContent, notAfter.data(), notAfter.size());
        derAddTag(validity, 0x30, valContent.data(), valContent.size());
    }
    derAppend(tbs, validity.data(), validity.size());

    derAppend(tbs, subject.data(), subject.size());

    {
        // SubjectPublicKeyInfo = SEQUENCE { AlgorithmIdentifier, BIT STRING }
        // AlgorithmIdentifier = SEQUENCE { OID id-ecPublicKey, 参数 OID secp256r1 }
        static const uint8_t oidEcPublicKey[] = {
            0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01
        };
        std::vector<uint8_t> algIdContent;
        derAppend(algIdContent, oidEcPublicKey, sizeof(oidEcPublicKey));
        derAppend(algIdContent, oidEcP256, sizeof(oidEcP256));
        std::vector<uint8_t> algId;
        derAddTag(algId, 0x30, algIdContent.data(), algIdContent.size());

        std::vector<uint8_t> spki;
        derAppend(spki, algId.data(), algId.size());
        std::vector<uint8_t> pubKeyBitString;
        pubKeyBitString.push_back(0x00);
        pubKeyBitString.insert(pubKeyBitString.end(), pubKey.begin(), pubKey.end());
        std::vector<uint8_t> pks;
        derAddTag(pks, 0x03, pubKeyBitString.data(), pubKeyBitString.size());
        derAppend(spki, pks.data(), pks.size());
        std::vector<uint8_t> spkiSeq;
        derAddTag(spkiSeq, 0x30, spki.data(), spki.size());
        derAppend(tbs, spkiSeq.data(), spkiSeq.size());
    }

    std::vector<uint8_t> tbsSeq;
    derAddTag(tbsSeq, 0x30, tbs.data(), tbs.size());

    // ECDSA-SHA256 签名 TBS
    br_sha256_context shaCtx;
    br_sha256_init(&shaCtx);
    br_sha256_update(&shaCtx, tbsSeq.data(), tbsSeq.size());
    uint8_t hash[br_sha256_SIZE];
    br_sha256_out(&shaCtx, hash);

    const br_ec_impl *ec = &br_ec_p256_m15;
    br_ecdsa_sign signFn = br_ecdsa_sign_asn1_get_default();
    uint8_t sigBuf[139];
    size_t sigLen = signFn(ec, &br_sha256_vtable, hash, &sk, sigBuf);
    if (sigLen == 0) {
        LOGE("ECDSA sign failed");
        return {};
    }

    std::vector<uint8_t> cert;
    derAppend(cert, tbsSeq.data(), tbsSeq.size());
    derAppend(cert, sigAlg.data(), sigAlg.size());

    std::vector<uint8_t> sigBitString;
    sigBitString.push_back(0x00);
    sigBitString.insert(sigBitString.end(), sigBuf, sigBuf + sigLen);
    std::vector<uint8_t> sigSeq;
    derAddTag(sigSeq, 0x03, sigBitString.data(), sigBitString.size());
    derAppend(cert, sigSeq.data(), sigSeq.size());

    std::vector<uint8_t> certSeq;
    derAddTag(certSeq, 0x30, cert.data(), cert.size());

    LOGI("cert DER built: %zu bytes (ECDSA-SHA256 signature %zu bytes)",
         certSeq.size(), sigLen);
    return certSeq;
}

std::string CertGen::derToPem(const std::vector<uint8_t> &der, const std::string &label)
{
    if (label == "CERTIFICATE") {
        return derToPemWrapped(der, PEM_CERT_HEADER, PEM_CERT_FOOTER);
    }
    return derToPemWrapped(der, PEM_KEY_HEADER, PEM_KEY_FOOTER);
}

} // namespace kdeconnect
