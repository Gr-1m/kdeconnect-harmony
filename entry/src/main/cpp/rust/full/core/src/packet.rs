// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! 协议编解码薄封装：复用 `kdc_core` 已与 C++ 基线做过逐字节差分的实现。
//!
//! 这里只补两件事：
//! 1. 接收缓冲用 `Vec<u8>`（网络字节不保证 UTF-8），帧提取后才校验 UTF-8；
//! 2. 把 `kdc_core::packet::DeviceInfo` 映射为本 crate 的 `DeviceInfo`。

use crate::types::{DeviceInfo, MAX_IDENTITY_PACKET_SIZE, MAX_PACKET_SIZE, PROTOCOL_VERSION};
pub use kdc_core::packet::ParsedPacket;

/// 从接收缓冲提取一个完整帧（含结尾 `\n`）。
///
/// - `None`：半包，缓冲保持原样；
/// - `Some(Ok(frame))`：完整帧（已从缓冲移除）；
/// - `Some(Err(()))`：超限行已丢弃（调用方跳过，继续下一帧）。
#[allow(clippy::result_unit_err)]
pub fn extract_frame(buf: &mut Vec<u8>, max_size: usize) -> Option<Result<Vec<u8>, ()>> {
    extract_frame_from(buf, max_size, 0).0
}

/// 游标版 [`extract_frame`]：返回 `(本轮的帧结果, 下一轮应传入的游标)`。
///
/// 游标 = 缓冲区**前缀**中已确认「不含 `'\n'`」的字节数。控制链路的读循环每轮只扫新增字节，
/// 从而把「超长行分多次到达」的扫描量从 O(n²) 降为 O(n)（32 MiB 单帧实测 ~100 s CPU → 秒级）。
#[allow(clippy::result_unit_err)]
pub fn extract_frame_from(
    buf: &mut Vec<u8>,
    max_size: usize,
    from: usize,
) -> (Option<Result<Vec<u8>, ()>>, usize) {
    let from = from.min(buf.len());
    match kdc_core::packet::scan_frame_from(buf, max_size, from) {
        kdc_core::packet::FrameScan::Half => {
            // 半包：`buf[from..]` 已确认不含 '\n'，连同调用方的不变量 ⇒ 整个缓冲都已扫过
            // ⇒ 游标推进到缓冲末尾（这正是 O(n) 的来源：下次只扫新到达的字节）。
            (None, buf.len())
        }
        kdc_core::packet::FrameScan::DroppedOversize { consumed } => {
            buf.drain(..consumed);
            // 超长行整行（或整个缓冲）已丢弃，剩余字节均未扫描。
            (Some(Err(())), 0)
        }
        kdc_core::packet::FrameScan::Frame { len } => {
            let frame = buf[..len].to_vec();
            buf.drain(..len);
            // 被消费的前缀同样**不含** `'\n'`，故已扫前缀随之缩短（不变量保持）。
            (Some(Ok(frame)), from.saturating_sub(len))
        }
    }
}

/// deviceName 过滤（kdeconnect-oh `01 §4`）：去掉 `["',;:.!?()\[\]<>]`，截 32 字符；
/// 过滤后为空则回退固定名，保证 identity 的 `deviceName` 非空（对端会因此拒绝）。
pub fn sanitize_device_name(name: &str) -> String {
    const INVALID: &[char] = &[
        '"', '\'', ',', ';', ':', '.', '!', '?', '(', ')', '[', ']', '<', '>',
    ];
    let filtered: String = name.chars().filter(|c| !INVALID.contains(c)).collect();
    let truncated: String = filtered.chars().take(32).collect();
    let trimmed = truncated.trim();
    if trimmed.is_empty() {
        "KDE Connect".to_owned()
    } else {
        trimmed.to_owned()
    }
}

/// 构建 `kdeconnect.identity` 帧（带 `\n`）。
pub fn build_identity(
    device_id: &str,
    device_name: &str,
    device_type: &str,
    tcp_port: u16,
    incoming_caps: &[String],
    outgoing_caps: &[String],
) -> String {
    kdc_core::packet::build_identity(
        device_id,
        &sanitize_device_name(device_name),
        device_type,
        tcp_port,
        PROTOCOL_VERSION,
        incoming_caps,
        outgoing_caps,
    )
}

/// 解析 identity 帧；deviceId 非法/非 identity → None。
pub fn parse_identity(json: &str) -> Option<DeviceInfo> {
    let info = kdc_core::packet::parse_identity(json)?;
    Some(DeviceInfo {
        device_id: info.device_id,
        device_name: info.device_name,
        device_type: info.device_type,
        host: String::new(),
        tcp_port: info.tcp_port,
        protocol_version: info.protocol_version,
    })
}

pub fn parse_packet(json: &str) -> Option<ParsedPacket> {
    kdc_core::packet::parse_packet(json)
}

