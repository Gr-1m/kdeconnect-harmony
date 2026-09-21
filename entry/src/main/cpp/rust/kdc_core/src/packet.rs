// SPDX-License-Identifier: GPL-2.0-or-later
//! `net/packet_io.cpp`（`kdeconnect::PacketIO` 纯函数部分）的 Rust 移植。
//!
//! 行为语义以现有 C++ 实现为**唯一参照**（`entry/src/main/cpp/net/packet_io.cpp`）：
//! 帧切分/超限丢弃、identity 构建的字段顺序与紧凑输出、deviceId 正则收口、
//! packet 的 type/body/payload 元数据解析。对照断言见
//! `entry/src/main/cpp/tests/test_main.cpp` 中同名 TEST_CASE（逐条移植到本文件尾部）。
//!
//! 纯函数：无 FFI、无 unsafe、无系统调用。

use serde::Serialize;
use serde_json::Value;

/// C++ `kdeconnect::DeviceInfo`（`net_types.h`）的 Rust 对应物。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DeviceInfo {
    pub device_id: String,
    pub device_name: String,
    pub device_type: String,
    pub tcp_port: u16,
}

/// `PacketIO::extractFrame` 的返回值。
///
/// C++ 用 `bool + 出参 frame` 表达三种结局；Rust 用枚举显式区分：
/// - C++ `true` 且 frame 非空 → [`FrameOutcome::Frame`]
/// - C++ `false`（半包，buf 原样保留）→ [`FrameOutcome::Half`]
/// - C++ `true` 且 frame 为空（超限行按「非法行丢弃」）→ [`FrameOutcome::DroppedOversize`]
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrameOutcome {
    /// 完整帧（含结尾 `'\n'`），已从 `buf` 移除。
    Frame(String),
    /// 半包：`buf` 保持原样，等后续数据。
    Half,
    /// 超限帧：该行已按「非法行丢弃」语义从 `buf` 移除，调用方跳过。
    DroppedOversize,
}

/// 从接收缓冲抽出一个完整帧（含结尾 `'\n'`）。
///
/// 与 C++ `PacketIO::extractFrame(buf, frame, maxSize)` 等价：
/// - `buf` 为空 → `Half`；
/// - 无 `'\n'` 且 `buf.len() > max_size` → 清空 `buf`（防缓冲无界增长 / OOM）→ `DroppedOversize`；
/// - 无 `'\n'` 且未超限 → `Half`（不动 `buf`）；
/// - 帧长（`'\n'` 下标 + 1）`> max_size` → 丢弃该行 → `DroppedOversize`；
/// - 否则返回含 `'\n'` 的完整帧并从 `buf` 移除。
/// 零拷贝扫描结果（R-OPT-1）：与 `FrameOutcome` 语义一一对应，但不分配中间 String。
pub enum FrameScan {
    /// 完整帧：`buf[..len]` 为帧字节（含结尾 `'\n'`）
    Frame { len: usize },
    /// 半包：缓冲保持原样
    Half,
    /// 超限行：`buf[..consumed]` 需移除（调用方跳过该帧）
    DroppedOversize { consumed: usize },
}

/// 只扫描、不分配、不改写（R-OPT-1）：语义与 `extract_frame` 完全一致 ——
/// 供 FFI 侧直接对调用方缓冲做一次扫描，避免 `from_utf8(..).to_string()` + `to_owned()` 两次拷贝。
pub fn scan_frame(buf: &[u8], max_size: usize) -> FrameScan {
    if buf.is_empty() {
        return FrameScan::Half;
    }
    match buf.iter().position(|&b| b == b'\n') {
        None => {
            if buf.len() > max_size {
                FrameScan::DroppedOversize { consumed: buf.len() }
            } else {
                FrameScan::Half
            }
        }
        Some(pos) => {
            let frame_len = pos + 1;
            if frame_len > max_size {
                FrameScan::DroppedOversize { consumed: frame_len }
            } else {
                FrameScan::Frame { len: frame_len }
            }
        }
    }
}

