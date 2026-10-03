// SPDX-License-Identifier: GPL-2.0-or-later
// native host 单元测试（WP-4 native 侧，PROCESS.md §4 覆盖清单 / table-driven 风格）。
//
// 说明：CodeArts 建议的 doctest 为单头网络依赖（本机不可达且下载需用户授权），
// 这里用零依赖自写宏（TEST_CASE/CHECK_*），语义与 table-driven 一致；将来引入
// doctest 时只需替换本文件的断言宏，用例本体不动。
//
// 构建/运行：./run.sh（g++ 直接编译，无需 cmake；见脚本头注释）。

#include <cstdio>
#include <cstring>
#include <string>

#include "../net/cert_gen.h"
#include "../net/cert_util.h"
#include "../net/net_util.h"
#include "../net/net_types.h"
#include "../net/napi_args.h"
#include "../napi/napi_event_contract.h"
#include <cctype>
#include <fstream>
#include <iterator>
#include <vector>
#include <algorithm>
#include "../net/packet_io.h"

using namespace kdeconnect;

namespace {

int g_failed = 0;
int g_cases = 0;

#define TEST_CASE(name) \
    static void name(); \
    struct Case_##name { \
        Case_##name() { ++g_cases; name(); } \
    } inst_##name; \
    static void name()

#define CHECK(cond) \
    do { \
        if (!(cond)) { \
            ++g_failed; \
            std::fprintf(stderr, "FAIL %s:%d CHECK(%s)\n", __FILE__, __LINE__, #cond); \
        } \
    } while (0)

#define CHECK_EQ_STR(a, b) \
    do { \
        if (std::string(a) != std::string(b)) { \
            ++g_failed; \
            std::fprintf(stderr, "FAIL %s:%d CHECK_EQ_STR(%s != %s): '%s' vs '%s'\n", \
                         __FILE__, __LINE__, #a, #b, std::string(a).c_str(), \
                         std::string(b).c_str()); \
        } \
    } while (0)

} // namespace

// —————— extractFrame：帧切分（P0 级，B3 修复的核心） ——————

TEST_CASE(extractFrameSingle)
{
    std::string buf = "A\n";
    std::string frame;
    CHECK(PacketIO::extractFrame(buf, frame));
    CHECK_EQ_STR(frame, "A\n");
    CHECK(buf.empty());
}

TEST_CASE(extractFrameTwoInOne)
{
    // 一次 read 收到两帧合并（EPOLLET 排空后的典型形态）
    std::string buf = "A\nB\n";
    std::string frame;
    CHECK(PacketIO::extractFrame(buf, frame));
    CHECK_EQ_STR(frame, "A\n");
    CHECK(PacketIO::extractFrame(buf, frame));
    CHECK_EQ_STR(frame, "B\n");
    CHECK(buf.empty());
}

TEST_CASE(extractFrameHalfKeepsBuffer)
{
    // 半包：不得消费缓冲
    std::string buf = "{\"type\":\"kde";
    const std::string before = buf;
    std::string frame;
    CHECK(!PacketIO::extractFrame(buf, frame));
    CHECK_EQ_STR(buf, before);
}

TEST_CASE(extractFrameHalfThenRest)
{
    std::string buf = "{\"type\":\"kde";
    buf += "connect.ping\"}\n";
    std::string frame;
    CHECK(PacketIO::extractFrame(buf, frame));
    CHECK_EQ_STR(frame, "{\"type\":\"kdeconnect.ping\"}\n");
    CHECK(buf.empty());
}

TEST_CASE(extractFrameOversizeDropped)
{
    // 超限帧：按「非法行丢弃」，返回 true + 空 frame（防 OOM，P2-1）
    std::string buf = "123456\nok\n";
    std::string frame = "sentinel";
    CHECK(PacketIO::extractFrame(buf, frame, 4));
    CHECK(frame.empty());
    CHECK(PacketIO::extractFrame(buf, frame, 4));
    CHECK_EQ_STR(frame, "ok\n");
}

// —————— parsePacket：type/body/payload 元数据（D3） ——————

