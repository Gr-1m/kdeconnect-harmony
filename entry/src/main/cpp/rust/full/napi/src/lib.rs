// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! ArkTS ↔ Rust NAPI 桥。
//!
//! 契约源：`entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts`（逐字对齐，
//! 函数名/事件名/字段名不得漂移）。事件通过 threadsafe function 投递到 ArkTS 主线程。

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::{Error, Function, Result, Status, Unknown};
use napi_ohos::threadsafe_function::{
    ThreadsafeCallContext, ThreadsafeFunction, ThreadsafeFunctionCallMode,
};

use kdc_native::events;
use kdc_native::stack;
use kdc_native::types::{EventType, NetConfig, NetEvent};

#[napi(object)]
pub struct NetConfigJs {
    pub device_id: String,
    pub device_name: String,
    pub device_type: String,
    pub cert_pem: String,
    pub key_pem: String,
    pub tcp_port: u16,
}

impl From<NetConfigJs> for NetConfig {
    fn from(value: NetConfigJs) -> Self {
        NetConfig {
            device_id: value.device_id,
            device_name: value.device_name,
            device_type: value.device_type,
            cert_pem: value.cert_pem,
            key_pem: value.key_pem,
            tcp_port: value.tcp_port,
            ..Default::default()
        }
    }
}

#[napi(object)]
pub struct CertPairJs {
    pub cert_pem: String,
    pub key_pem: String,
}

#[napi(object)]
pub struct NetEventJs {
    pub r#type: String,
    pub device_id: Option<String>,
    pub device_name: Option<String>,
    pub device_type: Option<String>,
    pub host: Option<String>,
    pub tcp_port: u16,
    pub role: Option<String>,
    pub packet: Option<String>,
    pub payload_transfer_id: i64,
    pub error_code: i32,
    pub error_message: Option<String>,
    pub payload_direction: Option<String>,
    pub payload_state: Option<String>,
    pub payload_size: i64,
    pub payload_bytes_done: i64,
    pub payload_file_name: Option<String>,
    pub payload_file_path: Option<String>,
}