/// 帧上限：identity 用 8 KiB，普通 packet 用 32 MiB。
pub fn frame_limit(is_identity_hint: bool) -> usize {
    if is_identity_hint {
        MAX_IDENTITY_PACKET_SIZE
    } else {
        MAX_PACKET_SIZE
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_name_filter_follows_spec() {
        // 过滤 ["',;:.!?()\[\]<>] + 截 32 字符；空则回退（kdeconnect-oh 01 §4）。
        assert_eq!(sanitize_device_name("My, Phone: !?"), "My Phone");
        assert_eq!(
            sanitize_device_name(&"x".repeat(40)),
            "x".repeat(32).as_str()
        );
        assert_eq!(sanitize_device_name("<<>>"), "KDE Connect");
        assert_eq!(sanitize_device_name("  "), "KDE Connect");
    }

    #[test]
    fn extracts_frames_from_bytes() {
        let mut buf = b"{\"type\":\"a\"}\n{\"type\":\"b\"}\n".to_vec();
        let first = extract_frame(&mut buf, MAX_PACKET_SIZE).unwrap().unwrap();
        assert_eq!(first, b"{\"type\":\"a\"}\n");
        let second = extract_frame(&mut buf, MAX_PACKET_SIZE).unwrap().unwrap();
        assert_eq!(second, b"{\"type\":\"b\"}\n");
        assert!(extract_frame(&mut buf, MAX_PACKET_SIZE).is_none());
    }

    #[test]
    fn oversize_line_is_dropped() {
        let mut buf = b"0123456789\n".to_vec();
        assert!(matches!(extract_frame(&mut buf, 4), Some(Err(()))));
        assert!(buf.is_empty());
    }

    #[test]
    fn cursor_scan_never_misses_a_split_frame() {
        // 一条帧分三次到达：游标只推进到已扫前缀，最后一片到齐后必须出帧。
        let mut buf: Vec<u8> = Vec::new();
        let mut from = 0usize;
        for (part, done) in [
            (&b"{\"id\":1"[..], false),
            (&b",\"type\":\"a\""[..], false),
            (&b"}\n"[..], true),
        ] {
            buf.extend_from_slice(part);
            let (item, next) = extract_frame_from(&mut buf, MAX_PACKET_SIZE, from);
            from = next;
            if done {
                assert_eq!(item.unwrap().unwrap(), b"{\"id\":1,\"type\":\"a\"}\n");
            } else {
                assert!(item.is_none(), "半包不应出帧");
                assert_eq!(from, buf.len(), "游标须推进到已扫前缀末尾");
            }
        }
        assert!(buf.is_empty());
    }

    #[test]
    fn cursor_handles_two_frames_and_prefix_shrink() {
        let mut buf = b"aa\nbb\n".to_vec();
        let (first, from) = extract_frame_from(&mut buf, MAX_PACKET_SIZE, 0);
        assert_eq!(first.unwrap().unwrap(), b"aa\n");
        let (second, _) = extract_frame_from(&mut buf, MAX_PACKET_SIZE, from);
        assert_eq!(second.unwrap().unwrap(), b"bb\n");
    }

    #[test]
    fn cursor_oversize_dropped_then_next_frame_intact() {
        // 前缀已扫（无 '\n'）+ 超长行 ⇒ 丢弃整行、游标归零，后续帧不受影响。
        let mut buf = vec![b'x'; 64];
        buf.extend_from_slice(b"\nok\n");
        let (item, from) = extract_frame_from(&mut buf, 32, 64);
        assert!(matches!(item, Some(Err(()))), "超长行应被丢弃");
        assert_eq!(from, 0);
        let (item, _) = extract_frame_from(&mut buf, 32, from);
        assert_eq!(item.unwrap().unwrap(), b"ok\n");
    }

    #[test]
    fn identity_roundtrip() {
        let frame = build_identity(
            "0123456789abcdef0123456789abcdef",
            "phone",
            "phone",
            1716,
            &["kdeconnect.ping".to_owned()],
            &["kdeconnect.ping".to_owned()],
        );
        assert!(frame.ends_with('\n'));
        let info = parse_identity(&frame).unwrap();
        assert_eq!(info.device_id, "0123456789abcdef0123456789abcdef");
        assert_eq!(info.tcp_port, 1716);
    }

    #[test]
    fn packet_metadata() {
        let json = r#"{"id":1,"type":"kdeconnect.share.request","body":{"filename":"x"},"payloadSize":42,"payloadTransferInfo":{"port":1739}}"#;
        let p = parse_packet(json).unwrap();
        assert_eq!(p.r#type, "kdeconnect.share.request");
        assert_eq!(p.payload_size, 42);
        assert_eq!(p.payload_port, 1739);
    }
}