TEST_CASE(parsePacketPayloadFields)
{
    const char *json =
        "{\"id\":0,\"type\":\"kdeconnect.share.request\",\"body\":{\"filename\":\"a.png\"},"
        "\"payloadSize\":882,\"payloadTransferInfo\":{\"port\":1739}}";
    std::string type, body;
    int64_t size = -99;
    uint16_t port = 0;
    CHECK(PacketIO::parsePacket(json, type, body, &size, &port));
    CHECK_EQ_STR(type, "kdeconnect.share.request");
    CHECK(size == 882);
    CHECK(port == 1739);
    CHECK(body.find("a.png") != std::string::npos);
}

TEST_CASE(parsePacketNoPayload)
{
    const char *json = "{\"id\":0,\"type\":\"kdeconnect.ping\",\"body\":{}}";
    std::string type, body;
    int64_t size = -99;
    uint16_t port = 99;
    CHECK(PacketIO::parsePacket(json, type, body, &size, &port));
    CHECK_EQ_STR(type, "kdeconnect.ping");
    CHECK(size == 0);
    CHECK(port == 0);
}

TEST_CASE(parsePacketInvalidJson)
{
    std::string type, body;
    CHECK(!PacketIO::parsePacket("{oops", type, body));
}

// —————— isValidDeviceId：协议正则收口（P2-4） ——————

TEST_CASE(deviceIdValidation)
{
    struct Row { const char *id; bool ok; };
    const Row rows[] = {
        {"0123456789abcdef0123456789abcdef", true},   // 32 hex
        {"0123456789abcdef0123456789abcde-", true},   // '-' 合法
        {"0123456789abcdef0123456789abcde_", true},   // '_' 合法
        {"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef", true},   // 大写
        {"0123456789abcdef0123456789abcde", false},   // 31 位
        {"0123456789abcdef0123456789abcdef0", true},  // 33 位（32..38 区间内）
        {"0123456789abcdef0123456789abcdef01", true},  // 34 位仍合法（≤38）
        {"0123456789abcdef0123456789abcd.f", false},  // 非法字符
        {"", false},
    };
    for (const auto &r : rows) {
        CHECK(PacketIO::isValidDeviceId(r.id) == r.ok);
    }
    // 39 位：超上限
    CHECK(!PacketIO::isValidDeviceId(std::string(39, 'a')));
    // 38 位：上边界合法
    CHECK(PacketIO::isValidDeviceId(std::string(38, 'a')));
}

// —————— buildIdentity：caps 单一来源（§3.3 修复） ——————

TEST_CASE(buildIdentityCarriesCaps)
{
    const std::string id = "0123456789abcdef0123456789abcdef";
    std::vector<std::string> in{"kdeconnect.share.request", "kdeconnect.ping"};
    std::vector<std::string> out{"kdeconnect.ping"};
    const std::string s = PacketIO::buildIdentity(id, "Dev", "phone", 1716, 8, in, out);
    CHECK(s.find("kdeconnect.identity") != std::string::npos);
    CHECK(s.find(id) != std::string::npos);
    CHECK(s.find("kdeconnect.share.request") != std::string::npos);
    CHECK(s.find("\"tcpPort\":1716") != std::string::npos);
    CHECK(!s.empty() && s.back() == '\n');  // 帧尾换行（KDE readLine 依赖）
}

// —————— cert_util：base64/PEM 往返 ——————

TEST_CASE(base64KnownVectors)
{
    CHECK_EQ_STR(base64Encode(reinterpret_cast<const uint8_t *>("abc"), 3), "YWJj");
    CHECK_EQ_STR(base64Encode(reinterpret_cast<const uint8_t *>("ab"), 2), "YWI=");
    CHECK_EQ_STR(base64Encode(reinterpret_cast<const uint8_t *>("a"), 1), "YQ==");
}

TEST_CASE(pemDerRoundtrip)
{
    const uint8_t der[] = {0x30, 0x03, 0x01, 0x02, 0x03};
    const std::string pem = derToPem("CERTIFICATE", der, sizeof(der));
    CHECK(pem.find("-----BEGIN CERTIFICATE-----") == 0);
    const std::string back = pemToDer(pem, "CERTIFICATE");
    CHECK(back.size() == sizeof(der));
    CHECK(std::memcmp(back.data(), der, sizeof(der)) == 0);
    CHECK(pemToDer("garbage", "CERTIFICATE").empty());
}

// —————— extractSpkiDer：最小 ASN.1 行走 ——————

