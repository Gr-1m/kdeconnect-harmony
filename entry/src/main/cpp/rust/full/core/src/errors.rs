// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! kcbridge 错误码（唯一事实源：仓库根 `contract/errors.v1.json` v1，与 `docs/kdeconnect-oh/08 §4` 一致）。
//!
//! 桥层阶段 1 起，native 的 `error` 事件 `errorCode` 一律使用本模块编号；
//! payload 传输自身的 `0–7` 见 `payload::code`（契约 v0.2）。

pub const NOT_READY: i32 = 101;
pub const NOT_STARTED: i32 = 102;
pub const ALREADY_STARTED: i32 = 103;
pub const BAD_JSON: i32 = 104;
pub const BAD_PARAM: i32 = 105;
pub const CONTRACT_MISMATCH: i32 = 109;
pub const CERT_MISMATCH: i32 = 201;
pub const PROTOCOL_VIOLATION: i32 = 202;
pub const LINE_TOO_LONG: i32 = 203;
pub const IDENTITY_INVALID: i32 = 204;
pub const CLOCK_SKEW: i32 = 205;
pub const PEER_NOT_CONNECTED: i32 = 301;
pub const OFFER_TIMEOUT: i32 = 302;
pub const TRANSFER_CANCELLED: i32 = 303;
pub const PAYLOAD_TIMEOUT: i32 = 401;
pub const FILE_IO: i32 = 402;
pub const SEND_FAILED: i32 = 403;
pub const ENGINE_PANIC: i32 = 501;
pub const IDENTITY_INVALID_ON_START: i32 = 502;
pub const INIT_FAILED: i32 = 503;

/// 契约内全部错误码（`contract/errors.v1.json` v1 的 `codes[].code`，**集合**语义、顺序无关）。
///
/// 由 `tests/contract_errors.rs` 与契约工件逐条比对：任何一侧新增/删除/改名/改分级 → 测试变红。
pub const ALL_CODES: &[i32] = &[
    NOT_READY,
    NOT_STARTED,
    ALREADY_STARTED,
    BAD_JSON,
    BAD_PARAM,
    CONTRACT_MISMATCH,
    CERT_MISMATCH,
    PROTOCOL_VIOLATION,
    LINE_TOO_LONG,
    IDENTITY_INVALID,
    CLOCK_SKEW,
    PEER_NOT_CONNECTED,
    OFFER_TIMEOUT,
    TRANSFER_CANCELLED,
    PAYLOAD_TIMEOUT,
    FILE_IO,
    SEND_FAILED,
    ENGINE_PANIC,
    IDENTITY_INVALID_ON_START,
    INIT_FAILED,
];

/// 契约 `name` 字段（供 error 事件/日志复用，避免再手写字符串；未知码 → `UNKNOWN`）。
pub fn name(code: i32) -> &'static str {
    match code {
        NOT_READY => "NOT_READY",
        NOT_STARTED => "NOT_STARTED",
        ALREADY_STARTED => "ALREADY_STARTED",
        BAD_JSON => "BAD_JSON",
        BAD_PARAM => "BAD_PARAM",
        CONTRACT_MISMATCH => "CONTRACT_MISMATCH",
        CERT_MISMATCH => "CERT_MISMATCH",
        PROTOCOL_VIOLATION => "PROTOCOL_VIOLATION",
        LINE_TOO_LONG => "LINE_TOO_LONG",
        IDENTITY_INVALID => "IDENTITY_INVALID",
        CLOCK_SKEW => "CLOCK_SKEW",
        PEER_NOT_CONNECTED => "PEER_NOT_CONNECTED",
        OFFER_TIMEOUT => "OFFER_TIMEOUT",
        TRANSFER_CANCELLED => "TRANSFER_CANCELLED",
        PAYLOAD_TIMEOUT => "PAYLOAD_TIMEOUT",
        FILE_IO => "FILE_IO",
        SEND_FAILED => "SEND_FAILED",
        ENGINE_PANIC => "ENGINE_PANIC",
        IDENTITY_INVALID_ON_START => "IDENTITY_INVALID_ON_START",
        INIT_FAILED => "INIT_FAILED",
        _ => "UNKNOWN",
    }
}

/// 是否为契约内已知码。
///
/// `disposition()` 对未知码回退 `Infra`（防御式）；本函数让「显式登记」与「兜底回退」可区分，
/// 也用于契约测试断言「契约内每个码都走了显式分支」。
pub fn is_known(code: i32) -> bool {
    ALL_CODES.contains(&code)
}

