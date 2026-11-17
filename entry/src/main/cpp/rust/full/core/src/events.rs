// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! 事件出口：网络栈 → NAPI 桥的唯一通道。
//!
//! 网络线程只调用 [`emit`]，回调由 NAPI 层注册（TSFN 投递到 ArkTS 主线程）。
//! 这里不做去重/节流；发现去重与事件普查在 [`crate::stack`] 内完成。

use crate::types::{EventCallback, EventType, NetEvent};
use std::sync::{Arc, LazyLock, Mutex};

static CALLBACK: LazyLock<Mutex<Option<EventCallback>>> = LazyLock::new(|| Mutex::new(None));

/// 冻结契约 `setOnEvent(kind, eventJson)` 的 kind 通道（阶段 B · B-1 依赖）。
pub type KindCallback = Arc<dyn Fn(i32, String) + Send + Sync + 'static>;
static KIND_CALLBACK: LazyLock<Mutex<Option<KindCallback>>> = LazyLock::new(|| Mutex::new(None));

pub fn set_callback(cb: Option<EventCallback>) {
    if let Ok(mut guard) = CALLBACK.lock() {
        *guard = cb;
    }
}

/// 注册 kind 通道回调（`setOnEvent`；契约要求 `start()` 之前注册）。
pub fn set_kind_callback(cb: Option<KindCallback>) {
    if let Ok(mut guard) = KIND_CALLBACK.lock() {
        *guard = cb;
    }
}

/// 内部事件 → 冻结 `EventKind`（`contract/kcbridge.d.ts` 的 15 项）。
///
/// ⚠️ 契约缺口（已上报，待裁决）：`Connected` / `Disconnected` / `Error` **在 15 个 kind 中没有对应项**
/// ⇒ 本函数对它们返回 `None`，这些事件继续走类型化通道（`init(cb(NetEvent))`），
/// 避免「有 kind 就丢类型化信息」或有损折叠。裁决后（建议只增 kind 15/16/17）在此补 3 行。
pub fn kind_of(event: &NetEvent) -> Option<i32> {
    match event.event_type {
        EventType::DeviceDiscovered => Some(3), // DeviceVisible
        EventType::DeviceLost => Some(4),       // DeviceGone
        EventType::PairingRequest => Some(7),   // PairRequest
        EventType::PacketReceived => Some(9),   // Packet
        EventType::PayloadTransfer => match event.payload_state.as_str() {
            "started" => Some(10),                           // TransferStarted
            "progress" => Some(12),                          // TransferProgress
            "finished" | "failed" | "cancelled" => Some(13), // TransferDone（状态在 JSON 里）
            _ => None,
        },
        EventType::Connected | EventType::Disconnected | EventType::Error => None,
    }
}

/// 冻结契约里 kind 的稳定名单（用于测试与文档；与 `kcbridge.d.ts` 的 `EventKind` 对齐）。
pub const EVENT_KIND_NAMES: [(i32, &str); 15] = [
    (0, "EngineStarted"),
    (1, "EngineInitFailed"),
    (2, "EngineStopped"),
    (3, "DeviceVisible"),
    (4, "DeviceGone"),
    (5, "DeviceUpdated"),
    (6, "Unpaired"),
    (7, "PairRequest"),
    (8, "PairResult"),
    (9, "Packet"),
    (10, "TransferStarted"),
    (11, "TransferOffer"),
    (12, "TransferProgress"),
    (13, "TransferDone"),
    (14, "Log"),
];

pub fn emit(event: NetEvent) {
    let cb = CALLBACK.lock().ok().and_then(|g| g.clone());
    if let Some(cb) = cb {
        cb(event.clone());
    }
    if let Some(kind) = kind_of(&event) {
        let kind_cb = KIND_CALLBACK.lock().ok().and_then(|g| g.clone());
        if let Some(kind_cb) = kind_cb {
            kind_cb(kind, crate::events::event_json(&event));
        }
    }
}

/// 事件的 JSON 形态（字段与桥层 `NetEvent` 一致）——由 NAPI 层复用其对象形态序列化，这里只留给测试断言用。
pub fn event_json(event: &NetEvent) -> String {
    crate::types::net_event_json(event)
}

/// 统一错误事件：`errorCode` 使用 **kcbridge 错误码**（`contract/errors.v1.json`，见 `crate::errors`）。
pub fn emit_error(device_id: &str, host: &str, port: u16, code: i32, message: &str) {
    emit(NetEvent {
        event_type: crate::types::EventType::Error,
        device_id: device_id.to_owned(),
        host: host.to_owned(),
        tcp_port: port,
        error_code: code,
        error_message: message.to_owned(),
        ..Default::default()
    });
}