namespace {
// 手工构造最小证书：tbs{ [0]ver, serial, sigAlg, issuer, validity, subject, SPKI }
const uint8_t kMiniCert[] = {
    0x30, 0x1C,                                          // Certificate SEQUENCE（内容 28B）
    0x30, 0x15,                                          // tbs SEQUENCE（内容 21B）
    0xA0, 0x03, 0x02, 0x01, 0x02,                        // [0] version v3
    0x02, 0x01, 0x01,                                    // serial
    0x30, 0x00,                                          // sigAlg {}
    0x30, 0x00,                                          // issuer {}
    0x30, 0x00,                                          // validity {}
    0x30, 0x00,                                          // subject {}
    0x30, 0x03, 0x01, 0x02, 0x03,                        // SPKI（期望输出）
    0x30, 0x00,                                          // outer sigAlg {}
    0x03, 0x01, 0x00,                                    // signature BITSTRING
};
}

TEST_CASE(extractSpkiFromMiniCert)
{
    const std::string spki = extractSpkiDer(kMiniCert, sizeof(kMiniCert));
    const uint8_t expect[] = {0x30, 0x03, 0x01, 0x02, 0x03};
    CHECK(spki.size() == sizeof(expect));
    CHECK(std::memcmp(spki.data(), expect, sizeof(expect)) == 0);
}

TEST_CASE(extractSpkiGarbage)
{
    CHECK(extractSpkiDer(nullptr, 0).empty());
    const uint8_t junk[] = {0x31, 0x00};
    CHECK(extractSpkiDer(junk, sizeof(junk)).empty());
}

// —————— computeVerificationCode：KDE verificationKey 等价（跨端互操作锚点） ——————

TEST_CASE(verificationCodeVectors)
{
    // 期望值由 python hashlib 按**相同字节构造**预计算（sha256(a||b||ts) 前 4 字节 hex 大写，大者在前）
    std::string a2, b2;
    for (int i = 0; i < 65; ++i) a2.push_back(static_cast<char>((0x10 + i) & 0xFF));
    for (int i = 0; i < 9; ++i) b2.push_back(static_cast<char>((0x90 + i) & 0xFF));
    CHECK_EQ_STR(computeVerificationCode(a2, b2, 1700000000), "2E10F4A0");
    CHECK_EQ_STR(computeVerificationCode(b2, a2, 1700000000), "2E10F4A0");  // 参数无序性
    CHECK_EQ_STR(computeVerificationCode(a2, b2, 0), "B1AD1B69");           // v8 ts 追加
    CHECK_EQ_STR(computeVerificationCode(a2, a2, 1700000000), "DCE0E04F");  // 相等分支
    CHECK(computeVerificationCode("", b2, 1).empty());                       // 空输入
}

// —————— isPrivateIpv4：直连地址白名单边界（P1-1 回归） ——————

TEST_CASE(isPrivateIpv4Boundaries)
{
    struct Row {
        const char *host;
        bool expect;
    };
    static const Row rows[] = {
        // 私网/回环/链路本地
        {"10.0.0.1", true},        {"10.255.255.255", true},
        {"127.0.0.1", true},       {"192.168.1.10", true},
        {"169.254.1.1", true},
        // 172.16/12 边界（P1-1 曾把整段判为「非私网」）
        {"172.15.255.255", false}, {"172.16.0.0", true},
        {"172.16.0.1", true},      {"172.20.5.5", true},
        {"172.31.255.255", true},  {"172.32.0.0", false},
        // 公网与保留地址
        {"8.8.8.8", false},        {"1.1.1.1", false},
        {"0.0.0.0", false},        {"192.169.0.1", false},
        {"11.0.0.1", false},
        // 非法输入：段数不足/越界/尾随字符/空串
        {"1.2.3", false},          {"1.2.3.4.5", false},
        {"256.1.1.1", false},      {"1.2.3.4x", false},
        {"1.2.3.4 ", false},       {"", false},
        {"localhost", false},      {"::1", false},
    };
    for (const Row &r : rows) {
        if (isPrivateIpv4(r.host) != r.expect) {
            ++g_failed;
            std::fprintf(stderr, "FAIL %s:%d isPrivateIpv4('%s') != %d\n", __FILE__, __LINE__,
                         r.host, r.expect ? 1 : 0);
        }
    }
}

// —————— extractSubjectDnDer：server 端 client-auth 的 CA 名来源（P0-2） ——————

