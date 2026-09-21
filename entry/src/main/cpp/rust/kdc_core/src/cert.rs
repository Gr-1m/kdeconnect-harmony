// SPDX-License-Identifier: GPL-2.0-or-later
//! `net/cert_util.cpp` 的逐函数等价 Rust 实现（R1 迁移，MSG93 §3）。
//!
//! 语义以现有 C++ 实现为唯一参照，逐行对齐：
//! - base64：标准字母表 `A-Za-z0-9+/` + `=` padding，手写实现（不用 base64 crate 的
//!   engine——`pemToDer` 的跳字符/容错语义与 `STANDARD` engine 并不一致，例如 C++ 允许
//!   body 内出现空白与 `=`，且对「非规范尾比特」不报错）。
//! - PEM：`derToPem` 每 64 字符一行 + 固定头尾；`pemToDer` 取**首个**匹配 label 段、
//!   跳过 `\n \r 空格 \t =`，遇非法字符即整体失败返回空。
//! - X.509：只走最小 ASN.1 TLV（`readTLV` 语义逐字对齐，长形长度允许 1..=4 字节），
//!   tbs 字段序 version([0],可选) serial sigAlg issuer validity subject spki，
//!   取第 5/第 6 个元素（i==4/5）且 tag 必须为 `0x30`。
//! - `computeVerificationCode`：双方 SPKI 按**字节序**排序（大者在前）+ `SHA256`，
//!   时间戳经 `to_string()` 十进制**无条件**追加（C++ 即如此；ts=0 追加 `"0"`），
//!   取摘要前 4 字节 hex 大写。
//!
//! 本文件为纯函数、无 FFI/`unsafe`；C ABI 垫片在 `ffi.rs`。

use sha2::{Digest, Sha256};

/// base64 标准字母表（与 C++ `kB64` 一致）。
const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// `base64Encode(data, len)`：标准字母表 + padding。
pub fn base64_encode(data: &[u8]) -> String {
    let len = data.len();
    let mut out = String::with_capacity((len + 2) / 3 * 4);
    let mut i = 0;
    while i + 3 <= len {
        let v = ((data[i] as u32) << 16) | ((data[i + 1] as u32) << 8) | data[i + 2] as u32;
        out.push(B64[((v >> 18) & 0x3F) as usize] as char);
        out.push(B64[((v >> 12) & 0x3F) as usize] as char);
        out.push(B64[((v >> 6) & 0x3F) as usize] as char);
        out.push(B64[(v & 0x3F) as usize] as char);
        i += 3;
    }
    if i + 1 == len {
        let v = (data[i] as u32) << 16;
        out.push(B64[((v >> 18) & 0x3F) as usize] as char);
        out.push(B64[((v >> 12) & 0x3F) as usize] as char);
        out.push('=');
        out.push('=');
    } else if i + 2 == len {
        let v = ((data[i] as u32) << 16) | ((data[i + 1] as u32) << 8);
        out.push(B64[((v >> 18) & 0x3F) as usize] as char);
        out.push(B64[((v >> 12) & 0x3F) as usize] as char);
        out.push(B64[((v >> 6) & 0x3F) as usize] as char);
        out.push('=');
    }
    out
}

/// `derToPem(label, der, len)`：`-----BEGIN <label>-----` / 每 64 字符换行 / `-----END <label>-----\n`。
pub fn der_to_pem(label: &str, der: &[u8]) -> String {
    let b64 = base64_encode(der);
    let mut out = String::with_capacity(b64.len() + label.len() * 2 + 40);
    out.push_str("-----BEGIN ");
    out.push_str(label);
    out.push_str("-----\n");
    let bytes = b64.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let n = std::cmp::min(64, bytes.len() - i);
        // b64 为纯 ASCII ⇒ i / i+n 必落在 char 边界上。
        out.push_str(&b64[i..i + n]);
        out.push('\n');
        i += 64;
    }
    out.push_str("-----END ");
    out.push_str(label);
    out.push_str("-----\n");
    out
}

