// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! KDE Connect HarmonyOS native core（全 Rust 重写）。
//!
//! 分层：
//! - `packet` / `cert_ext` / `cert_gen` / `net_util`：纯函数（host 可测）；
//! - `tls`：rustls 配置与验证器；
//! - `discovery` / `connection` / `payload` / `stack`：网络状态机；
//! - NAPI 桥在独立 crate `kdeconnect_napi`，核心不依赖 Node-API。

#![deny(unsafe_op_in_unsafe_fn)]

pub mod cert_ext;
pub mod cert_gen;
pub mod connection;
pub mod discovery;
pub mod events;
pub mod log;
pub mod net_util;
pub mod packet;
pub mod payload;
pub mod stack;
pub mod state;
pub mod tls;
pub mod types;