TEST_CASE(subjectDnFromCert)
{
    // 自签 EC 证书（CertGen 产出的正是 server 端要宣告的那种对端证书）
    const std::string id = "deadbeefdeadbeefdeadbeefdeadbeef";
    const CertPair pair = CertGen::generateSelfSignedEc(id, 10);
    const std::string der = pemToDer(pair.certPem, "CERTIFICATE");
    CHECK(!der.empty());

    const std::string dn = extractSubjectDnDer(reinterpret_cast<const uint8_t *>(der.data()),
                                               der.size());
    CHECK(!dn.empty());
    CHECK(static_cast<uint8_t>(dn[0]) == 0x30);  // DN 是 SEQUENCE
    // CN=deviceId 必须是 DN 的子串（DER 里 CN 以 UTF8String/PrintableString 出现）
    CHECK(dn.find(id) != std::string::npos);
    // SPKI 提取不受影响（同一行走的两条出口）
    CHECK(!extractSpkiDer(reinterpret_cast<const uint8_t *>(der.data()), der.size()).empty());
    // 垃圾输入
    const uint8_t junk[] = {0x31, 0x00};
    CHECK(extractSubjectDnDer(junk, sizeof(junk)).empty());
}

// —————— 证书有效期：闰日校正（评审 C2）——————

TEST_CASE(leapDaysBetweenYears)
{
    // 平年区间：2025→2026 无闰日
    CHECK(leapDaysBetween(2025, 1) == 0);
    // 2026→2036：2028/2032/2036 三年闰
    CHECK(leapDaysBetween(2026, 10) == 3);
    // 2027→2037：2028/2032/2036 三年闰
    CHECK(leapDaysBetween(2027, 10) == 3);
    // 世纪平年：2100 不是闰年 ⇒ 2099→2109 只有 2104/2108
    CHECK(leapDaysBetween(2099, 10) == 2);
    // 400 年整除：2000 是闰年
    CHECK(leapDaysBetween(1999, 1) == 1);
    // 十年证书的天数 = 365×10 + 闰日
    CHECK(365 * 10 + leapDaysBetween(2026, 10) == 3653);
}

// —————— PEM 往返（评审 S1/S2：统一到 cert_util 的 base64/pemToDer）——————

TEST_CASE(pemRoundTripUsesSharedImpl)
{
    const CertPair pair = CertGen::generateSelfSignedEc("feedfacefeedfacefeedfacefeedface", 10);
    // 证书与私钥都能被 cert_util 的 PEM→DER 解析（tls_engine 现在走同一条实现）
    const std::string certDer = pemToDer(pair.certPem, "CERTIFICATE");
    CHECK(!certDer.empty());
    const std::string keyDer = pemToDer(pair.keyPem, "EC PRIVATE KEY");
    CHECK(!keyDer.empty());
    // DER→PEM→DER 往返一致（base64 编解码共用同一实现）
    const std::string back =
        derToPem("CERTIFICATE", reinterpret_cast<const uint8_t *>(certDer.data()), certDer.size());
    CHECK(pemToDer(back, "CERTIFICATE") == certDer);
    // 标签不匹配时必须失败（防止误解析私钥/证书混用）
    CHECK(pemToDer(pair.certPem, "EC PRIVATE KEY").empty());
}


// —————— T1：NAPI 取参校验的纯判定层（AtomCode MSG112 T1；锁定代码评审 F1 的约定）——————
// 约定：字段缺失 或 类型不符 ⇒ 抛 TypeError；生产代码（net/napi_exports.cpp）直接调用本层，
// 故任何回退都会被下列用例立即拦下（文案逐字锁定）。

TEST_CASE(napiArgCheckTruthTable)
{
    struct Row { bool present; napiargs::ArgTag got; napiargs::ArgTag want; napiargs::ArgCheck expect; };
    const Row rows[] = {
        {false, napiargs::ArgTag::String,    napiargs::ArgTag::String, napiargs::ArgCheck::Missing},
        {true,  napiargs::ArgTag::Undefined, napiargs::ArgTag::String, napiargs::ArgCheck::WrongType},
        {true,  napiargs::ArgTag::Number,    napiargs::ArgTag::String, napiargs::ArgCheck::WrongType},
        {true,  napiargs::ArgTag::String,    napiargs::ArgTag::String, napiargs::ArgCheck::Ok},
        {true,  napiargs::ArgTag::Number,    napiargs::ArgTag::Number, napiargs::ArgCheck::Ok},
        {true,  napiargs::ArgTag::String,    napiargs::ArgTag::Number, napiargs::ArgCheck::WrongType},
    };
    for (const Row &r : rows) {
        CHECK(napiargs::checkArg(r.present, r.got, r.want) == r.expect);
    }
}