/// `b64Val(c)`：合法 base64 字符 → 0..=63，否则 -1。
fn b64_val(c: u8) -> i32 {
    match c {
        b'A'..=b'Z' => (c - b'A') as i32,
        b'a'..=b'z' => (c - b'a') as i32 + 26,
        b'0'..=b'9' => (c - b'0') as i32 + 52,
        b'+' => 62,
        b'/' => 63,
        _ => -1,
    }
}

/// `pemToDer(pem, label)`：取首个匹配 label 段的 base64 body 解码；任何异常返回空 `Vec`。
pub fn pem_to_der(pem: &str, label: &str) -> Vec<u8> {
    let begin = format!("-----BEGIN {label}-----");
    let end = format!("-----END {label}-----");
    let start = match pem.find(&begin) {
        Some(i) => i + begin.len(),
        None => return Vec::new(),
    };
    // 与 C++ `pem.find(end, b)` 等价：
    let stop = match pem[start..].find(&end) {
        Some(i) => start + i,
        None => return Vec::new(),
    };
    let bytes = pem.as_bytes();
    let mut der = Vec::with_capacity((stop - start) / 4 * 3);
    let mut acc: u32 = 0;
    let mut bits: u32 = 0;
    for &c in &bytes[start..stop] {
        if c == b'\n' || c == b'\r' || c == b' ' || c == b'\t' || c == b'=' {
            continue; // '=' padding：长度可由位数推出，直接跳过
        }
        let v = b64_val(c);
        if v < 0 {
            return Vec::new();
        }
        acc = (acc << 6) | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            der.push(((acc >> bits) & 0xFF) as u8);
        }
    }
    der
}

/// 单个 TLV：`tag`、内容区间、以及含 tag+len 的完整元素区间。
struct Tlv<'a> {
    tag: u8,
    content: &'a [u8],
    elem: &'a [u8],
}

/// `readTLV`：读一个 TLV 并把 `pos` 推进到下一元素；任何越界/非法长度返回 `None`。
fn read_tlv<'a>(buf: &'a [u8], pos: &mut usize) -> Option<Tlv<'a>> {
    let end = buf.len();
    let mut p = *pos;
    if p + 2 > end {
        return None;
    }
    let elem_start = p;
    let tag = buf[p];
    p += 1;
    let first = buf[p];
    p += 1;
    let mut len = first as usize;
    if first & 0x80 != 0 {
        let n = (first & 0x7F) as usize;
        if n == 0 || n > 4 || p + n > end {
            return None;
        }
        len = 0;
        for _ in 0..n {
            len = (len << 8) | buf[p] as usize;
            p += 1;
        }
    }
    if p + len > end {
        return None;
    }
    let content = &buf[p..p + len];
    p += len;
    *pos = p;
    Some(Tlv {
        tag,
        content,
        elem: &buf[elem_start..p],
    })
}

/// `walkTbsFields` 的等价实现：返回 `(subject, spki)` 的完整元素 DER（含 tag+len）。
fn walk_tbs_fields(cert_der: &[u8]) -> Option<(&[u8], &[u8])> {
    // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
    let mut cert_pos = 0usize;
    let cert = read_tlv(cert_der, &mut cert_pos)?;
    if cert.tag != 0x30 {
        return None;
    }
    // tbsCertificate ::= SEQUENCE { ... }
    let mut tbs_pos = 0usize;
    let tbs = read_tlv(cert.content, &mut tbs_pos)?;
    if tbs.tag != 0x30 {
        return None;
    }
    let body = tbs.content;
    let mut q = 0usize;
    // 可选 [0] version
    if q < body.len() && body[q] == 0xA0 {
        read_tlv(body, &mut q)?;
    }
    // serial(0x02) → sigAlg(0x30) → issuer(0x30) → validity(0x30) → subject(0x30) → spki(0x30)
    let mut subject: Option<&[u8]> = None;
    let mut spki: Option<&[u8]> = None;
    for i in 0..6 {
        let t = read_tlv(body, &mut q)?;
        if i >= 4 {
            if t.tag != 0x30 {
                return None;
            }
            if i == 4 {
                subject = Some(t.elem);
            } else {
                spki = Some(t.elem);
            }
        }
    }
    Some((subject?, spki?))
}