pub fn extract_frame(buf: &mut String, max_size: usize) -> FrameOutcome {
    match scan_frame(buf.as_bytes(), max_size) {
        FrameScan::Half => FrameOutcome::Half,
        FrameScan::DroppedOversize { consumed } => {
            buf.drain(..consumed);
            FrameOutcome::DroppedOversize
        }
        FrameScan::Frame { len } => {
            let frame = buf[..len].to_owned();
            buf.drain(..len);
            FrameOutcome::Frame(frame)
        }
    }
}

/// identity 帧的 `body`：字段顺序与 `PacketIO::buildIdentity` 的 cJSON 插入顺序一致
/// （serde 按声明顺序输出字段，不依赖 `serde_json` 的 `preserve_order` feature）。
#[derive(Serialize)]
struct IdentityBody<'a> {
    #[serde(rename = "deviceId")]
    device_id: &'a str,
    #[serde(rename = "deviceName")]
    device_name: &'a str,
    #[serde(rename = "deviceType")]
    device_type: &'a str,
    #[serde(rename = "tcpPort")]
    tcp_port: u16,
    #[serde(rename = "protocolVersion")]
    protocol_version: i32,
    #[serde(rename = "incomingCapabilities")]
    incoming_capabilities: &'a [String],
    #[serde(rename = "outgoingCapabilities")]
    outgoing_capabilities: &'a [String],
}

/// identity 帧根对象：顺序同 C++（`id` / `type` / `version` / `body`）。
#[derive(Serialize)]
struct IdentityFrame<'a> {
    id: i32,
    #[serde(rename = "type")]
    frame_type: &'static str,
    version: i32,
    body: IdentityBody<'a>,
}

/// 构建 `kdeconnect.identity` 帧，帧尾带 `'\n'`（协议规定 packet 以换行分隔）。
///
/// 与 C++ `PacketIO::buildIdentity` 等价：字段与顺序逐字一致，
/// 输出紧凑（无空格），空 capability 数组输出 `[]`。
pub fn build_identity(
    device_id: &str,
    device_name: &str,
    device_type: &str,
    tcp_port: u16,
    protocol_version: i32,
    incoming: &[String],
    outgoing: &[String],
) -> String {
    let frame = IdentityFrame {
        id: 0,
        frame_type: "kdeconnect.identity",
        version: protocol_version,
        body: IdentityBody {
            device_id,
            device_name,
            device_type,
            tcp_port,
            protocol_version,
            incoming_capabilities: incoming,
            outgoing_capabilities: outgoing,
        },
    };

    // 对应 cJSON_PrintUnformatted：紧凑、无空格；随后统一追加帧尾 '\n'
    let mut json = serde_json::to_string(&frame).expect("identity 帧序列化不会失败");
    json.push('\n');
    json
}

/// deviceId 格式校验：`^[a-zA-Z0-9_-]{32,38}$`（协议三端一致，且 = 证书 CN）。
///
/// 长度按字节计，与 C++ `std::string::size()` 一致。
pub fn is_valid_device_id(id: &str) -> bool {
    if id.len() < 32 || id.len() > 38 {
        return false;
    }
    id.bytes()
        .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
}