fn opt(value: String) -> Option<String> {
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

impl From<NetEvent> for NetEventJs {
    fn from(ev: NetEvent) -> Self {
        let is_payload = ev.event_type == EventType::PayloadTransfer;
        let is_connected = ev.event_type == EventType::Connected;
        NetEventJs {
            r#type: ev.event_type.as_str().to_owned(),
            device_id: opt(ev.device_id),
            device_name: opt(ev.device_name),
            device_type: opt(ev.device_type),
            host: opt(ev.host),
            tcp_port: ev.tcp_port,
            role: if is_connected {
                Some(ev.role.as_str().to_owned())
            } else {
                None
            },
            packet: opt(ev.packet),
            payload_transfer_id: ev.payload_transfer_id as i64,
            error_code: ev.error_code,
            error_message: opt(ev.error_message),
            payload_direction: if is_payload {
                Some(
                    if ev.payload_direction_send {
                        "send"
                    } else {
                        "receive"
                    }
                    .to_owned(),
                )
            } else {
                None
            },
            payload_state: if is_payload {
                Some(ev.payload_state)
            } else {
                None
            },
            payload_size: ev.payload_size,
            payload_bytes_done: ev.payload_bytes_done,
            payload_file_name: if is_payload {
                opt(ev.payload_file_name)
            } else {
                None
            },
            payload_file_path: if is_payload {
                opt(ev.payload_file_path)
            } else {
                None
            },
        }
    }
}

/// `CalleeHandled=false`：ArkTS 回调只接收事件对象本身。
/// 若用默认的 `true`，napi-rs 会按 Node 的 `(err, value)` 约定把 `null` 当第一个参数，
/// ArkTS 的 `(event) => ...` 就会拿到 null（实测崩溃：`Cannot read property packet of null`）。
type EventTsfn = ThreadsafeFunction<NetEventJs, Unknown<'static>, NetEventJs, Status, false>;

static BRIDGE: LazyLock<Mutex<Option<EventTsfn>>> = LazyLock::new(|| Mutex::new(None));
static PENDING_CAPS: LazyLock<Mutex<Option<(Vec<String>, Vec<String>)>>> =
    LazyLock::new(|| Mutex::new(None));
static PENDING_TRUST: LazyLock<Mutex<HashMap<String, String>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn err(reason: &str) -> Error {
    Error::new(Status::GenericFailure, reason.to_owned())
}

#[napi]
pub fn init(callback: Function<'static>) -> Result<()> {
    let mut bridge = BRIDGE
        .lock()
        .map_err(|_| err("init: event bridge poisoned"))?;
    if bridge.is_some() {
        return Err(err("init: event bridge already initialized"));
    }
    let tsfn: EventTsfn = callback
        .build_threadsafe_function::<NetEventJs>()
        .callee_handled::<false>()
        .build_callback(|ctx: ThreadsafeCallContext<NetEventJs>| Ok(ctx.value))
        .map_err(|e| Error::new(Status::GenericFailure, format!("create tsfn: {e}")))?;
    *bridge = Some(tsfn);
    events::set_callback(Some(std::sync::Arc::new(|event: NetEvent| {
        if let Ok(bridge) = BRIDGE.lock() {
            if let Some(tsfn) = bridge.as_ref() {
                let _ = tsfn.call(NetEventJs::from(event), ThreadsafeFunctionCallMode::NonBlocking);
            }
        }
    })));
    Ok(())
}

#[napi]
pub fn shutdown() {
    events::set_callback(None);
    stack::stop_global();
    if let Ok(mut bridge) = BRIDGE.lock() {
        let _ = bridge.take();
    }
}

#[napi]
pub fn start(config: NetConfigJs) -> bool {
    let cfg: NetConfig = config.into();
    // 启动前回灌的 TrustStore / capabilities 必须在监听线程启动前生效（开屏期无竞态）。
    let trusted = PENDING_TRUST
        .lock()
        .map(|m| m.clone())
        .unwrap_or_default();
    let caps = PENDING_CAPS.lock().ok().and_then(|mut p| p.take());
    stack::start_global_with(cfg, trusted, caps)
}

#[napi]
pub fn stop() {
    stack::stop_global();
}

#[napi]
pub fn connect_to_peer(host: String, port: u16) {
    if let Some(stack) = stack::current() {
        stack.connect_to_peer(host, port);
    } else {
        kdc_native::events::emit_error("", "", port, libc::EINVAL, "net stack not started");
    }
}

#[napi]
pub fn send_packet(device_id: String, packet_json: String) -> bool {
    stack::current()
        .map(|stack| stack.send_packet(&device_id, &packet_json))
        .unwrap_or(false)
}

#[napi]
pub fn disconnect(device_id: String) {
    if let Some(stack) = stack::current() {
        stack.disconnect(&device_id);
    }
}

#[napi]
pub fn generate_cert(device_id: String) -> Result<CertPairJs> {
    let pair = kdc_native::cert_gen::generate_self_signed_ec(&device_id, 10)
        .map_err(|e| Error::new(Status::GenericFailure, e))?;
    Ok(CertPairJs {
        cert_pem: pair.cert_pem,
        key_pem: pair.key_pem,
    })
}

#[napi]
pub fn set_capabilities(incoming: Vec<String>, outgoing: Vec<String>) {
    if let Ok(mut pending) = PENDING_CAPS.lock() {
        *pending = Some((incoming.clone(), outgoing.clone()));
    }
    if let Some(stack) = stack::current() {
        stack.set_capabilities(incoming, outgoing);
    }
}

#[napi]
pub fn trigger_broadcast() {
    if let Some(stack) = stack::current() {
        stack.trigger_broadcast();
    }
}

#[napi]
pub fn send_payload(
    device_id: String,
    packet_type: String,
    body_json: String,
    file_path: String,
) -> i64 {
    stack::current()
        .map(|stack| stack.send_payload(&device_id, &packet_type, &body_json, &file_path) as i64)
        .unwrap_or(0)
}

#[napi]
pub fn keep_payload(transfer_id: i64, dest_path: String) -> bool {
    if transfer_id <= 0 {
        return false;
    }
    stack::current()
        .map(|stack| stack.keep_payload(transfer_id as u64, &dest_path))
        .unwrap_or(false)
}

#[napi]
pub fn discard_payload(transfer_id: i64) -> bool {
    if transfer_id <= 0 {
        return false;
    }
    stack::current()
        .map(|stack| stack.discard_payload(transfer_id as u64))
        .unwrap_or(false)
}

#[napi]
pub fn cancel_payload(transfer_id: i64) {
    if transfer_id > 0 {
        if let Some(stack) = stack::current() {
            stack.cancel_payload(transfer_id as u64);
        }
    }
}

#[napi]
pub fn get_peer_certificate(device_id: String) -> String {
    stack::current()
        .map(|stack| stack.get_peer_certificate(&device_id))
        .unwrap_or_default()
}

#[napi]
pub fn get_own_certificate() -> String {
    stack::current()
        .map(|stack| stack.get_own_certificate())
        .unwrap_or_default()
}

#[napi]
pub fn get_pair_verification_code(device_id: String, timestamp: i64) -> String {
    stack::current()
        .map(|stack| stack.get_pair_verification_code(&device_id, timestamp))
        .unwrap_or_default()
}

#[napi]
pub fn set_trusted_certificate(device_id: String, cert_pem: String) {
    if let Ok(mut trust) = PENDING_TRUST.lock() {
        trust.insert(device_id.clone(), cert_pem.clone());
    }
    if let Some(stack) = stack::current() {
        stack.set_trusted_certificate(&device_id, &cert_pem);
    }
}

#[napi]
pub fn remove_trusted_certificate(device_id: String) {
    if let Ok(mut trust) = PENDING_TRUST.lock() {
        trust.remove(&device_id);
    }
    if let Some(stack) = stack::current() {
        stack.remove_trusted_certificate(&device_id);
    }
}