/// `extractSpkiDer(certDer, len)`：失败返回空 `Vec`。
pub fn extract_spki_der(cert_der: &[u8]) -> Vec<u8> {
    match walk_tbs_fields(cert_der) {
        Some((_, spki)) => spki.to_vec(),
        None => Vec::new(),
    }
}

/// `extractSubjectDnDer(certDer, len)`：失败返回空 `Vec`。
pub fn extract_subject_dn_der(cert_der: &[u8]) -> Vec<u8> {
    match walk_tbs_fields(cert_der) {
        Some((subject, _)) => subject.to_vec(),
        None => Vec::new(),
    }
}

/// `computeVerificationCode(own, peer, ts)`：KDE `PairingHandler::verificationKey` 等价。
pub fn compute_verification_code(
    own_spki_der: &[u8],
    peer_spki_der: &[u8],
    pairing_timestamp: i64,
) -> String {
    if own_spki_der.is_empty() || peer_spki_der.is_empty() {
        return String::new();
    }
    // KDE：if (a < b) swap —— 大者在前（字节序比较）。
    let (a, b) = if own_spki_der < peer_spki_der {
        (peer_spki_der, own_spki_der)
    } else {
        (own_spki_der, peer_spki_der)
    };
    let ts = pairing_timestamp.to_string();
    let mut hasher = Sha256::new();
    hasher.update(a);
    hasher.update(b);
    hasher.update(ts.as_bytes());
    let digest = hasher.finalize();

    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(8);
    for byte in &digest[..4] {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0F) as usize] as char);
    }
    out
}

#[cfg(test)]
mod tests {
    //! 断言逐条移植自 `entry/src/main/cpp/tests/test_main.cpp`（行为对照）：
    //! `base64KnownVectors` / `pemDerRoundtrip` / `extractSpkiFromMiniCert` /
    //! `extractSpkiGarbage` / `verificationCodeVectors` / `subjectDnFromCert` /
    //! `pemRoundTripUsesSharedImpl`。
    //!
    //! 测试夹具来源（不入库的临时 C++ 程序 `/tmp/fixture_check.cpp`、`/tmp/golden_gen.cpp`
    //! 链接仓库内 `net/cert_util.cpp` 生成/校验；`MINI_CERT` 直接取自 test_main.cpp）：
    //! - `CN_CERT_DER`：确定性构造的自签证书（[0] version + 真实 CN=DeviceId 的 subject +
    //!   91B SPKI，外层用长形长度 0x81/0x82 路径）；
    //! - `NO_VERSION_CERT`：省略可选 [0] version 的最小证书；
    //! - `BAD_SUBJECT_TAG_CERT`：subject 位上是 `0x02`（必须失败）；
    //! - verification code 期望码：由真实 C++ `computeVerificationCode` 打印。
    use super::*;

    const MINI_DER: [u8; 5] = [0x30, 0x03, 0x01, 0x02, 0x03];

    // 手工构造最小证书：tbs{ [0]ver, serial, sigAlg, issuer, validity, subject, SPKI }
    // （逐字取自 tests/test_main.cpp 的 kMiniCert）
    const MINI_CERT: [u8; 30] = [
        0x30, 0x1C, // Certificate SEQUENCE（内容 28B）
        0x30, 0x15, // tbs SEQUENCE（内容 21B）
        0xA0, 0x03, 0x02, 0x01, 0x02, // [0] version v3
        0x02, 0x01, 0x01, // serial
        0x30, 0x00, // sigAlg {}
        0x30, 0x00, // issuer {}
        0x30, 0x00, // validity {}
        0x30, 0x00, // subject {}
        0x30, 0x03, 0x01, 0x02, 0x03, // SPKI（期望输出）
        0x30, 0x00, // outer sigAlg {}
        0x03, 0x01, 0x00, // signature BITSTRING
    ];

    // 省略 [0] version 的证书（同一行走的「无可选 version」分支）
    const NO_VERSION_CERT: [u8; 25] = [
        0x30, 0x17, 0x30, 0x10, 0x02, 0x01, 0x01, 0x30, 0x00, 0x30, 0x00, 0x30, 0x00, 0x30, 0x00,
        0x30, 0x03, 0x01, 0x02, 0x03, 0x30, 0x00, 0x03, 0x01, 0x00,
    ];