/// 解析 identity 帧。语义与 C++ `PacketIO::parseIdentity` 等价：
/// 非 JSON / 非对象根 / `type` 非 `"kdeconnect.identity"` / 缺 `body` / deviceId 不合法 → `None`。
///
/// 注：C++ 版通过出参 `DeviceInfo` 回填，缺字段时保留调用方旧值；Rust 版返回独立结构，
/// 未出现的字段取空串 / 0（`deviceId` 必须过 [`is_valid_device_id`]，否则整体 `None`）。
pub fn parse_identity(json: &str) -> Option<DeviceInfo> {
    let root: Value = serde_json::from_str(json).ok()?;
    // cJSON_GetObjectItem 在非对象根上恒为 NULL
    let root = root.as_object()?;

    if root.get("type").and_then(Value::as_str) != Some("kdeconnect.identity") {
        return None;
    }

    // C++ 只要求 body 存在（不校验类型）；body 非对象时其字段取不到，与 cJSON 一致
    let body = root.get("body")?;
    let body = body.as_object();
    let field = |name: &str| body.and_then(|b| b.get(name));

    let device_id = field("deviceId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let device_name = field("deviceName")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let device_type = field("deviceType")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let tcp_port = field("tcpPort")
        .and_then(Value::as_f64)
        .map(|port| port as u16) // 合法域 0..=65535 内与 C++ static_cast<uint16_t> 等价
        .unwrap_or(0);

    // deviceId 必须存在且格式合法（REVIEW §4 P2-4：格式校验一处收口）
    if !is_valid_device_id(&device_id) {
        return None;
    }

    Some(DeviceInfo {
        device_id,
        device_name,
        device_type,
        tcp_port,
    })
}

/// `PacketIO::parsePacket` 的解析结果（对应 C++ 的 `type` / `body` 出参与可选 payload 元数据）。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ParsedPacket {
    pub r#type: String,
    /// body 子树的紧凑 JSON 原文（对应 cJSON_PrintUnformatted；body 缺失时为空串）。
    pub body: String,
    /// 0 = 无 payload；-1 = 流式；>0 = 字节数。
    pub payload_size: i64,
    /// payloadTransferInfo.port（缺失 / 非数字 → 0）。
    pub payload_port: u16,
}

