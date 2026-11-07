// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! 跨模块共享的类型与协议常量。
//!
//! 常量的唯一事实源是 `kdeconnect-meta/schemas/` 与 `devdocs/CPP_GUIDE.md` §6；
//! 数值必须与三端实现（KDE / Android / 本仓 C++ 基线）一致，改一处要核对三处。

use std::sync::Arc;

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
pub const CONN_RATE_LIMIT_MS: u64 = 300;
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

/// 对端 identity 的公开字段（`kdeconnect.identity` 的 `body`）。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DeviceInfo {
    pub device_id: String,
    pub device_name: String,
    pub device_type: String,
    pub host: String,
    pub tcp_port: u16,
}

/// `start(config)` 的输入（与 `Index.d.ts` 的 `NetConfig` 对齐）。
#[derive(Debug, Clone, Default)]
pub struct NetConfig {
    pub device_id: String,
    pub device_name: String,
    pub device_type: String,
    pub cert_pem: String,
    pub key_pem: String,
    pub tcp_port: u16,
    /// 0 = 默认 `UDP_PORT`（host 测试注入非标准端口）。
    pub udp_port: u16,
    /// 空 = 设备默认 cacheDir 路径。
    pub spool_dir: String,
    /// 0 = `CONNECT_HANDSHAKE_TIMEOUT_MS`。
    pub connect_handshake_timeout_ms: u64,
    /// 0 = `TCP_PORT_MIN` / `TCP_PORT_MAX`。
    pub port_probe_min: u16,
    pub port_probe_max: u16,
}

/// TLS 角色约定（KDE 强制）：拨号方 = TLS server，被拨方 = TLS client。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TlsRole {
    Server,
    Client,
}

impl TlsRole {
    pub fn as_str(self) -> &'static str {
        match self {
            TlsRole::Server => "server",
            TlsRole::Client => "client",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ConnectionState {
    #[default]
    Idle,
    PlainIdentity,
    TlsHandshake,
    Encrypted,
    Closing,
    Closed,
}

/// 事件类型；下标顺序是 NAPI 契约的一部分（见 `napi_event_contract.h`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum EventType {
    #[default]
    DeviceDiscovered,
    DeviceLost,
    Connected,
    Disconnected,
    PacketReceived,
    PairingRequest,
    Error,
    PayloadTransfer,
}

impl EventType {
    pub fn as_str(self) -> &'static str {
        match self {
            EventType::DeviceDiscovered => "deviceDiscovered",
            EventType::DeviceLost => "deviceLost",
            EventType::Connected => "connected",
            EventType::Disconnected => "disconnected",
            EventType::PacketReceived => "packetReceived",
            EventType::PairingRequest => "pairingRequest",
            EventType::Error => "error",
            EventType::PayloadTransfer => "payloadTransfer",
        }
    }
}

/// 事件对象是扁平结构：与字段无关的值留空（NAPI 侧转成 null）。
#[derive(Debug, Clone, Default)]
pub struct NetEvent {
    pub event_type: EventType,
    pub device_id: String,
    pub device_name: String,
    pub device_type: String,
    pub host: String,
    pub tcp_port: u16,
    pub role: TlsRole,
    pub packet: String,
    pub error_code: i32,
    pub error_message: String,
    pub payload_size: i64,
    pub payload_transfer_port: u16,
    pub payload_transfer_id: u64,
    pub payload_direction_send: bool,
    pub payload_state: String,
    pub payload_file_path: String,
    pub payload_file_name: String,
    pub payload_bytes_done: i64,
}

impl Default for TlsRole {
    fn default() -> Self {
        TlsRole::Client
    }
}

pub type EventCallback = Arc<dyn Fn(NetEvent) + Send + Sync + 'static>;

/// 用于日志/错误消息的 errno 文本。
pub fn errno_text(errno: i32) -> String {
    // SAFETY: `strerror` 返回进程内静态字符串，这里立即拷贝。
    unsafe {
        let ptr = libc::strerror(errno);
        if ptr.is_null() {
            return format!("errno {errno}");
        }
        std::ffi::CStr::from_ptr(ptr).to_string_lossy().into_owned()
    }
}
