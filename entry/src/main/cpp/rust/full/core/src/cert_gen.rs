// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! 自签 EC P-256 证书生成（`net/cert_gen.cpp` 的 Rust 等价）。
//!
//! 约束（三端一致）：CN 必须等于 deviceId；有效期 **-1 日历年 → +10 日历年**
//! （对齐 Android `minusYears(1)` / `plusYears(10)`，容忍设备间时钟偏差；
//! main `e896b0f` 已修 C++ 侧，本文件需逐字对齐语义）。
//! 私钥输出 PKCS#8 PEM；本栈自身用 rustls 解析，KDE/Android 只看到证书。

use rcgen::{CertificateParams, DistinguishedName, DnType, KeyPair, PKCS_ECDSA_P256_SHA256};
use time::OffsetDateTime;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CertPair {
    pub cert_pem: String,
    pub key_pem: String,
}

/// 按**日历年**平移（Java `plusYears/minusYears` 语义）：2 月 29 日遇到非闰年落到 2 月 28 日。
///
/// 不能用 `now ± days(365*years)`：跨闰年会差 1 天，且 2/29 生日会溢出。
/// C++/Android 与 KDE 的对端都按日历校验有效期，故这里必须用日历语义。
pub fn shift_calendar_years(at: OffsetDateTime, years: i32) -> OffsetDateTime {
    let target = at.year() + years;
    at.replace_year(target)
        .or_else(|_| at.replace_day(28).and_then(|d| d.replace_year(target)))
        .unwrap_or(at)
}

pub fn generate_self_signed_ec(device_id: &str, valid_years: i32) -> Result<CertPair, String> {
    generate_self_signed_ec_at(device_id, valid_years, OffsetDateTime::now_utc())
}

/// 可注入 `now` 的版本（测试用；生产走 [`generate_self_signed_ec`]）。
pub fn generate_self_signed_ec_at(
    device_id: &str,
    valid_years: i32,
    now: OffsetDateTime,
) -> Result<CertPair, String> {
    if device_id.is_empty() {
        return Err("deviceId is empty".to_owned());
    }
    let key = KeyPair::generate_for(&PKCS_ECDSA_P256_SHA256).map_err(|e| e.to_string())?;
    let mut params = CertificateParams::new(Vec::<String>::new()).map_err(|e| e.to_string())?;
    let mut dn = DistinguishedName::new();
    dn.push(DnType::CommonName, device_id);
    params.distinguished_name = dn;

    params.not_before = shift_calendar_years(now, -1);
    params.not_after = shift_calendar_years(now, valid_years.max(1));
    // 自签证书仅用于本协议的身份/密钥交换；不设 EKU，与既有 BearSSL 基线保持一致
    // （KDE/Android 也不要求 keyUsage/EKU）。

    let cert = params.self_signed(&key).map_err(|e| e.to_string())?;
    Ok(CertPair {
        cert_pem: cert.pem(),
        key_pem: key.serialize_pem(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cert_ext;
    use time::{Date, Month, PrimitiveDateTime};

    const ID: &str = "0123456789abcdef0123456789abcdef";

    fn utc(year: i32, month: Month, day: u8) -> OffsetDateTime {
        PrimitiveDateTime::new(
            Date::from_calendar_date(year, month, day).expect("valid date"),
            time::Time::MIDNIGHT,
        )
        .assume_utc()
    }

    #[test]
    fn shift_is_calendar_years() {
        let nov = utc(2026, Month::November, 7);
        assert_eq!(shift_calendar_years(nov, -1), utc(2025, Month::November, 7));
        assert_eq!(shift_calendar_years(nov, 10), utc(2036, Month::November, 7));

        // 闰日：minusYears/plusYears 落到 2/28（Java 语义）
        let leap = utc(2028, Month::February, 29);
        assert_eq!(shift_calendar_years(leap, -1), utc(2027, Month::February, 28));
        assert_eq!(shift_calendar_years(leap, 10), utc(2038, Month::February, 28));
    }

    #[test]
    fn generated_validity_matches_calendar_years() {
        let pair = generate_self_signed_ec_at(ID, 10, utc(2026, Month::November, 7)).unwrap();
        let der = cert_ext::cert_der_from_pem(&pair.cert_pem);
        let (not_before, not_after) = cert_ext::validity_from_der(&der).expect("validity");
        assert_eq!(not_before, "251107000000Z");
        assert_eq!(not_after, "361107000000Z");
    }

    #[test]
    fn leap_day_validity() {
        let pair = generate_self_signed_ec_at(ID, 10, utc(2028, Month::February, 29)).unwrap();
        let der = cert_ext::cert_der_from_pem(&pair.cert_pem);
        let (not_before, not_after) = cert_ext::validity_from_der(&der).expect("validity");
        assert_eq!(not_before, "270228000000Z");
        assert_eq!(not_after, "380228000000Z");
    }

    #[test]
    fn cert_cn_matches_device_id() {
        let pair = generate_self_signed_ec(ID, 10).unwrap();
        assert!(pair.cert_pem.starts_with("-----BEGIN CERTIFICATE-----"));
        assert!(pair.key_pem.starts_with("-----BEGIN PRIVATE KEY-----"));
        let der = cert_ext::cert_der_from_pem(&pair.cert_pem);
        assert_eq!(cert_ext::subject_cn_from_der(&der).as_deref(), Some(ID));
    }
}
