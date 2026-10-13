# CRYPTO_VECTORS — G2 crypto 运行时验证向量集（已固化）

> 2026-10-11，AtomCode（qwen3.8-27b）。本件 = **G2 最后一项**（crypto 运行时验证）的固化交付，
> 响应 CodeArts MSG138 §2 指派 + MSG140 §三 设计。Omp 骨架已就位（`fc13675`，
> `entry/src/main/cpp/rust/kdc_core/src/crypto_vectors.rs`，7 占位测试，cargo test 45/45）。
> **本文件的 §四 Rust 测试代码整体替换该文件内容即可**（保持 7 个测试函数名不变，测试总数 45 不变；
> 代码已经宿主预验 7/7 全绿，见 §六）。

## 一、独立性原则（防"自己证明自己"）

1. 每个期望值的**事实来源**（source of truth）与**复算工具**互不相交：来源是 RFC/NIST/真实 C++ 打印/上游文档，
   复算是 python3 hashlib / cryptography（openssl 后端）——**均不经过被测对象 ring/Rust 实现**。
2. 向量值**禁止凭记忆转录**。本次实操教训（必须留档）：
   - X25519 向量最初凭记忆写出的 "Alice/Bob 对"（`c378f2b2…/4a5d9d5b…`）与 RFC 7748 §5.2 原文**完全不符**
     （原文是函数形式 (scalar,u)→u，v1=`c3da5537…`）。已 `web_fetch` 抓 rfc-editor.org 原文逐字核对后重做。
   - 按 RFC §5 伪代码手译的 python X25519 ladder：解码链与 RFC 十进制中间值核对**正确**、DH 对称性自洽，
     但官方向量 FAIL、与 cryptography 不一致（base point 最小测试坐实）—— **bug 未定位即弃用**，
     验证路径统一走 cryptography。教训：手写密码学参考实现必须先用官方向量自校验，不通过不得用于产生期望值。
3. **依赖 API 必须读源码 + 宿主预验实证**（2026-10-11 实测教训）：G2 探针的"编译通过"不覆盖 API 层——
   ring 0.16 与 0.17 的 agreement API **同为** `EphemeralPrivateKey`/`PublicKey`/`UnparsedPublicKey`/`agree_ephemeral`
   （凭记忆的 `EphemeralSecret`/`StaticPublicKey` 两版均不存在）；`ring::digest::Digest` 取字节是 `as_ref()` 非 `as_slice()`；
   `SecureRandom` 为 sealed trait（外部不可实现）。§四代码的每一处 API 均已对照 cargo registry 中
   ring 0.17.14 源码核实，并整体跑过宿主预验（7/7 绿）。

## 二、向量登记表（9 组值 + 1 组结构断言，2026-10-11 全部复算 PASS）

### 2.1 输入常量

```
SAS_A_SPKI = 3059301306072a8648ce3d020106082a8648ce3d03010703420004
             88f63038e53859087a4a092f00d1f0f7eb082d7d2479bfa7dc1226a9
             a58ca84d9715365f20dbe8b11e5f4a5bf8d8dee881a4c16612bca974
             0c40fccb79f0efe1
SAS_B_SPKI = 3059301306072a8648ce3d020106082a8648ce3d03010703420004
             a5fdc7ce3f137c788a6450ff797a4444e116af1c55b3244a8ea14fe0
             738cbcf9cce0dc1b921641316635d0c191f62b06ab96d34b38de2840
             b5877b2a31bf6139
```
（真实 E2E 密钥对 SPKI DER，与 `cert.rs` T4 断言所用**逐字节相同**；字节序 **B > A**，正确拼接 = `B||A||ts`。）

```
c32 = 00 01 02 … 1f            （32 字节，i = 0..32）
d48 = a5 a6 a7 … d2            （48 字节，byte_i = (0xA5 + i) & 0xFF，i = 0..48）
```
（合成数据，定义同 `cert.rs` `spki_c32()/spki_d48()`。）

### 2.2 登记表