    // subject 位上是 0x02（非 SEQUENCE）⇒ 行走必须失败
    const BAD_SUBJECT_TAG_CERT: [u8; 20] = [
        0x30, 0x12, 0x30, 0x0B, 0x02, 0x01, 0x01, 0x30, 0x00, 0x30, 0x00, 0x30, 0x00, 0x02, 0x00,
        0x30, 0x00, 0x03, 0x01, 0x00,
    ];

    const CN_CERT_DER: [u8; 211] = [
        0x30, 0x81, 0xD0, 0x30, 0x81, 0xBE, 0xA0, 0x03, 0x02, 0x01, 0x02, 0x02, 0x01, 0x01, 0x30,
        0x0A, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02, 0x30, 0x00, 0x30, 0x1E,
        0x17, 0x0D, 0x32, 0x36, 0x30, 0x39, 0x31, 0x33, 0x31, 0x34, 0x30, 0x32, 0x35, 0x30, 0x5A,
        0x17, 0x0D, 0x33, 0x36, 0x30, 0x39, 0x31, 0x33, 0x31, 0x34, 0x30, 0x32, 0x35, 0x30, 0x5A,
        0x30, 0x2B, 0x31, 0x29, 0x30, 0x27, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0C, 0x20, 0x64, 0x65,
        0x61, 0x64, 0x62, 0x65, 0x65, 0x66, 0x64, 0x65, 0x61, 0x64, 0x62, 0x65, 0x65, 0x66, 0x64,
        0x65, 0x61, 0x64, 0x62, 0x65, 0x65, 0x66, 0x64, 0x65, 0x61, 0x64, 0x62, 0x65, 0x65, 0x66,
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08,
        0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04, 0x00, 0x01, 0x02,
        0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11,
        0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F,
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E,
        0x3F, 0x30, 0x0A, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02, 0x03, 0x01,
        0x00,
    ];

    const CN_CERT_SUBJECT: [u8; 45] = [
        0x30, 0x2B, 0x31, 0x29, 0x30, 0x27, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0C, 0x20, 0x64, 0x65,
        0x61, 0x64, 0x62, 0x65, 0x65, 0x66, 0x64, 0x65, 0x61, 0x64, 0x62, 0x65, 0x65, 0x66, 0x64,
        0x65, 0x61, 0x64, 0x62, 0x65, 0x65, 0x66, 0x64, 0x65, 0x61, 0x64, 0x62, 0x65, 0x65, 0x66,
    ];

