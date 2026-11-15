// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! 线程入口 panic 包裹（MSG262 P0-2）。
//!
//! 背景：native 侧每个连接/payload/发现线程都是独立 `std::thread`，一旦 panic 会
//! 直接终止该线程（连接状态残留、事件不派发、`ENGINE_PANIC(501)` 从未使用）。
//!
//! 做法：**只包线程入口**（不包事件循环内部），panic ⇒
//! `emit_error(501 ENGINE_PANIC)` + 由调用方给出的清理动作（关闭连接 / 结束 payload job）

use std::sync::{Arc, Mutex};

use crate::state::Shared;

/// 测试钩子：**指定 deviceId** 的下一次 identity 帧处理主动 panic（生产恒为 `None`）。
///
/// 必须按 deviceId 定向：钩子是进程级静态，而 `cargo test` 并行跑同一二进制内的多个用例，
/// 「下一个 identity」会被别的用例消费（实测踩到过）。
static PANIC_FOR_ID: Mutex<Option<String>> = Mutex::new(None);

/// 仅供测试：让 `device_id` 的下一次 identity 帧处理主动 panic
/// （见 `stack_e2e::thread_panic_is_reported_and_cleanup_runs`）。
#[doc(hidden)]
pub fn panic_on_identity_of_for_test(device_id: &str) {
    if let Ok(mut guard) = PANIC_FOR_ID.lock() {
        *guard = Some(device_id.to_owned());
    }
}

/// 由 `connection` 在 identity 帧处理前调用；命中（且消费）时调用方应 panic。
#[doc(hidden)]
pub fn take_test_panic_for(device_id: &str) -> bool {
    let Ok(mut guard) = PANIC_FOR_ID.lock() else {
        return false;
    };
    if guard.as_deref() == Some(device_id) {
        *guard = None;
        true
    } else {
        false
    }
}

/// 包裹线程体：`panic` 不逃出线程边界。
///
/// - `shared`：用于派发 `ENGINE_PANIC` 事件；
/// - `what`：线程职能（进日志与事件消息，便于定位）；
/// - `on_panic`：清理动作（关连接 / 结束 payload job），在派发事件后执行。
pub fn guard<F, C>(shared: Arc<Shared>, what: &str, on_panic: C, body: F)
where
    F: FnOnce(),
    C: FnOnce(),
{
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(body));
    let Err(payload) = result else {
        return;
    };
    let message = payload
        .downcast_ref::<&str>()
        .map(|s| (*s).to_owned())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "unknown panic".to_owned());
    crate::loge!("thread panic in {what}: {message}");
    shared.emit_error(
        "",
        crate::errors::ENGINE_PANIC,
        &format!("thread panic in {what}: {message}"),
        "",
        0,
    );
    on_panic();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panic_hook_is_targeted_and_one_shot() {
        assert!(!take_test_panic_for("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
        panic_on_identity_of_for_test("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        assert!(
            !take_test_panic_for("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
            "只对指定 deviceId 生效"
        );
        assert!(take_test_panic_for("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
        assert!(
            !take_test_panic_for("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            "一次性"
        );
    }
}
