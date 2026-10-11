// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later

//! Crypto runtime test vectors (G2 validation) — 向量集 2026-10-11 固化，登记表见 devdocs/CRYPTO_VECTORS.md。
//! 期望值全部取自权威原文（RFC 7748 §5.2 / NIST FIPS 180-4 / 真实 C++ 打印）并经独立工具复算，
//! **不**来自 ring/Rust 自身（防"自己证明自己"）。

#[cfg(test)]
mod tests {
    use crate::cert::compute_verification_code;

    fn hex2bytes(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    // —— SAS 输入：真实 E2E 密钥对 SPKI DER（与 cert.rs T4 逐字节相同）——
    const SAS_A_SPKI: &str = "3059301306072a8648ce3d020106082a8648ce3d0301070342000488f63038e53859087a4a092f00d1f0f7eb082d7d2479bfa7dc1226a9a58ca84d9715365f20dbe8b11e5f4a5bf8d8dee881a4c16612bca9740c40fccb79f0efe1";
    const SAS_B_SPKI: &str = "3059301306072a8648ce3d020106082a8648ce3d03010703420004a5fdc7ce3f137c788a6450ff797a4444e116af1c55b3244a8ea14fe0738cbcf9cce0dc1b921641316635d0c191f62b06ab96d34b38de2840b5877b2a31bf6139";

    /// V1：SAS 金标·正确序（字节序大者在前，B > A），ts=1700000000
    #[test]
    fn sas_golden_vector_normal() {
        let a = hex2bytes(SAS_A_SPKI);
        let b = hex2bytes(SAS_B_SPKI);
        assert_eq!(compute_verification_code(&a, &b, 1_700_000_000), "A82E8F8A");
        assert_eq!(compute_verification_code(&b, &a, 1_700_000_000), "A82E8F8A"); // 参数无序性
    }

    /// V2：SAS 错序哨兵（A||B）——断言 !=，钉扎拼接顺序防回归
    #[test]
    fn sas_golden_vector_reversed() {
        let a = hex2bytes(SAS_A_SPKI);
        let b = hex2bytes(SAS_B_SPKI);
        assert_ne!(compute_verification_code(&a, &b, 1_700_000_000), "71A26CF5");
    }

    fn c32() -> Vec<u8> {
        (0..32u32).map(|i| i as u8).collect()
    }
    fn d48() -> Vec<u8> {
        (0..48u32).map(|i| ((0xA5 + i) & 0xFF) as u8).collect()
    }

    /// V3：R1 ts=1745000000（期望值取自真实 C++ 打印）
    #[test]
    fn sas_r1_vector_ts1745000000() {
        assert_eq!(compute_verification_code(&c32(), &d48(), 1_745_000_000), "D0223B99");
    }

    /// V4：R1 ts=0
    #[test]
    fn sas_r1_vector_ts0() {
        assert_eq!(compute_verification_code(&c32(), &d48(), 0), "41F0A922");
    }

    /// V5：R1 ts=-7（负数分支：追加十进制串 "-7"）
    #[test]
    fn sas_r1_vector_ts_negative7() {
        assert_eq!(compute_verification_code(&c32(), &d48(), -7), "CBC47CA2");
    }

    /// V6：SHA-256("abc")，NIST FIPS 180-4。ring 与 sha2 双实现互检，期望值为 NIST 原文。
    #[test]
    fn ring_sha256_vector() {
        const EXPECT: &[u8; 32] = &[
            0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde,
            0x5d, 0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
            0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
        ];
        let ring_out = ring::digest::digest(&ring::digest::SHA256, b"abc");
        assert_eq!(ring_out.as_ref(), EXPECT);
        use sha2::Digest;
        let mut h = sha2::Sha256::new();
        h.update(b"abc");
        assert_eq!(h.finalize().as_slice(), EXPECT);
    }

    /// V10：X25519 自洽性（ring 0.17 公共 API）。
    /// 验证：X25519 C 代码在目标平台可执行 + ladder 结构自洽（双向共享密钥相等、长度 32、非零）。
    /// 注：ring 0.16/0.17 公共 API 不提供固定密钥入口（sealed SecureRandom + EphemeralPrivateKey
    /// 为 by-value 单次使用），故 V7-V9（RFC 7748 §5.2 固定向量）无法在 ring 侧直接断言——
    /// 其值已经 cryptography 独立复算坐实（MATCH，见 CRYPTO_VECTORS.md 登记表），
    /// X25519 系统性正确性由 0.9.0 rustls TLS 1.3 端到端握手覆盖。
    #[test]
    fn ring_x25519_vector() {
        use ring::agreement::{self, UnparsedPublicKey};
        use ring::rand::SystemRandom;

        let rng = SystemRandom::new();
        let a = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &rng).unwrap();
        let b = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &rng).unwrap();
        let pub_a = a.compute_public_key().unwrap();
        let pub_b = b.compute_public_key().unwrap();

        // 每个私钥恰用一次（agree_ephemeral 的 by-value 签名强制单次使用）
        let s_ab = agreement::agree_ephemeral(
            a,
            &UnparsedPublicKey::new(&agreement::X25519, pub_b.as_ref()),
            |km| km.to_vec(),
        )
        .unwrap();
        let s_ba = agreement::agree_ephemeral(
            b,
            &UnparsedPublicKey::new(&agreement::X25519, pub_a.as_ref()),
            |km| km.to_vec(),
        )
        .unwrap();

        assert_eq!(s_ab.len(), 32);
        assert_eq!(s_ab, s_ba); // 对称性：X25519(k_a, pub_b) == X25519(k_b, pub_a)
        assert_ne!(s_ab, vec![0u8; 32]); // 非低阶点/无穷远点输出
    }
}