/// 错误处置分级（与 `contract/errors.v1.json` 的 `disposition` 逐条一致）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Disposition {
    /// 断链（并派发 error）。
    FatalLink,
    /// 丢弃该包，链路继续。
    DropPacket,
    /// 可忽略（debug）。
    Ignorable,
    /// 基础设施问题（重连/日志）。
    Infra,
}

/// 穷举分级：新增码不在此 match 会编译失败，逼迫作者显式登记。
pub fn disposition(code: i32) -> Disposition {
    match code {
        NOT_READY | NOT_STARTED | ALREADY_STARTED | CONTRACT_MISMATCH | CERT_MISMATCH
        | PROTOCOL_VIOLATION | LINE_TOO_LONG | IDENTITY_INVALID => Disposition::FatalLink,
        BAD_JSON | BAD_PARAM | CLOCK_SKEW | PEER_NOT_CONNECTED | OFFER_TIMEOUT
        | TRANSFER_CANCELLED | PAYLOAD_TIMEOUT | SEND_FAILED => Disposition::DropPacket,
        FILE_IO | ENGINE_PANIC | IDENTITY_INVALID_ON_START | INIT_FAILED => Disposition::Infra,
        _ => Disposition::Infra,
    }
}

/// `errors.v1.json` 里 `kind: throw` 的码（跨桥时以异常形式抛出；阶段 1 的旧契约仍走事件）。
pub fn is_throw(code: i32) -> bool {
    matches!(code, NOT_READY | NOT_STARTED | ALREADY_STARTED | BAD_JSON | BAD_PARAM | CONTRACT_MISMATCH)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_codes_covers_every_constant_without_duplicates() {
        for code in [
            NOT_READY,
            NOT_STARTED,
            ALREADY_STARTED,
            BAD_JSON,
            BAD_PARAM,
            CONTRACT_MISMATCH,
            CERT_MISMATCH,
            PROTOCOL_VIOLATION,
            LINE_TOO_LONG,
            IDENTITY_INVALID,
            CLOCK_SKEW,
            PEER_NOT_CONNECTED,
            OFFER_TIMEOUT,
            TRANSFER_CANCELLED,
            PAYLOAD_TIMEOUT,
            FILE_IO,
            SEND_FAILED,
            ENGINE_PANIC,
            IDENTITY_INVALID_ON_START,
            INIT_FAILED,
        ] {
            assert!(ALL_CODES.contains(&code), "{code} 未登记进 ALL_CODES");
            assert!(is_known(code), "{code} 应被 is_known 认作已知码");
            assert_ne!(name(code), "UNKNOWN", "{code} 缺少 name 映射");
        }
        let mut sorted = ALL_CODES.to_vec();
        sorted.sort_unstable();
        let total = sorted.len();
        sorted.dedup();
        assert_eq!(sorted.len(), total, "ALL_CODES 存在重复项");
    }

    #[test]
    fn unknown_code_falls_back_but_is_not_known() {
        assert!(!is_known(999_999));
        assert_eq!(disposition(999_999), Disposition::Infra);
        assert_eq!(name(999_999), "UNKNOWN");
        assert!(!is_throw(999_999));
    }

    #[test]
    fn dispositions_match_contract() {
        assert_eq!(disposition(CERT_MISMATCH), Disposition::FatalLink);
        assert_eq!(disposition(PROTOCOL_VIOLATION), Disposition::FatalLink);
        assert_eq!(disposition(LINE_TOO_LONG), Disposition::FatalLink);
        assert_eq!(disposition(IDENTITY_INVALID), Disposition::FatalLink);
        assert_eq!(disposition(CLOCK_SKEW), Disposition::DropPacket);
        assert_eq!(disposition(PEER_NOT_CONNECTED), Disposition::DropPacket);
        assert_eq!(disposition(OFFER_TIMEOUT), Disposition::DropPacket);
        assert_eq!(disposition(TRANSFER_CANCELLED), Disposition::DropPacket);
        assert_eq!(disposition(PAYLOAD_TIMEOUT), Disposition::DropPacket);
        assert_eq!(disposition(SEND_FAILED), Disposition::DropPacket);
        assert_eq!(disposition(FILE_IO), Disposition::Infra);
        assert_eq!(disposition(INIT_FAILED), Disposition::Infra);
    }

    #[test]
    fn throw_kinds_match_contract() {
        for code in [NOT_READY, NOT_STARTED, ALREADY_STARTED, BAD_JSON, BAD_PARAM, CONTRACT_MISMATCH] {
            assert!(is_throw(code), "{code} should be throw kind");
        }
        for code in [CERT_MISMATCH, PROTOCOL_VIOLATION, PEER_NOT_CONNECTED, PAYLOAD_TIMEOUT, INIT_FAILED] {
            assert!(!is_throw(code), "{code} should be event kind");
        }
    }
}