/// 出向连接失败（kcbridge 码，无 OS errno 细节）：UI 可直接提示「连接失败/对端无响应」。
pub fn emit_connect_error(host: &str, port: u16, code: i32, stage: &str) {
    crate::logw!("connect error {host}:{port} code={code} stage={stage}");
    emit_error("", host, port, code, &format!("{stage} ({host}:{port})"));
}

/// 出向连接失败（带 OS errno 细节，便于诊断；`code` 仍为 kcbridge 码）。
pub fn emit_connect_error_os(host: &str, port: u16, code: i32, stage: &str, errno: i32) {
    crate::logw!(
        "connect error {host}:{port} code={code} stage={stage} os_errno={errno} ({})",
        crate::types::errno_text(errno)
    );
    emit_error(
        "",
        host,
        port,
        code,
        &format!(
            "{stage} ({host}:{port}): {}",
            crate::types::errno_text(errno)
        ),
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::TlsRole;

    fn ev(kind: EventType) -> NetEvent {
        NetEvent {
            event_type: kind,
            ..Default::default()
        }
    }

    #[test]
    fn kind_table_matches_frozen_eventkind() {
        assert_eq!(
            EVENT_KIND_NAMES.len(),
            15,
            "冻结 EventKind 为 15 项（0–14）"
        );
        let mut codes: Vec<i32> = EVENT_KIND_NAMES.iter().map(|(k, _)| *k).collect();
        codes.sort_unstable();
        assert_eq!(codes, (0..=14).collect::<Vec<i32>>());
        assert_eq!(kind_of(&ev(EventType::DeviceDiscovered)), Some(3));
        assert_eq!(kind_of(&ev(EventType::DeviceLost)), Some(4));
        assert_eq!(kind_of(&ev(EventType::PairingRequest)), Some(7));
        assert_eq!(kind_of(&ev(EventType::PacketReceived)), Some(9));
    }

    #[test]
    fn payload_states_fold_into_transfer_kinds() {
        for (state, kind) in [
            ("started", 10),
            ("progress", 12),
            ("finished", 13),
            ("failed", 13),
            ("cancelled", 13),
        ] {
            let mut e = ev(EventType::PayloadTransfer);
            e.payload_state = state.to_owned();
            assert_eq!(kind_of(&e), Some(kind), "state={state}");
        }
        let mut odd = ev(EventType::PayloadTransfer);
        odd.payload_state = "unknown-state".to_owned();
        assert_eq!(kind_of(&odd), None, "未知 payload 状态不得映射到 kind");
    }

    #[test]
    fn kinds_absent_for_connected_disconnected_error() {
        // 契约缺口（已上报）：这 3 个内部事件在冻结 EventKind 里没有对应项
        assert_eq!(kind_of(&ev(EventType::Connected)), None);
        assert_eq!(kind_of(&ev(EventType::Disconnected)), None);
        assert_eq!(kind_of(&ev(EventType::Error)), None);
    }

    #[test]
    fn event_json_shape_matches_bridge_expectations() {
        let mut e = ev(EventType::PacketReceived);
        e.device_id = "a".repeat(32);
        e.packet = "{\"type\":\"kdeconnect.ping\"}".to_owned();
        let v: serde_json::Value = serde_json::from_str(&event_json(&e)).expect("合法 JSON");
        assert_eq!(v["type"], "packetReceived");
        assert_eq!(v["deviceId"], "a".repeat(32));
        assert_eq!(v["packet"], "{\"type\":\"kdeconnect.ping\"}");
        assert!(
            v.get("payloadState").is_none(),
            "非 payload 事件不得带 payload 字段"
        );

        let mut c = ev(EventType::Connected);
        c.role = TlsRole::Server;
        let cv: serde_json::Value = serde_json::from_str(&event_json(&c)).unwrap();
        assert_eq!(cv["role"], "server");

        let mut p = ev(EventType::PayloadTransfer);
        p.payload_state = "finished".to_owned();
        p.payload_bytes_done = 42;
        let pv: serde_json::Value = serde_json::from_str(&event_json(&p)).unwrap();
        assert_eq!(pv["payloadState"], "finished");
        assert_eq!(pv["payloadBytesDone"], 42);
        assert_eq!(pv["payloadDirection"], "receive");
    }
}
