// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! 事件出口：网络栈 → NAPI 桥的唯一通道。
//!
//! 网络线程只调用 [`emit`]，回调由 NAPI 层注册（TSFN 投递到 ArkTS 主线程）。
//! 这里不做去重/节流；发现去重与事件普查在 [`crate::stack`] 内完成。

use crate::types::{EventCallback, NetEvent};
use std::sync::{LazyLock, Mutex};

static CALLBACK: LazyLock<Mutex<Option<EventCallback>>> = LazyLock::new(|| Mutex::new(None));

pub fn set_callback(cb: Option<EventCallback>) {
    if let Ok(mut guard) = CALLBACK.lock() {
        *guard = cb;
    }
}

pub fn emit(event: NetEvent) {
    let cb = CALLBACK.lock().ok().and_then(|g| g.clone());
    if let Some(cb) = cb {
        cb(event);
    }
}

/// 统一错误事件：`errorCode` 为 errno 或协议自定义码。
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

/// 出向连接失败：带目标地址与真实 errno，UI 可直接提示「连接失败/对端无响应」。
pub fn emit_connect_error(host: &str, port: u16, code: i32, stage: &str) {
    crate::logw!(
        "connect error {host}:{port} code={code} stage={stage} ({})",
        crate::types::errno_text(code)
    );
    emit_error(
        "",
        host,
        port,
        code,
        &format!("{stage} ({host}:{port}): {}", crate::types::errno_text(code)),
    );
}