TEST_CASE(napiArgTypeErrorMessageLocked)
{
    // 逐字锁定：napi_exports.cpp 抛出的 TypeError 文本必须与此完全一致
    CHECK(napiargs::fieldTypeErrorText("deviceId", "string") ==
          "start(config): 'deviceId' 缺失或类型错误（需要 string）");
    // start(config) 的 5 个字符串字段 + 1 个数字字段：字段名与期望类型都必须出现在文案里
    const char *strFields[] = {"deviceId", "deviceName", "deviceType", "certPem", "keyPem"};
    for (const char *f : strFields) {
        const std::string msg = napiargs::fieldTypeErrorText(f, "string");
        CHECK(msg.find(f) != std::string::npos);
        CHECK(msg.find("需要 string") != std::string::npos);
    }
    const std::string port = napiargs::fieldTypeErrorText("tcpPort", "number");
    CHECK(port.find("tcpPort") != std::string::npos);
    CHECK(port.find("需要 number") != std::string::npos);
}


// —————— T3：事件桥契约（AtomCode MSG112 T3）——————
// ① 事件类型名数组 与 Index.d.ts 的 NetEventType 联合逐字一致（顺序即契约）；
// ② 事件对象字段名 与 NetEventBase 声明逐字一致（含双向检查：不许多、不许少）；
// ③ 事件队列深度：入队 +1、出队 -1 且下限收敛到 0（不可为负）。
// 生产代码（napi/napi_events.cpp）直接复用 napi_event_contract.h，故漂移会被立即拦下。

namespace {

std::string readContractDts()
{
    // 由当前工作目录逐级上溯查找（run.sh 可能从 tests/ 或构建目录运行二进制）
    const std::string rel = "types/libkdeconnect_napi/Index.d.ts";
    std::string up;
    for (int i = 0; i < 6; ++i) {
        std::ifstream f(up + rel);
        if (f) {
            return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        }
        up += "../";
    }
    return std::string();
}

// 取 [from, to) 之间的所有 "..." 内容（按出现顺序）
std::vector<std::string> quotedIn(const std::string &s, std::size_t from, std::size_t to)
{
    std::vector<std::string> out;
    for (std::size_t i = from; i < to; ++i) {
        if (s[i] != '"') {
            continue;
        }
        const std::size_t j = s.find('"', i + 1);
        if (j == std::string::npos || j > to) {
            break;
        }
        out.push_back(s.substr(i + 1, j - i - 1));
        i = j;
    }
    return out;
}

// 取接口体内每一行的「字段名」（形如 `  name?: type;` / `  name: type;`），跳过注释与空行
std::vector<std::string> interfaceFields(const std::string &body)
{
    std::vector<std::string> out;
    std::size_t p = 0;
    while (p <= body.size()) {
        std::size_t e = body.find('\n', p);
        std::string line = body.substr(p, (e == std::string::npos ? body.size() : e) - p);
        p = (e == std::string::npos) ? body.size() + 1 : e + 1;
        const std::size_t a = line.find_first_not_of(" \t\r");
        if (a == std::string::npos || line.compare(a, 2, "//") == 0) {
            continue;
        }
        std::size_t k = a;
        while (k < line.size() && (std::isalnum(static_cast<unsigned char>(line[k])) || line[k] == '_')) {
            ++k;
        }
        if (k > a) {
            out.push_back(line.substr(a, k - a));
        }
    }
    return out;
}

} // namespace

