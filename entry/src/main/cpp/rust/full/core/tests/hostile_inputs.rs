// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! **异常输入（hostile input）用例**（MSG259 P1-4 的落地部分）。
//!
//! 目标不是「穷举 fuzz」，而是把**外部输入进入解析层的那几个门**逐个钉死：
//! identity/packet JSON、证书 DER/PEM、deviceId 边界、caps 注入、地址字符串、帧上限。
//! 约定：**绝不 panic**（返回 `None`/空值/回退），且不产生「看似成功」的假结果。
//!
//! 未覆盖（明确记录，见交付消息）：TLS 握手期的畸形记录、payload 端口协商的对抗性重放——
//! 这些需要真实 socket/时间维度，属 `cargo fuzz` + 真机验证范畴，本轮不引入 fuzz 工具链。

use kdc_native::cert_ext;
use kdc_native::packet;
use kdc_native::types::{MAX_IDENTITY_PACKET_SIZE, MAX_PACKET_SIZE};

const VALID_ID: &str = "0123456789abcdef0123456789abcdef";

#[test]
fn identity_rejects_hostile_json() {
    let hostile = [
        "",
        " ",
        "{",
        "}",
        "[]",
        "null",
        "0",
        r#""kdeconnect.identity""#,
        r#"{"type":"kdeconnect.identity"}"#, // 缺 body
        r#"{"type":"other","body":{"deviceId":"0123456789abcdef0123456789abcdef"}}"#,
        r#"{"type":"kdeconnect.identity","body":{"deviceId":"short"}}"#,
        r#"{"type":"kdeconnect.identity","body":{"deviceId":"0123456789abcdef0123456789abcdef0123456789"}}"#,
        r#"{"type":"kdeconnect.identity","body":{"deviceId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!"}}"#, // 非法字符
        r#"{"type":"kdeconnect.identity","body":{"deviceId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"#, // 截断 JSON
    ];
    for raw in hostile {
        assert!(
            packet::parse_identity(raw).is_none(),
            "畸形 identity 不应被接受: {raw}"
        );
    }
}

/// 宽松字段（`deviceName`/`deviceType`/`tcpPort`）与端口越界：**记录实现口径**（含与 C++ 的差异）。
#[test]
fn identity_leniency_and_port_bounds_are_explicit() {
    // ① 宽松字段缺失/类型不符 ⇒ 空串 / 0，但 identity 本身仍被接受（`deviceName` 非否决条件）。
    let lean = format!(
        r#"{{"type":"kdeconnect.identity","body":{{"deviceId":"{VALID_ID}","deviceName":123}}}}"#
    );
    let info = packet::parse_identity(&lean).expect("deviceName 类型不符不应否决 identity");
    assert_eq!(info.device_name, "");
    assert_eq!(info.device_type, "");
    assert_eq!(info.tcp_port, 0);

    // ② 数值字符串兼容（上游 Android 经 optString 读 int 字段会以字符串回发）。
    let stringy = format!(
        r#"{{"type":"kdeconnect.identity","body":{{"deviceId":"{VALID_ID}","tcpPort":"1716"}}}}"#
    );
    assert_eq!(
        packet::parse_identity(&stringy).map(|i| i.tcp_port),
        Some(1716)
    );

    // ③ 端口越界：Rust `as u16` **饱和**（70000 → 65535、-1 → 0）；
    //    C++ `static_cast<uint16_t>` 会**回绕**（70000 → 4464）⇒ 二者对畸形输入行为不同，
    //    这里锁定 Rust 口径（更安全：不会把越界值映射成另一个「看起来合法」的端口）。
    for (raw_port, expect) in [("70000", 65535u16), ("-1", 0), ("65535", 65535), ("0", 0)] {
        let json = format!(
            r#"{{"type":"kdeconnect.identity","body":{{"deviceId":"{VALID_ID}","tcpPort":{raw_port}}}}}"#
        );
        assert_eq!(
            packet::parse_identity(&json).map(|i| i.tcp_port),
            Some(expect),
            "tcpPort={raw_port} 的解析口径变了"
        );
    }

    // ④ `deviceName` 在**入向**不做裁剪（仅出向 `sanitize_device_name` 收口）——
    //    这是一个已知观察项（对端可控的 name/type 会原样进日志与 UI），见交付消息 §4。
    let long_name = "n".repeat(200);
    let json = format!(
        r#"{{"type":"kdeconnect.identity","body":{{"deviceId":"{VALID_ID}","deviceName":"{long_name}"}}}}"#
    );
    assert_eq!(
        packet::parse_identity(&json).map(|i| i.device_name.chars().count()),
        Some(200)
    );
}