/// 解析 packet 的 type/body 与 payload 元数据。
///
/// 与 C++ `PacketIO::parsePacket` 等价：JSON 非法 → `None`；`type` 缺失或非字符串
/// （C++ 返回 `!type.empty()`）→ `None`；`body` 缺失时为空串。
pub fn parse_packet(json: &str) -> Option<ParsedPacket> {
    let root: Value = serde_json::from_str(json).ok()?;

    let packet_type = root
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();

    let body = match root.get("body") {
        Some(body) => serde_json::to_string(body).expect("Value 序列化不会失败"),
        None => String::new(),
    };

    let payload_size = root
        .get("payloadSize")
        .and_then(Value::as_f64)
        .map(|size| size as i64)
        .unwrap_or(0);

    let payload_port = root
        .get("payloadTransferInfo")
        .and_then(Value::as_object)
        .and_then(|info| info.get("port"))
        .and_then(Value::as_f64)
        .map(|port| port as u16) // 合法域内与 C++ static_cast<uint16_t> 等价
        .unwrap_or(0);

    if packet_type.is_empty() {
        return None;
    }

    Some(ParsedPacket {
        r#type: packet_type,
        body,
        payload_size,
        payload_port,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 32 位合法 deviceId（`test_main.cpp` 同名用例的固定输入）。
    const VALID_ID: &str = "0123456789abcdef0123456789abcdef";
    /// C++ `extractFrame` 的默认 maxSize（`net_types.h` MAX_PACKET_SIZE）。
    const MAX_PACKET_SIZE: usize = 32 * 1024 * 1024;

    // —————— extractFrame：帧切分（P0 级，B3 修复的核心） ——————

    #[test]
    fn extract_frame_single() {
        let mut buf = "A\n".to_string();
        assert_eq!(
            extract_frame(&mut buf, MAX_PACKET_SIZE),
            FrameOutcome::Frame("A\n".to_string())
        );
        assert!(buf.is_empty());
    }

    #[test]
    fn extract_frame_two_in_one() {
        // 一次 read 收到两帧合并（EPOLLET 排空后的典型形态）
        let mut buf = "A\nB\n".to_string();
        assert_eq!(
            extract_frame(&mut buf, MAX_PACKET_SIZE),
            FrameOutcome::Frame("A\n".to_string())
        );
        assert_eq!(
            extract_frame(&mut buf, MAX_PACKET_SIZE),
            FrameOutcome::Frame("B\n".to_string())
        );
        assert!(buf.is_empty());
    }

    #[test]
    fn extract_frame_half_keeps_buffer() {
        // 半包：不得消费缓冲
        let mut buf = "{\"type\":\"kde".to_string();
        let before = buf.clone();
        assert_eq!(extract_frame(&mut buf, MAX_PACKET_SIZE), FrameOutcome::Half);
        assert_eq!(buf, before);
    }

    #[test]
    fn extract_frame_half_then_rest() {
        let mut buf = "{\"type\":\"kde".to_string();
        buf += "connect.ping\"}\n";
        assert_eq!(
            extract_frame(&mut buf, MAX_PACKET_SIZE),
            FrameOutcome::Frame("{\"type\":\"kdeconnect.ping\"}\n".to_string())
        );
        assert!(buf.is_empty());
    }

    #[test]
    fn extract_frame_oversize_dropped() {
        // 超限帧：按「非法行丢弃」（防 OOM，P2-1）；后续正常帧不受影响
        let mut buf = "123456\nok\n".to_string();
        assert_eq!(extract_frame(&mut buf, 4), FrameOutcome::DroppedOversize);
        assert_eq!(extract_frame(&mut buf, 4), FrameOutcome::Frame("ok\n".to_string()));
    }

    #[test]
    fn extract_frame_oversize_partial_line_clears_buffer() {
        // 无 '\n' 且已超限：整段丢弃，防止缓冲无界增长
        let mut buf = "0123456789".to_string();
        assert_eq!(extract_frame(&mut buf, 4), FrameOutcome::DroppedOversize);
        assert!(buf.is_empty());
        // 未超限的半包仍原样保留
        let mut buf = "0123".to_string();
        assert_eq!(extract_frame(&mut buf, 4), FrameOutcome::Half);
        assert_eq!(buf, "0123");
    }

    // —————— parsePacket：type/body/payload 元数据（D3） ——————

    #[test]
    fn parse_packet_payload_fields() {
        let json = "{\"id\":0,\"type\":\"kdeconnect.share.request\",\"body\":{\"filename\":\"a.png\"},\
                    \"payloadSize\":882,\"payloadTransferInfo\":{\"port\":1739}}";
        let pkt = parse_packet(json).expect("应解析成功");
        assert_eq!(pkt.r#type, "kdeconnect.share.request");
        assert_eq!(pkt.payload_size, 882);
        assert_eq!(pkt.payload_port, 1739);
        assert!(pkt.body.contains("a.png"));
    }

    #[test]
    fn parse_packet_no_payload() {
        let json = "{\"id\":0,\"type\":\"kdeconnect.ping\",\"body\":{}}";
        let pkt = parse_packet(json).expect("应解析成功");
        assert_eq!(pkt.r#type, "kdeconnect.ping");
        assert_eq!(pkt.payload_size, 0);
        assert_eq!(pkt.payload_port, 0);
    }

    #[test]
    fn parse_packet_invalid_json() {
        assert_eq!(parse_packet("{oops"), None);
    }

    #[test]
    fn parse_packet_streaming_payload_size_kept() {
        // -1 = 流式：必须原样保留（0 另有含义，不可混同）
        let json = "{\"type\":\"kdeconnect.share.request\",\"payloadSize\":-1}";
        let pkt = parse_packet(json).expect("应解析成功");
        assert_eq!(pkt.payload_size, -1);
        assert_eq!(pkt.payload_port, 0);
    }

    // —————— isValidDeviceId：协议正则收口（P2-4） ——————

    #[test]
    fn device_id_validation() {
        let rows: &[(&str, bool)] = &[
            ("0123456789abcdef0123456789abcdef", true), // 32 hex
            ("0123456789abcdef0123456789abcde-", true), // '-' 合法
            ("0123456789abcdef0123456789abcde_", true), // '_' 合法
            ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef", true), // 大写
            ("0123456789abcdef0123456789abcde", false), // 31 位
            ("0123456789abcdef0123456789abcdef0", true), // 33 位（32..38 区间内）
            ("0123456789abcdef0123456789abcdef01", true), // 34 位仍合法（≤38）
            ("0123456789abcdef0123456789abcd.f", false), // 非法字符
            ("", false),
        ];
        for (id, ok) in rows {
            assert_eq!(is_valid_device_id(id), *ok, "id={id:?}");
        }
        // 39 位：超上限
        assert!(!is_valid_device_id(&"a".repeat(39)));
        // 38 位：上边界合法
        assert!(is_valid_device_id(&"a".repeat(38)));
    }

    // —————— buildIdentity：caps 单一来源（§3.3 修复） ——————

    #[test]
    fn build_identity_carries_caps() {
        let incoming = vec![
            "kdeconnect.share.request".to_string(),
            "kdeconnect.ping".to_string(),
        ];
        let outgoing = vec!["kdeconnect.ping".to_string()];
        let s = build_identity(VALID_ID, "Dev", "phone", 1716, 8, &incoming, &outgoing);
        assert!(s.contains("kdeconnect.identity"));
        assert!(s.contains(VALID_ID));
        assert!(s.contains("kdeconnect.share.request"));
        assert!(s.contains("\"tcpPort\":1716"));
        assert!(s.ends_with('\n')); // 帧尾换行（KDE readLine 依赖）
    }

    #[test]
    fn build_identity_matches_cpp_byte_for_byte() {
        // golden：由现有 C++ 实现（packet_io.cpp + 仓库内 cJSON）实跑捕获，
        // 锁定字段顺序 / 紧凑输出（无空格）/ 空 caps 输出 `[]` / 帧尾 '\n'。
        let s = build_identity(VALID_ID, "Dev", "phone", 1716, 8, &[], &[]);
        assert_eq!(
            s,
            "{\"id\":0,\"type\":\"kdeconnect.identity\",\"version\":8,\"body\":{\"deviceId\":\
             \"0123456789abcdef0123456789abcdef\",\"deviceName\":\"Dev\",\"deviceType\":\"phone\",\
             \"tcpPort\":1716,\"protocolVersion\":8,\"incomingCapabilities\":[],\
             \"outgoingCapabilities\":[]}}\n"
        );
    }

    // —————— parseIdentity：deviceId 收口（P2-4） ——————

    #[test]
    fn parse_identity_requires_valid_device_id() {
        let ok = format!(
            "{{\"id\":0,\"type\":\"kdeconnect.identity\",\"version\":8,\"body\":{{\
             \"deviceId\":\"{VALID_ID}\",\"deviceName\":\"Dev\",\"deviceType\":\"phone\",\
             \"tcpPort\":1716,\"protocolVersion\":8,\"incomingCapabilities\":[],\
             \"outgoingCapabilities\":[]}}}}"
        );
        let info = parse_identity(&ok).expect("合法 identity 应解析成功");
        assert_eq!(info.device_id, VALID_ID);
        assert_eq!(info.device_name, "Dev");
        assert_eq!(info.device_type, "phone");
        assert_eq!(info.tcp_port, 1716);

        // deviceId 不合法 → 整体失败
        let bad_id = ok.replace(VALID_ID, "0123456789abcdef0123456789abcde");
        assert_eq!(parse_identity(&bad_id), None);
        // 缺 deviceId → 整体失败
        let no_id = "{\"type\":\"kdeconnect.identity\",\"body\":{\"deviceName\":\"Dev\"}}";
        assert_eq!(parse_identity(no_id), None);
        // type 非 kdeconnect.identity → 失败
        let wrong_type = ok.replace("kdeconnect.identity", "kdeconnect.ping");
        assert_eq!(parse_identity(&wrong_type), None);
        // 缺 body → 失败；非法 JSON → 失败
        assert_eq!(
            parse_identity("{\"type\":\"kdeconnect.identity\"}"),
            None
        );
        assert_eq!(parse_identity("{\"id\":0"), None);
    }
}
