// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! 最小 X.509 辅助：从证书 DER 取 subject CN。
//!
//! KDE Connect 的协议硬约束是「身份 deviceId == 对端叶证书 CN」。rustls 只暴露
//! 证书 DER，不解析 CN，所以这里按 RFC 5280 走最小 TLV：
//! `Certificate → tbsCertificate → subject Name → RDN → AttributeTypeAndValue`。

/// 读取一个 DER TLV，返回 `(tag, value, rest)`；长度只支持短形与 1..=4 字节长形。
fn read_tlv(input: &[u8]) -> Option<(u8, &[u8], &[u8])> {
    let tag = *input.first()?;
    let len_byte = *input.get(1)?;
    let (len, header) = if len_byte & 0x80 == 0 {
        (len_byte as usize, 2usize)
    } else {
        let n = (len_byte & 0x7f) as usize;
        if n == 0 || n > 4 || input.len() < 2 + n {
            return None;
        }
        let mut len = 0usize;
        for &b in &input[2..2 + n] {
            len = len.checked_mul(256)?.checked_add(b as usize)?;
        }
        (len, 2 + n)
    };
    let end = header.checked_add(len)?;
    if end > input.len() {
        return None;
    }
    Some((tag, &input[header..end], &input[end..]))
}

fn expect_tlv<'a>(input: &'a [u8], want_tag: u8) -> Option<(&'a [u8], &'a [u8])> {
    let (tag, value, rest) = read_tlv(input)?;
    if tag != want_tag {
        return None;
    }
    Some((value, rest))
}

/// OID 2.5.4.3 (commonName) 的 DER 内容。
const OID_CN: &[u8] = &[0x55, 0x04, 0x03];

/// 从证书 DER 取 subject 的第一个 CN。空/非法证书 → None。
pub fn subject_cn_from_der(cert_der: &[u8]) -> Option<String> {
    // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
    let (cert_body, _) = expect_tlv(cert_der, 0x30)?;
    let (tbs, _) = expect_tlv(cert_body, 0x30)?;

    // tbsCertificate 字段序（version 可选）：
    // version [0], serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo, ...
    let mut rest = tbs;
    if rest.first().copied() == Some(0xA0) {
        let (_, _, after) = read_tlv(rest)?;
        rest = after;
    }
    let (_, after_serial) = expect_tlv(rest, 0x02)?;
    let (_, after_sig) = expect_tlv(after_serial, 0x30)?;
    let (_, after_issuer) = expect_tlv(after_sig, 0x30)?;
    let (_, after_validity) = expect_tlv(after_issuer, 0x30)?;
    let (subject, _) = expect_tlv(after_validity, 0x30)?;

    // subject = SEQUENCE OF RDN；RDN = SET OF AttributeTypeAndValue。
    let mut rdns = subject;
    while !rdns.is_empty() {
        let (set, after_rdn) = expect_tlv(rdns, 0x31)?;
        rdns = after_rdn;
        let mut attrs = set;
        while !attrs.is_empty() {
            let (attr, after_attr) = expect_tlv(attrs, 0x30)?;
            attrs = after_attr;
            let (oid, after_oid) = expect_tlv(attr, 0x06)?;
            if oid != OID_CN {
                continue;
            }
            let (tag, value, _) = read_tlv(after_oid)?;
            // 可打印类型：UTF8String(0x0C)、PrintableString(0x13)、IA5String(0x16)、BMPString(0x1E) 不处理。
            return match tag {
                0x0C | 0x13 | 0x16 => std::str::from_utf8(value).ok().map(|s| s.to_owned()),
                _ => None,
            };
        }
    }
    None
}

/// 从证书 DER 取 `(notBefore, notAfter)` 的 UTCTime 原文（`YYMMDDHHMMSSZ`）。
///
/// 仅用于测试/诊断：验证自签证书的有效期是日历语义（与 Android minusYears/plusYears 对齐）。
pub fn validity_from_der(cert_der: &[u8]) -> Option<(String, String)> {
    let (cert_body, _) = expect_tlv(cert_der, 0x30)?;
    let (tbs, _) = expect_tlv(cert_body, 0x30)?;

    let mut rest = tbs;
    if rest.first().copied() == Some(0xA0) {
        let (_, _, after) = read_tlv(rest)?;
        rest = after;
    }
    let (_, after_serial) = expect_tlv(rest, 0x02)?;
    let (_, after_sig) = expect_tlv(after_serial, 0x30)?;
    let (_, after_issuer) = expect_tlv(after_sig, 0x30)?;
    let (validity, _) = expect_tlv(after_issuer, 0x30)?;

    let (nb_tag, nb, after_nb) = read_tlv(validity)?;
    let (na_tag, na, _) = read_tlv(after_nb)?;
    if nb_tag != 0x17 || na_tag != 0x17 {
        return None; // 只处理 UTCTime（2050 前）
    }
    Some((
        String::from_utf8_lossy(nb).into_owned(),
        String::from_utf8_lossy(na).into_owned(),
    ))
}

/// 从 PEM 取第一个 CERTIFICATE 的 DER。
pub fn cert_der_from_pem(pem: &str) -> Vec<u8> {
    kdc_core::cert::pem_to_der(pem, "CERTIFICATE")
}

/// DER → 单证书 PEM。
pub fn cert_pem_from_der(der: &[u8]) -> String {
    kdc_core::cert::der_to_pem("CERTIFICATE", der)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_cn_from_generated_cert() {
        let pair = crate::cert_gen::generate_self_signed_ec("0123456789abcdef0123456789abcdef", 10)
            .expect("cert");
        let der = cert_der_from_pem(&pair.cert_pem);
        assert!(!der.is_empty());
        assert_eq!(
            subject_cn_from_der(&der).as_deref(),
            Some("0123456789abcdef0123456789abcdef")
        );
    }

    #[test]
    fn rejects_garbage() {
        assert_eq!(subject_cn_from_der(&[]), None);
        assert_eq!(subject_cn_from_der(&[0x30, 0x00]), None);
        assert_eq!(subject_cn_from_der(&[0xff; 16]), None);
    }
}
