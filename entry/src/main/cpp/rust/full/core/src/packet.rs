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
    match kdc_core::packet::scan_frame(buf, max_size) {
        kdc_core::packet::FrameScan::Half => None,
        kdc_core::packet::FrameScan::DroppedOversize { consumed } => {
            buf.drain(..consumed);
            Some(Err(()))
        }
        kdc_core::packet::FrameScan::Frame { len } => {
            let frame = buf[..len].to_vec();
            buf.drain(..len);
            Some(Ok(frame))
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
        assert!(matches!(
            extract_frame(&mut buf, 4),
            Some(Err(()))
        ));
        assert!(buf.is_empty());
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