#[test]
fn packet_rejects_hostile_json_and_extremes() {
    for raw in [
        "",
        "{",
        "[]",
        "null",
        "0",
        r#"{"body":{}}"#,
        r#"{"type":42}"#,
    ] {
        assert!(
            packet::parse_packet(raw).is_none(),
            "畸形 packet 不应被接受: {raw}"
        );
    }

    // 极端 payload 元数据：解析层只做「值搬运」，**不得溢出/panic**；消费侧另有上限检查。
    let huge = format!(
        r#"{{"type":"kdeconnect.share.request","body":{{}},"payloadSize":{},"payloadTransferInfo":{{"port":65535}}}}"#,
        i64::MAX
    );
    let parsed = packet::parse_packet(&huge).expect("极端 payloadSize 仍应可解析");
    assert_eq!(parsed.payload_size, i64::MAX);
    assert_eq!(parsed.payload_port, 65535);

    let negative = r#"{"type":"kdeconnect.ping","body":{},"payloadSize":-7}"#;
    let parsed = packet::parse_packet(negative).expect("负 payloadSize 仍应可解析");
    assert_eq!(parsed.payload_size, -7);

    // port 超出 u16：Rust `as u16` **饱和**到 65535（C++ static_cast 会回绕成 4464）；不得 panic。
    let bad_port = r#"{"type":"kdeconnect.ping","body":{},"payloadSize":1,"payloadTransferInfo":{"port":70000}}"#;
    assert_eq!(
        packet::parse_packet(bad_port).map(|p| p.payload_port),
        Some(65535),
        "越界端口应按饱和口径处理（见 identity_leniency_and_port_bounds_are_explicit ③）"
    );
}

#[test]
fn cert_parsers_survive_hostile_input() {
    for der in [
        Vec::new(),
        vec![0u8; 1],
        vec![0xff; 64],
        b"not a certificate".to_vec(),
        vec![0x30, 0x82, 0xff, 0xff], // 声称超长但截断
    ] {
        assert!(
            cert_ext::subject_cn_from_der(&der).is_none(),
            "畸形 DER 不应产出 CN（len={}）",
            der.len()
        );
        assert!(cert_ext::validity_from_der(&der).is_none());
    }

    // 非 base64 字符 ⇒ 空（`pem_to_der` 逐字符校验）
    assert!(
        cert_ext::cert_der_from_pem(
            "-----BEGIN CERTIFICATE-----\n*** not b64 ***\n-----END CERTIFICATE-----"
        )
        .is_empty(),
        "含非法 base64 字符的 PEM 应返回空 DER"
    );
    assert!(cert_ext::cert_der_from_pem("garbage").is_empty());

    // 注意：**合法 base64 但不是证书** 会解码出垃圾 DER（长度非 0，这是设计：只做解码不做语义校验）
    // ⇒ 真正的护栏在下游：`subject_cn_from_der` 必须拒绝它（否则会出现「看起来有效的身份」）。
    let not_a_cert = cert_ext::cert_der_from_pem(
        "-----BEGIN CERTIFICATE-----\nbm90IGEgY2VydGlmaWNhdGU=\n-----END CERTIFICATE-----",
    );
    assert!(!not_a_cert.is_empty(), "合法 base64 会被解码（已知口径）");
    assert!(
        cert_ext::subject_cn_from_der(&not_a_cert).is_none(),
        "非证书 DER 不得产出 CN"
    );

    // 自产证书必须能往返（正路径不被上面的防御吞掉）。
    let pair = kdc_native::cert_gen::generate_self_signed_ec(VALID_ID, 10).expect("cert");
    let der = cert_ext::cert_der_from_pem(&pair.cert_pem);
    assert!(!der.is_empty());
    assert_eq!(
        cert_ext::subject_cn_from_der(&der).as_deref(),
        Some(VALID_ID)
    );
}