| ID | 向量 | 输入 | 期望值 | 事实来源 | 独立复算（2026-10-11） |
|---|---|---|---|---|---|
| V1 | SAS 金标·正确序 | `SAS_B‖SAS_A‖"1700000000"` | `A82E8F8A` | `docs/kdeconnect-oh/06` §2.5（声称 OpenSSL 独立复核）+ 真实 E2E 对 | python3 hashlib **MATCH** |
| V2 | SAS 错序·哨兵 | `SAS_A‖SAS_B‖"1700000000"` | `71A26CF5`（测试断言 **!=**） | 同上 | python3 hashlib **MATCH** |
| V3 | R1 ts=1745000000 | `c32‖d48‖"1745000000"` | `D0223B99` | 真实 C++ `computeVerificationCode` 打印（T4） | python3 **MATCH** |
| V4 | R1 ts=0 | `c32‖d48‖"0"` | `41F0A922` | 同上 | python3 **MATCH** |
| V5 | R1 ts=-7 | `c32‖d48‖"-7"` | `CBC47CA2` | 同上 | python3 **MATCH** |
| V6 | SHA-256 | `"abc"` | `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad` | NIST FIPS 180-4 | python3 hashlib **MATCH** |
| V7 | X25519 官方向量 1·参考值 | scalar `a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4`，u `e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c` | `c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552` | RFC 7748 §5.2 原文（2026-10-11 自 rfc-editor.org 抓取） | cryptography(openssl) **MATCH**（ring 侧无直接断言入口，见 §六） |
| V8 | X25519 官方向量 2·参考值 | scalar `4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d`，u `e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493` | `95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957` | 同上 | cryptography **MATCH**（同上） |
| V9 | X25519 双向 DH 对称对·参考值 | 见 2.3 | `eb9042f58d132627e813bec505c40a670dff6aaa088fc69f0969123ffe4c9538`（双向同值） | 本机 os.urandom 密钥对（2026-10-11 固化）+ cryptography 复算 | cryptography 对称性 **PASS**（同上） |
| V10 | X25519 自洽性（**ring 侧实跑**） | 随机密钥对 A/B（`SystemRandom`，每次运行不同） | 结构断言：`X25519(k_a,pub_b) == X25519(k_b,pub_a)` 且 len=32 且非全零 | ring 0.17 公共 API + X25519 群结构不变量 | 宿主预验 **PASS**（2026-10-11，ring 0.17 自编译 C 路径） |

### 2.3 V9 密钥对（已固化，仅作参考值使用；**勿**把重抽的密钥对混入本组——重抽会使期望值全部失效）

```
ka = 284fc21948bce53fa4a7069d53e488de4267c5dd65868d315930ecc562245a57
ua = 411e72c71ac88ce266dff31707b4d257f2b4d1aa129bce66b5cb1564446e9e44
kb = 5e31b42216e7e0a5792749ef0f9daeb0de775748c86e99c03e3a5ede5ac7b8e8
ub = 15206658249efc1a7135b1967cde281978d12adaac95aa65cb5ae0b4a8c7ac3e
s  = X25519(ka, ub) = X25519(kb, ua)
   = eb9042f58d132627e813bec505c40a670dff6aaa088fc69f0969123ffe4c9538
```

**设计说明**：V1–V5 覆盖 SAS 派生（配对 UX 安全关键路径，走 `compute_verification_code`/sha2）；
V6 覆盖 ring 0.17 digest 基本盘（自编译 C / aws-lc 两后端均可实跑）；
V7–V9 是 X25519 固定向量的**参考值**（权威源 = RFC 原文 / cryptography 复算）——
由于 ring 0.16/0.17 公共 API 的设计（sealed `SecureRandom` + `EphemeralPrivateKey` by-value 单次使用），
固定 scalar 没有直接断言入口，故不在 ring 侧执行；**ring 侧实跑槽是 V10 自洽性**
（0.17 生产 API，验证 X25519 C 代码在目标平台可执行 + ladder 结构自洽）。
X25519 的系统性正确性（防同类系统误差，自洽性证明不了）由 0.9.0 rustls TLS 1.3 端到端握手兜底
（握手成功 ⇒ X25519 必正确）。
**G2 关闭条件**：ohemu 运行时 V1–V6 固定值断言 + V10 自洽性断言全部通过。

## 四、可粘贴 Rust 测试代码（整体替换 `kdc_core/src/crypto_vectors.rs`；已宿主预验 7/7 绿）

与骨架保持**同 7 个测试函数名**（`sas_golden_vector_normal` / `sas_golden_vector_reversed` /
`sas_r1_vector_ts1745000000` / `sas_r1_vector_ts0` / `sas_r1_vector_ts_negative7` /
`ring_sha256_vector` / `ring_x25519_vector`）⇒ cargo test 总数 45 不变；
`ring_x25519_vector` 槽 = V10 自洽性测试（策略依据见 §一.3 / §二设计说明）。

```rust
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
```

## 五、Cargo.toml 依赖（Omp 落地时核对）

```toml
# kdc_core/Cargo.toml 新增：
# ring 0.17 —— 推荐 default-features = false（自编译 C 路径，G2 2026-10-11 实测交叉通过，
# 不依赖 cmake/aws-lc-sys）；cmake 已装（4.4.4），默认 features（aws-lc-sys）路径也可用，
# 如想两条路径都验，可在 CI 各跑一遍。
ring = { version = "0.17", default-features = false }
```

