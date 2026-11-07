// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! 全栈 host 端到端：两套 Rust 栈经真实 TCP/TLS 互联。
//!
//! 覆盖：TLS 角色（拨号方=server / 被拨方=client）、明文+加密 identity、
//! `connected`、`pairingRequest`、packetReceived、信任证书、双向 payload 与 settle。

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use kdc_native::cert_gen;
use kdc_native::events;
use kdc_native::stack::Stack;
use kdc_native::types::{EventType, NetConfig, NetEvent, TlsRole};

fn device_id(ch: char) -> String {
    std::iter::repeat_n(ch, 32).collect()
}

fn config(ch: char, name: &str, tcp_port: u16, udp_port: u16, spool: &str) -> NetConfig {
    let id = device_id(ch);
    let pair = cert_gen::generate_self_signed_ec(&id, 10).expect("cert");
    NetConfig {
        device_id: id,
        device_name: name.to_owned(),
        device_type: "phone".to_owned(),
        cert_pem: pair.cert_pem,
        key_pem: pair.key_pem,
        tcp_port,
        udp_port,
        spool_dir: spool.to_owned(),
        connect_handshake_timeout_ms: 5_000,
        ..Default::default()
    }
}

struct Events(Arc<Mutex<Vec<NetEvent>>>);

impl Events {
    fn new() -> Self {
        let list = Arc::new(Mutex::new(Vec::new()));
        let sink = list.clone();
        events::set_callback(Some(Arc::new(move |ev| {
            if let Ok(mut guard) = sink.lock() {
                guard.push(ev);
            }
        })));
        Self(list)
    }

    fn wait(
        &self,
        timeout: Duration,
        pred: impl Fn(&NetEvent) -> bool,
    ) -> Option<NetEvent> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Ok(guard) = self.0.lock() {
                if let Some(found) = guard.iter().find(|e| pred(e)).cloned() {
                    return Some(found);
                }
            }
            if Instant::now() > deadline {
                return None;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

#[test]
fn two_stacks_connect_pair_and_transfer_payload() {
    let events = Events::new();
    let a_id = device_id('a');
    let b_id = device_id('b');
    let spool_a = "/tmp/kdc-rust-e2e-a";
    let spool_b = "/tmp/kdc-rust-e2e-b";
    let _ = std::fs::remove_dir_all(spool_a);
    let _ = std::fs::remove_dir_all(spool_b);

    let a = Stack::start(config('a', "stack-a", 18080, 19171, spool_a)).expect("start a");
    let b = Stack::start(config('b', "stack-b", 18081, 19172, spool_b)).expect("start b");

    // A 主动拨 B：A = TLS server，B = TLS client。
    assert!(a.connect_to_peer("127.0.0.1".to_owned(), b.bound_tcp_port()));

    let connected_a = events
        .wait(Duration::from_secs(10), |e| {
            e.event_type == EventType::Connected && e.device_id == b_id
        })
        .expect("A should report connected");
    assert_eq!(connected_a.role, TlsRole::Server);
    assert_eq!(connected_a.tcp_port, b.bound_tcp_port());

    let connected_b = events
        .wait(Duration::from_secs(10), |e| {
            e.event_type == EventType::Connected && e.device_id == a_id
        })
        .expect("B should report connected");
    assert_eq!(connected_b.role, TlsRole::Client);

    // 明文 identity 与加密 identity 都会触发 pairingRequest（设备名回填依赖它）。
    assert!(events
        .wait(Duration::from_secs(5), |e| {
            e.event_type == EventType::PairingRequest && e.device_id == a_id
        })
        .is_some());

    // 证书必须可从 TLS 层取到，且 CN == deviceId。
    let peer_of_a = a.get_peer_certificate(&b_id);
    let peer_of_b = b.get_peer_certificate(&a_id);
    assert!(peer_of_a.contains("BEGIN CERTIFICATE"));
    assert!(peer_of_b.contains("BEGIN CERTIFICATE"));
    assert_eq!(
        kdc_native::cert_ext::subject_cn_from_der(&kdc_native::cert_ext::cert_der_from_pem(
            &peer_of_a
        ))
        .as_deref(),
        Some(b_id.as_str())
    );

    // 配对成功后的钉扎回灌（ArkTS TrustStore 等价）。
    a.set_trusted_certificate(&b_id, &peer_of_a);
    b.set_trusted_certificate(&a_id, &peer_of_b);

    // 控制帧：B → A。
    let ping = "{\"id\":1,\"type\":\"kdeconnect.ping\",\"body\":{\"message\":\"hi\"}}\n";
    assert!(b.send_packet(&a_id, ping));
    let received = events
        .wait(Duration::from_secs(5), |e| {
            e.event_type == EventType::PacketReceived && e.packet == ping
        })
        .expect("A should receive ping");
    assert_eq!(received.device_id, b_id);

    // A → B 文件 payload。
    let src = "/tmp/kdc-rust-e2e-src.bin";
    let dest = "/tmp/kdc-rust-e2e-dst.bin";
    let _ = std::fs::remove_file(dest);
    let data: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
    std::fs::write(src, &data).unwrap();

    let start = Instant::now();
    let id = a.send_payload(
        &b_id,
        "kdeconnect.share.request",
        "{\"filename\":\"e2e.bin\"}",
        src,
    );
    assert_ne!(id, 0, "sendPayload should return transfer id");
    let finished = events
        .wait(Duration::from_secs(20), |e| {
            e.event_type == EventType::PayloadTransfer
                && e.payload_state == "finished"
                && !e.payload_direction_send
                && e.payload_transfer_id == id
        })
        .expect("B should finish receiving payload");
    assert_eq!(finished.payload_bytes_done, data.len() as i64);
    assert!(b.keep_payload(id as u64, dest), "keepPayload should succeed");
    let saved = std::fs::read(dest).unwrap();
    assert_eq!(saved, data, "payload bytes must match");
    eprintln!("payload e2e took {:?}", start.elapsed());

    // 断开与停止：A 主动断开应让 B 收到 disconnected。
    a.disconnect(&b_id);
    assert!(events
        .wait(Duration::from_secs(5), |e| {
            e.event_type == EventType::Disconnected && e.device_id == a_id
        })
        .is_some());

    a.stop();
    b.stop();
    events::set_callback(None);
}
