// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! KDE Connect HarmonyOS native core（全 Rust 重写）。
//!
//! 分层：
//! - `packet` / `cert_ext` / `cert_gen` / `net_util`：纯函数（host 可测）；
//! - `tls`：rustls 配置与验证器；
//! - `discovery` / `connection` / `payload` / `stack`：网络状态机；
//! - NAPI 桥在独立 crate `kdeconnect_napi`，核心不依赖 Node-API。
//!
//! 不变式（改动前先改 `devdocs/FULL_RUST.md` / 规格文档）：
//!
//! - I1. 网络字节先过 `limits` 的长度/条数检查，再进入解析。
//! - I2. 未配对设备只接受 `kdeconnect.identity` / `kdeconnect.pair`，其余丢弃。
//! - I3. 连接设备身份（deviceId/CN 校验、钉扎）只由 `connection.rs` 写入，其他模块只读快照。
//! - I4. TLS 握手签名校验不得省略；自定义 verifier 只替换「信任谁」。
//! - I5. 验证码使用与 TLS 完全相同的对端 SPKI DER（`kdc_core::cert` 单一实现）。

#![deny(unsafe_op_in_unsafe_fn)]

pub mod cert_ext;
pub mod cert_gen;
pub mod connection;
pub mod discovery;
pub mod errors;
pub mod events;
pub mod limits;
pub mod log;
pub mod net_util;
pub mod packet;
pub mod payload;
pub mod stack;
pub mod state;
pub mod tls;
pub mod types;