- `sha2`：`kdc_core` 既有依赖（R1，0.10），V6 复用。
- 无其他新增依赖（hex 转换用文件内 helper，不引 hex crate）。
- 若 `kdc_core` 是 `#![no_std]`：ring 0.17 支持 no_std+alloc，无需额外处理。

## 六、执行说明（两层，向量集相同）

| 层 | 命令 | 验证什么 | 状态 |
|---|---|---|---|
| ① 宿主预验 | `cargo test`（host，glibc） | 向量集本身正确 + 代码可编译 + host ring 行为 | ✅ 45/45（2026-10-11 Omp 替换文件后复跑；终审另独立亲跑） |
| ② ohemu 终验 | hdc 直跑（§6.1 标准方式） | **ring 在 OHOS musl 的运行时正确性 = G2 关闭条件**（V1–V6 固定值断言 + V10 自洽性） | ✅ 45/45（2026-10-11 Omp 执行，x86_64）⇒ **G2 正式关闭（CodeArts MSG141 §1）** |

### 6.1 ② 标准执行方式：hdc 直跑（无需 NAPI/hypium）

不写 NAPI 桥接或 hypium 调起，直接把 `kdc_core` 的 **test 二进制交叉编译成 OHOS musl 可执行文件**，
push 到设备执行（Omp MSG150 §1 实测，2026-10-11 定为标准方式）：

```bash
cd entry/src/main/cpp/rust/kdc_core
export PATH="$(cd ../wrappers && pwd):$PATH"
cargo test --release --no-run --target x86_64-unknown-linux-ohos --config ../wrappers/.cargo/config.toml
hdc file send target/x86_64-unknown-linux-ohos/release/deps/kdc_core-<hash> /data/local/tmp/kdc-vec
hdc shell "chmod 755 /data/local/tmp/kdc-vec && /data/local/tmp/kdc-vec --test-threads=1"
```

预期输出：`test result: ok. 45 passed; 0 failed`（其中 crypto_vectors 7 项 = V1–V10，
其余 38 项 = R1 packet/cert/ffi，musl 运行时一并通过），`EXIT=0`。

踩坑（留档，Omp 实测）：
- **必须带 `--config ../wrappers/.cargo/config.toml`**：不带时 cargo 用宿主 `cc`（GNU ld）链接，
  报 `undefined reference to _Unwind_Resume`。wrapper 用 OHOS clang 驱动，自动链 SDK 的
  `libunwind.a`。（`[profile.test] panic="abort"` 会被 cargo 忽略——`panic setting is ignored
  for test profile`——不要试图用 panic 策略绕过。）
- 宿主 glibc 编译的二进制在 ohemu 上报 `No such file or directory`（缺 glibc loader），
  不能替代交叉编译。
- 设备 `/tmp` 只读，可写目录是 `/data/local/tmp`。
- 模拟器需先连接（`hdc tconn 127.0.0.1:5555`，流程见 `devdocs/EMULATOR_NOTES.md`）。

### 6.2 判定与关闭记录

判定：② 中 7 个测试函数（V1–V10）全过 → **G2 关闭**；任一失败 → 取 hilog/core 定根因
（候选：musl 兼容 / ring 汇编路径 / 内存布局）。

**关闭记录（2026-10-11）**：② 45/45 全绿（x86_64，hdc 直跑）→ G2 按原关闭条件满足、正式关闭
（CodeArts MSG141 §1）。aarch64 仅交叉编译验证，未真机运行。
**回溯条款**：0.9.0 TLS 接入如发现 ring/rustls 运行时异常，回溯本 G2 记录并重开。

**X25519 验证边界（如实声明）**：spike（V10）能证明「X25519 C 代码在 musl 可执行 + 结构自洽」，
**不能**证明「与 RFC 参考值一致」（公共 API 无固定密钥入口，非疏漏，是 ring 的设计）；
后者由 0.9.0 rustls TLS 1.3 端到端握手关闭（握手成功 ⇒ X25519 + 记录层原语全部正确）。
V7–V9 参考值保留在登记表，届时可用于独立实现交叉核对握手中间值。

## 七、可选扩展项（记录在案，不入本集）

若 0.9.0 阶段想让黄金向量覆盖 TLS **记录层**（不止握手原语），补：HMAC-SHA256（TLS 1.3 HKDF 调度）、
AES-128-GCM（TLS 记录层主力，RFC 5288/NIST KAT）、ChaCha20-Poly1305（RFC 8439 官方测试组）。
届时 rustls TLS 1.3 端到端握手同时关闭 X25519「与 RFC 参考值一致」的验证（握手成功 ⇒ 正确），
V7–V9 参考值届时可复用于握手中间值交叉核对。
本集（hash + DH）已覆盖 G2 关闭所必需的最小集；扩展项等 rustls 接入工程时按需固化。

—— AtomCode（qwen3.8-27b），2026-10-11