#[test]
fn device_id_bounds_are_exact() {
    let ok = [
        "a".repeat(32),
        "a".repeat(38),
        "0123456789abcdef0123456789abcdef".to_owned(),
        format!("{}{}", "a".repeat(31), "-"),
        format!("{}{}", "a".repeat(37), "_"),
    ];
    for id in ok {
        assert!(kdc_core::packet::is_valid_device_id(&id), "应合法: {id}");
    }
    let bad = [
        "a".repeat(31),
        "a".repeat(39),
        String::new(),
        format!("{}!", "a".repeat(31)),
        format!("{} ", "a".repeat(31)),
        format!("{}{}", "a".repeat(31), "."),
        format!("{}中文", "a".repeat(28)),
    ];
    for id in bad {
        assert!(!kdc_core::packet::is_valid_device_id(&id), "应非法: {id:?}");
    }
}

#[test]
fn identity_caps_cannot_break_the_frame() {
    // 能力表来自外部（ArkTS 回灌）：带引号/换行/控制字符也不能破坏「一行一个 JSON」的帧约定。
    let incoming = vec![
        "kdeconnect.ping\"]}\n{\"x\":\"1".to_owned(),
        "kdeconnect.\u{7}bell".to_owned(),
        String::new(),
    ];
    let frame = packet::build_identity(VALID_ID, "hostile\"/name", "phone", 1716, &incoming, &[]);
    assert_eq!(
        frame.matches('\n').count(),
        1,
        "identity 帧必须只含一个换行"
    );
    assert!(frame.ends_with('\n'));
    let body = frame.trim_end_matches('\n');
    assert!(body.starts_with('{') && body.ends_with('}'));
    assert!(
        serde_json::from_str::<serde_json::Value>(body).is_ok(),
        "identity 帧必须是合法 JSON（能力项需被转义）"
    );
    assert!(
        packet::parse_identity(body).is_some(),
        "转义后的 identity 仍应可解析"
    );
}

#[test]
fn device_name_sanitizer_never_yields_empty_or_overlong() {
    for raw in [
        "",
        "   ",
        "<<>>",
        "\u{0}\u{1}\u{2}",
        "\n\r\t",
        &"x".repeat(500),
        "中文名 with , ; : . ! ? ( ) [ ] < >",
    ] {
        let name = packet::sanitize_device_name(raw);
        assert!(!name.trim().is_empty(), "不得为空（回退固定名）: {raw:?}");
        assert!(name.chars().count() <= 32, "不得超过 32 字符: {name}");
        assert!(!name.contains('\n'), "不得含换行（帧/日志注入面）: {name}");
    }
}

#[test]
fn addresses_and_ports_survive_hostile_strings() {
    for host in [
        "",
        " ",
        "not a host",
        "999.999.999.999",
        "::1",
        "127.0.0.1\n",
    ] {
        // 不得 panic；非私有地址一律 false。
        assert!(
            !kdc_native::net_util::is_private_ipv4(host),
            "应判非私有: {host:?}"
        );
    }
    assert!(kdc_native::net_util::is_private_ipv4("127.0.0.1"));
    assert!(kdc_native::net_util::is_private_ipv4("192.168.3.4"));

    // 端口探测：非法主机 + 极短超时 ⇒ 0（无监听），且必须**快速返回**（不得挂住门禁）。
    let started = std::time::Instant::now();
    let port = kdc_native::net_util::find_listening_tcp_port("999.999.999.999", 1716, 1764, 50);
    assert_eq!(port, 0);
    assert!(
        started.elapsed() < std::time::Duration::from_secs(5),
        "非法主机探测耗时过长: {:?}",
        started.elapsed()
    );
}

#[test]
fn frame_limits_are_what_the_protocol_says() {
    assert_eq!(packet::frame_limit(true), MAX_IDENTITY_PACKET_SIZE);
    assert_eq!(packet::frame_limit(false), MAX_PACKET_SIZE);
    assert_eq!(MAX_IDENTITY_PACKET_SIZE, 8 * 1024);

    // 上限 0：任何非空行都应判超限（不 panic、不静默吞掉）。
    let mut buf = b"x\n".to_vec();
    let (item, _) = packet::extract_frame_from(&mut buf, 0, 0);
    assert!(matches!(item, Some(Err(()))), "max_size=0 应判超限");
    assert!(buf.is_empty());
}