    const CN_CERT_SPKI: [u8; 91] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08,
        0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04, 0x00, 0x01, 0x02,
        0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11,
        0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F,
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E,
        0x3F,
    ];

    const DEVICE_ID: &str = "deadbeefdeadbeefdeadbeefdeadbeef";

    // 与 C++ 用例同构的 SPKI 素材：65B 0x10.. / 9B 0x90.. / 32B 0x00.. / 48B 0xA5..
    fn spki_a65() -> Vec<u8> {
        (0..65u32).map(|i| ((0x10 + i) & 0xFF) as u8).collect()
    }
    fn spki_b9() -> Vec<u8> {
        (0..9u32).map(|i| ((0x90 + i) & 0xFF) as u8).collect()
    }
    fn spki_c32() -> Vec<u8> {
        (0..32u32).map(|i| i as u8).collect()
    }
    fn spki_d48() -> Vec<u8> {
        (0..48u32).map(|i| ((0xA5 + i) & 0xFF) as u8).collect()
    }

    // —————— base64 ——————

    #[test]
    fn base64_known_vectors() {
        assert_eq!(base64_encode(b"abc"), "YWJj");
        assert_eq!(base64_encode(b"ab"), "YWI=");
        assert_eq!(base64_encode(b"a"), "YQ==");
        // 字母表两端与空输入（C++ 对 len==0 返回空串）
        assert_eq!(base64_encode(&[0x00, 0x00, 0x00]), "AAAA");
        assert_eq!(base64_encode(&[0xFF, 0xFF, 0xFF]), "////");
        assert_eq!(base64_encode(&[0xFB, 0xEF, 0xBE]), "++++");
        assert_eq!(base64_encode(&[]), "");
    }

    // —————— PEM 往返 ——————

    #[test]
    fn pem_der_roundtrip() {
        let pem = der_to_pem("CERTIFICATE", &MINI_DER);
        assert!(pem.starts_with("-----BEGIN CERTIFICATE-----"));
        assert!(pem.ends_with("-----END CERTIFICATE-----\n"));
        let back = pem_to_der(&pem, "CERTIFICATE");
        assert_eq!(back, MINI_DER.to_vec());
        assert!(pem_to_der("garbage", "CERTIFICATE").is_empty());
    }

    #[test]
    fn pem_wrapping_and_tolerant_decode() {
        // 每 64 字符换行：211B → 284 个 base64 字符 → 4×64 + 28
        let pem = der_to_pem("CERTIFICATE", &CN_CERT_DER);
        let lines: Vec<&str> = pem.trim_end_matches('\n').split('\n').collect();
        assert_eq!(lines.len(), 7);
        assert_eq!(lines[0], "-----BEGIN CERTIFICATE-----");
        assert_eq!(lines[6], "-----END CERTIFICATE-----");
        assert_eq!(
            lines[1..6].iter().map(|l| l.len()).collect::<Vec<_>>(),
            vec![64, 64, 64, 64, 28]
        );
        assert_eq!(pem_to_der(&pem, "CERTIFICATE"), CN_CERT_DER.to_vec());

        // 手写 P E M 字面量：'=' padding、\r\n、行内空格、BEGIN 前有杂音、END 后有杂音
        // （C++ 语义：find 到 BEGIN/END 之间按字节扫，跳 '= \r \n 空格 \t'）
        let inline_pem =
            "junk\r\n-----BEGIN CERTIFICATE-----\r\n MAMBAgM= \r\n-----END CERTIFICATE-----\ntail";
        assert_eq!(pem_to_der(inline_pem, "CERTIFICATE"), MINI_DER.to_vec());
        // 空 body（无 padding 也无数据）
        assert!(pem_to_der(
            "-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n",
            "CERTIFICATE"
        )
        .is_empty());
    }

    #[test]
    fn pem_to_der_failure_paths() {
        let bad_char = "-----BEGIN CERTIFICATE-----\n@@@@\n-----END CERTIFICATE-----";
        assert!(pem_to_der(bad_char, "CERTIFICATE").is_empty());
        // 缺 END（C++ 在 b 之后找不到 end ⇒ 空）
        assert!(pem_to_der("-----BEGIN CERTIFICATE-----\nMAMBAgM=\n", "CERTIFICATE").is_empty());
        // 缺 BEGIN
        assert!(pem_to_der("MAMBAgM=", "CERTIFICATE").is_empty());
        // 大小写/标签不同 → 不匹配
        assert!(pem_to_der("-----BEGIN certificate-----\nMAMBAgM=\n-----END certificate-----", "CERTIFICATE").is_empty());
    }

    // —————— extractSpkiDer：最小 ASN.1 行走 ——————

    #[test]
    fn extract_spki_from_mini_cert() {
        let spki = extract_spki_der(&MINI_CERT);
        assert_eq!(spki, MINI_DER.to_vec());
        // 无 [0] version 的同构证书
        assert_eq!(extract_spki_der(&NO_VERSION_CERT), MINI_DER.to_vec());
        assert_eq!(extract_subject_dn_der(&NO_VERSION_CERT), vec![0x30, 0x00]);
    }

    #[test]
    fn extract_spki_garbage() {
        assert!(extract_spki_der(&[]).is_empty());
        assert!(extract_spki_der(&[0x31, 0x00]).is_empty());
        // subject 位上 tag != 0x30 ⇒ 失败
        assert!(extract_spki_der(&BAD_SUBJECT_TAG_CERT).is_empty());
        assert!(extract_subject_dn_der(&BAD_SUBJECT_TAG_CERT).is_empty());
        // 截断尾部（外层 TLV 声明长度超出缓冲区）
        assert!(extract_spki_der(&CN_CERT_DER[..CN_CERT_DER.len() - 1]).is_empty());
        // 长形长度非法：n==0（0x80 不定长）
        assert!(extract_spki_der(&[0x30, 0x80, 0x00]).is_empty());
    }

    // —————— computeVerificationCode：KDE verificationKey 等价 ——————

    #[test]
    fn verification_code_vectors() {
        let a2 = spki_a65();
        let b2 = spki_b9();
        // 期望值由真实 C++ computeVerificationCode 打印（temp 程序链接 net/cert_util.cpp）：
        // sha256(a||b||十进制 ts) 前 4 字节 hex 大写，字节序大者在前。
        assert_eq!(
            compute_verification_code(&a2, &b2, 1700000000),
            "2E10F4A0"
        );
        assert_eq!(
            compute_verification_code(&b2, &a2, 1700000000),
            "2E10F4A0" // 参数无序性
        );
        // v8：timestamp 无条件追加（C++ to_string(0) == "0"）
        assert_eq!(compute_verification_code(&a2, &b2, 0), "B1AD1B69");
        assert_eq!(
            compute_verification_code(&a2, &a2, 1700000000),
            "DCE0E04F" // 相等分支
        );
        assert!(compute_verification_code(&[], &b2, 1).is_empty()); // 空输入
    }

    #[test]
    fn verification_code_golden_extra() {
        // 额外 golden（本任务要求）：值与顺序无关性断言均取自 C++ 实现实际输出。
        let c32 = spki_c32();
        let d48 = spki_d48();
        // 带 timestamp
        assert_eq!(
            compute_verification_code(&c32, &d48, 1745000000),
            "D0223B99"
        );
        assert_eq!(
            compute_verification_code(&d48, &c32, 1745000000),
            "D0223B99"
        );
        // 不带 timestamp（ts<=0：C++ 仍追加十进制串 "0" / "-7"）
        assert_eq!(compute_verification_code(&c32, &d48, 0), "41F0A922");
        assert_eq!(compute_verification_code(&c32, &d48, -7), "CBC47CA2");
    }

    // —————— extractSubjectDnDer：server 端 client-auth 的 CA 名来源 ——————

    #[test]
    fn subject_dn_from_cert() {
        let dn = extract_subject_dn_der(&CN_CERT_DER);
        assert_eq!(dn, CN_CERT_SUBJECT.to_vec());
        assert_eq!(dn[0], 0x30); // DN 是 SEQUENCE
        // CN=deviceId 必须是 DN 的子串（DER 里 CN 以 UTF8String 出现）
        assert!(dn
            .windows(DEVICE_ID.len())
            .any(|w| w == DEVICE_ID.as_bytes()));
        // SPKI 提取不受影响（同一行走的两条出口）
        assert_eq!(extract_spki_der(&CN_CERT_DER), CN_CERT_SPKI.to_vec());
        // 垃圾输入
        assert!(extract_subject_dn_der(&[0x31, 0x00]).is_empty());
        assert!(extract_subject_dn_der(&[]).is_empty());
    }

    // —————— PEM 往返（统一到 cert_util 的 base64/pemToDer）—————

    #[test]
    fn pem_round_trip_uses_shared_impl() {
        let cert_der = CN_CERT_DER.to_vec();
        // 证书与私钥都能被 PEM→DER 解析（tls_engine 现在走同一条实现）
        let cert_pem = der_to_pem("CERTIFICATE", &cert_der);
        let cert_back = pem_to_der(&cert_pem, "CERTIFICATE");
        assert!(!cert_back.is_empty());
        let key_der: Vec<u8> = (0..51u32).map(|i| ((0x80 + i) & 0xFF) as u8).collect();
        let key_pem = der_to_pem("EC PRIVATE KEY", &key_der);
        let key_back = pem_to_der(&key_pem, "EC PRIVATE KEY");
        assert_eq!(key_back, key_der);
        // DER→PEM→DER 往返一致（base64 编解码共用同一实现）
        assert_eq!(pem_to_der(&der_to_pem("CERTIFICATE", &cert_der), "CERTIFICATE"), cert_der);
        // 标签不匹配时必须失败（防止误解析私钥/证书混用）
        assert!(pem_to_der(&cert_pem, "EC PRIVATE KEY").is_empty());
        assert!(pem_to_der(&key_pem, "CERTIFICATE").is_empty());
    }
}