TEST_CASE(napiEventContractMatchesDts)
{
    const std::string dts = readContractDts();
    CHECK(!dts.empty());   // 找不到 d.ts 即失败（契约门禁不可静默跳过）

    // ① 类型名联合
    const std::size_t u0 = dts.find("export type NetEventType =");
    CHECK(u0 != std::string::npos);
    const std::size_t u1 = dts.find(';', u0);
    CHECK(u1 != std::string::npos);
    const std::vector<std::string> types = quotedIn(dts, u0, u1);
    CHECK(types.size() == napi_bridge::kEventTypeCount);
    // 集合必须一致（类型联合的顺序无语义，d.ts 里 payloadTransfer/error 的先后与枚举不同）…
    for (const std::string &n : types) {
        bool found = false;
        for (std::size_t i = 0; i < napi_bridge::kEventTypeCount; ++i) {
            if (n == napi_bridge::kEventTypeNames[i]) { found = true; break; }
        }
        CHECK(found);
    }
    // …而 C++ 数组的**下标顺序**必须与 EventType 枚举一致（桥用它按 event.type 取名字）。
    CHECK(napi_bridge::kEventTypeNames[static_cast<int>(EventType::DeviceDiscovered)] == std::string("deviceDiscovered"));
    CHECK(napi_bridge::kEventTypeNames[static_cast<int>(EventType::DeviceLost)] == std::string("deviceLost"));
    CHECK(napi_bridge::kEventTypeNames[static_cast<int>(EventType::Connected)] == std::string("connected"));
    CHECK(napi_bridge::kEventTypeNames[static_cast<int>(EventType::Disconnected)] == std::string("disconnected"));
    CHECK(napi_bridge::kEventTypeNames[static_cast<int>(EventType::PacketReceived)] == std::string("packetReceived"));
    CHECK(napi_bridge::kEventTypeNames[static_cast<int>(EventType::PairingRequest)] == std::string("pairingRequest"));
    CHECK(napi_bridge::kEventTypeNames[static_cast<int>(EventType::Error)] == std::string("error"));
    CHECK(napi_bridge::kEventTypeNames[static_cast<int>(EventType::PayloadTransfer)] == std::string("payloadTransfer"));

    // ② 字段名：双向一致
    const std::string ifaceDecl = "export interface NetEventBase {";
    const std::size_t i0 = dts.find(ifaceDecl);
    CHECK(i0 != std::string::npos);
    const std::size_t i1 = dts.find("\n}", i0);
    CHECK(i1 != std::string::npos);
    // 从声明行的大括号之后开始（否则 export/interface/NetEventBase 会被误当作字段名）
    const std::size_t bodyStart = i0 + ifaceDecl.size();
    const std::vector<std::string> fields = interfaceFields(dts.substr(bodyStart, i1 - bodyStart));
    CHECK(fields.size() == napi_bridge::kEventFieldCount);
    for (const std::string &f : fields) {
        // d.ts 声明了 → 必须被桥发出（否则 JS 侧拿到 undefined 而契约写着可选字段名）
        bool found = false;
        for (std::size_t i = 0; i < napi_bridge::kEventFieldCount; ++i) {
            if (f == napi_bridge::kEventFieldNames[i]) { found = true; break; }
        }
        CHECK(found);
    }
    for (std::size_t i = 0; i < napi_bridge::kEventFieldCount; ++i) {
        bool found = false;
        for (const std::string &f : fields) {
            if (f == napi_bridge::kEventFieldNames[i]) { found = true; break; }
        }
        CHECK(found);
    }

    // 字段名自检：历史错误名必须被判为非契约（REVIEW §4 P1-2 的 message/code 漂移）
    CHECK(napi_bridge::isCanonicalEventField("type"));
    CHECK(napi_bridge::isCanonicalEventField("deviceId"));
    CHECK(napi_bridge::isCanonicalEventField("payloadBytesDone"));
    CHECK(!napi_bridge::isCanonicalEventField("message"));
    CHECK(!napi_bridge::isCanonicalEventField("code"));
}

TEST_CASE(napiEventQueueDepthInvariant)
{
    // 起始归零（全局状态，测试前后保持 0）
    while (eventQueueDepth().load() > 0) {
        napi_bridge::eventDequeued();
    }
    CHECK(eventQueueDepth().load() == 0);

    napi_bridge::eventEnqueued();
    napi_bridge::eventEnqueued();
    napi_bridge::eventEnqueued();
    CHECK(eventQueueDepth().load() == 3);

    napi_bridge::eventDequeued();
    napi_bridge::eventDequeued();
    CHECK(eventQueueDepth().load() == 1);

    napi_bridge::eventDequeued();
    CHECK(eventQueueDepth().load() == 0);

    // 下限收敛：多减不得为负（CallJs 在 env/callback 为空时也会减一次）
    napi_bridge::eventDequeued();
    napi_bridge::eventDequeued();
    CHECK(eventQueueDepth().load() == 0);
}

int main()
{
    std::printf("native host tests: %d cases, %d failed\n", g_cases, g_failed);
    return g_failed == 0 ? 0 : 1;
}
