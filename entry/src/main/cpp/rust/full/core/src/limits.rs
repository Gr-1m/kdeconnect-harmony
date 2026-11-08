// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! 协议常量与防御限额的**唯一来源**（对齐 kdeconnect-oh `06 §2.1 limits.rs` 的组织约定）。
//!
//! 值必须三端一致：`kdeconnect-meta/schemas/`、`devdocs/CPP_GUIDE.md` §6、本仓 C++ 基线。
//! 改一处要核对三处；`dev/native-rust` 内的所有 `crate::types::<CONST>` 经 `types.rs`
//! 重导出，定义只在本文件出现。

pub const UDP_PORT: u16 = 1716;
pub const TCP_PORT_MIN: u16 = 1716;
pub const TCP_PORT_MAX: u16 = 1764;
pub const PAYLOAD_PORT_MIN: u16 = 1739;
pub const MAX_IDENTITY_PACKET_SIZE: usize = 8192;
pub const MAX_PACKET_SIZE: usize = 32 * 1024 * 1024;
pub const PROTOCOL_VERSION: i32 = 8;
pub const MAX_UNPAIRED_CONNECTIONS: usize = 42;
pub const LISTEN_BACKLOG: i32 = 42;
pub const IDENTITY_TIMEOUT_MS: u64 = 1000;
pub const PLAIN_IDENTITY_TIMEOUT_MS: u64 = 1000;
pub const CONNECT_HANDSHAKE_TIMEOUT_MS: u64 = 10_000;
pub const DISCOVERY_DEBOUNCE_MS: u64 = 500;
pub const DISCOVERY_DEDUP_EVENT_MS: u64 = 2000;
pub const DISCOVERY_TIMEOUT_MS: u64 = 60_000;
pub const DISCOVERY_BROADCAST_FAST_MS: u64 = 5_000;
pub const DISCOVERY_BROADCAST_FAST_COUNT: u32 = 5;
pub const DISCOVERY_LONG_INTERVAL_MS: u64 = 60_000;
pub const DISCOVERY_BROADCAST_WHILE_LINKED: bool = false;
/// 同设备重连限速：kdeconnect-oh `01 §5` 取桌面/iOS 的 **500ms**（Android 为 1000ms）。
pub const CONN_RATE_LIMIT_MS: u64 = 500;
pub const PORT_PROBE_TIMEOUT_MS: u64 = 500;
pub const MAX_TX_QUEUE_BYTES: usize = 8 * 1024 * 1024;
pub const LOOP_TICK_MS: u64 = 200;
pub const PAYLOAD_ACCEPT_TIMEOUT_MS: u64 = 30_000;
pub const PAYLOAD_CHUNK: usize = 16 * 1024;
pub const PAYLOAD_PROGRESS_INTERVAL_MS: u64 = 100;
pub const PAYLOAD_STALL_TIMEOUT_MS: u64 = 30_000;
pub const PAYLOAD_JOB_REAP_MS: u64 = 5_000;
pub const PAYLOAD_RECEIVE_KEEP_MS: u64 = 24 * 60 * 60 * 1000;
pub const PAYLOAD_SPOOL_DIR_DEFAULT: &str =
    "/data/storage/el2/base/haps/entry/cache/kdeconnect_payloads";
