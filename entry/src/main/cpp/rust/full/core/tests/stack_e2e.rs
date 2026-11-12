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
    config_with_cert_id(ch, ch, name, tcp_port, udp_port, spool)
}

/// `cert_ch` 与 `ch` 不同 ⇒ 证书 CN != identity deviceId（负路径用）。
fn config_with_cert_id(
    ch: char,
    cert_ch: char,
    name: &str,
    tcp_port: u16,
    udp_port: u16,
    spool: &str,
) -> NetConfig {
    let id = device_id(ch);
    let pair = cert_gen::generate_self_signed_ec(&device_id(cert_ch), 10).expect("cert");
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

struct Events {
    sink: Arc<Mutex<Vec<NetEvent>>>,
    from: usize,
}

impl Events {
    fn new() -> Self {
        // 全局单例事件汇（`set_callback` 是进程级 ⇒ 多个 `#[test]` 并行时只能装一次）。
        // 每个 `Events` 在**创建时**记录起点索引：`wait` 只看起点之后的事件，
        // 因此「先到的事件」不会被漏掉（这是本文件多用例并行 + 无序到达的前提）。
        static SINK: std::sync::LazyLock<Arc<Mutex<Vec<NetEvent>>>> =
            std::sync::LazyLock::new(|| {
                let list: Arc<Mutex<Vec<NetEvent>>> = Arc::new(Mutex::new(Vec::new()));
                let sink = list.clone();
                events::set_callback(Some(Arc::new(move |ev| {
                    if let Ok(mut guard) = sink.lock() {
                        guard.push(ev);
                    }
                })));
                list
            });
        let sink = SINK.clone();
        let from = sink.lock().map(|g| g.len()).unwrap_or(0);
        Self { sink, from }
    }

    fn wait(&self, timeout: Duration, pred: impl Fn(&NetEvent) -> bool) -> Option<NetEvent> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Ok(guard) = self.sink.lock() {
                if let Some(found) = guard
                    .get(self.from..)
                    .and_then(|tail| tail.iter().find(|e| pred(e)))
                    .cloned()
                {
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
    // 进度事件：接收侧必须**至少发出一条**带非零字节的 progress（MSG229 §2：UI 进度恒 0 的 native 侧一半）。
    let progress = events
        .wait(Duration::from_secs(10), |e| {
            e.event_type == EventType::PayloadTransfer
                && e.payload_state == "progress"
                && !e.payload_direction_send
                && e.device_id == a_id
        })
        .expect("接收侧必须至少发一次 progress 事件");
    assert!(
        progress.payload_bytes_done > 0 && progress.payload_bytes_done <= data.len() as i64,
        "progress 必须带递增的非零字节，实际={}",
        progress.payload_bytes_done
    );
    // 接收侧的 transferId 是**本端局部**编号（不进协议包、不要求对端一致，MSG218 §1.2）
    // ⇒ 必须使用接收事件回填的 id（此前测试用发送侧 id 只是因为「两栈各自从 1 起」的巧合相等）。
    let finished = events
        .wait(Duration::from_secs(20), |e| {
            e.event_type == EventType::PayloadTransfer
                && e.payload_state == "finished"
                && !e.payload_direction_send
        })
        .expect("B should finish receiving payload");
    assert_eq!(finished.payload_bytes_done, data.len() as i64);
    let recv_id = finished.payload_transfer_id;
    assert_ne!(recv_id, 0, "接收侧 transferId 不得为 0");
    // 契约：接收 finished 必须回填 spool 路径（ArkTS 自动保存分支依赖它，MSG220 §3：若为空则整段不执行）。
    assert!(
        finished.payload_file_path.starts_with(spool_b),
        "receive finished 必须带非空 spool 路径，实际={:?}",
        finished.payload_file_path
    );
    assert_eq!(
        std::fs::metadata(&finished.payload_file_path)
            .map(|m| m.len())
            .ok(),
        Some(data.len() as u64),
        "finished 时 spool 文件应已落盘且长度正确"
    );
    assert!(b.keep_payload(recv_id, dest), "keepPayload should succeed");
    let saved = std::fs::read(dest).unwrap();
    assert_eq!(saved, data, "payload bytes must match");
    eprintln!("payload e2e took {:?}", start.elapsed());

    // 取消路径：契约 v0.2 code 6（用户主动取消）。
    let cancel_id = a.send_payload(
        &b_id,
        "kdeconnect.share.request",
        "{\"filename\":\"cancel.bin\"}",
        src,
    );
    assert_ne!(cancel_id, 0, "cancel scenario should get a transfer id");
    a.cancel_payload(cancel_id);
    let cancelled = events
        .wait(Duration::from_secs(5), |e| {
            e.event_type == EventType::PayloadTransfer
                && e.payload_state == "cancelled"
                && e.payload_transfer_id == cancel_id
        })
        .expect("cancelled event expected");
    assert_eq!(
        cancelled.error_code, 6,
        "cancelled must use contract code 6"
    );

    // 断开与停止：A 主动断开应让 B 收到 disconnected。
    a.disconnect(&b_id);
    assert!(events
        .wait(Duration::from_secs(5), |e| {
            e.event_type == EventType::Disconnected && e.device_id == a_id
        })
        .is_some());

    a.stop();
    b.stop();

    // —— 负路径 1：对端证书 CN != identity deviceId ⇒ fail-closed（不得派发 connected） ——
    let a2_id = device_id('c');
    let a2 = Stack::start(config_with_cert_id(
        'c',
        'e', // 证书 CN 用 e，与 identity deviceId(c) 不一致
        "mismatch-a",
        18082,
        19173,
        "/tmp/kdc-rust-e2e-a2",
    ))
    .expect("start a2");
    let b2 = Stack::start(config(
        'd',
        "mismatch-b",
        18083,
        19174,
        "/tmp/kdc-rust-e2e-b2",
    ))
    .expect("start b2");
    assert!(a2.connect_to_peer("127.0.0.1".to_owned(), b2.bound_tcp_port()));
    let err = events
        .wait(Duration::from_secs(8), |e| {
            e.event_type == EventType::Error
                && e.device_id == a2_id
                && e.error_code == kdc_native::errors::CERT_MISMATCH
        })
        .expect("B2 must reject CN mismatch with EACCES");
    assert!(
        err.error_message.contains("CN"),
        "unexpected error message: {}",
        err.error_message
    );
    assert!(
        events
            .wait(Duration::from_secs(1), |e| {
                e.event_type == EventType::Connected && e.device_id == a2_id
            })
            .is_none(),
        "CN mismatch must not produce connected"
    );
    a2.stop();
    b2.stop();

    // —— 负路径 2：信任证书钉扎不符 ⇒ fail-closed（不得派发 connected） ——
    let a3_id = device_id('f');
    let a3 =
        Stack::start(config('f', "pin-a", 18084, 19175, "/tmp/kdc-rust-e2e-a3")).expect("start a3");
    let b3 =
        Stack::start(config('g', "pin-b", 18085, 19176, "/tmp/kdc-rust-e2e-b3")).expect("start b3");
    let wrong = cert_gen::generate_self_signed_ec(&device_id('h'), 10).expect("wrong cert");
    b3.set_trusted_certificate(&a3_id, &wrong.cert_pem);
    assert!(a3.connect_to_peer("127.0.0.1".to_owned(), b3.bound_tcp_port()));
    let err = events
        .wait(Duration::from_secs(8), |e| {
            e.event_type == EventType::Error
                && e.device_id == a3_id
                && e.error_message.contains("certificate mismatch")
        })
        .expect("B3 must reject pinned certificate mismatch");
    assert_eq!(
        err.error_code,
        kdc_native::errors::CERT_MISMATCH,
        "pinning mismatch should be CERT_MISMATCH(201)"
    );
    assert!(
        events
            .wait(Duration::from_secs(1), |e| {
                e.event_type == EventType::Connected && e.device_id == a3_id
            })
            .is_none(),
        "pinning mismatch must not produce connected"
    );
    a3.stop();
    b3.stop();
}

// ---------------------------------------------------------------------------
// 以下用例对应 CodeArts MSG201 对 `b596260` 的评审缺陷（D1/D2/D3 + 103）。
// ---------------------------------------------------------------------------

/// 原始拨号方（KDE 约定：拨号方 = TLS **server**），线序与真实栈一致：
/// 明文 identity → TLS 握手 → 加密 identity。用于注入协议级非法帧。
fn raw_dialer(port: u16, ch: char) -> (std::net::TcpStream, kdc_native::tls::TlsSession) {
    use std::io::Write;

    let id = device_id(ch);
    let pair = cert_gen::generate_self_signed_ec(&id, 10).expect("raw cert");
    let ctx = kdc_native::tls::build_context(&pair.cert_pem, &pair.key_pem).expect("tls ctx");
    let ident = kdc_native::packet::build_identity(&id, "raw-dialer", "phone", 1716, &[], &[]);

    let mut stream = std::net::TcpStream::connect(("127.0.0.1", port)).expect("raw tcp connect");
    stream
        .set_read_timeout(Some(Duration::from_millis(200)))
        .expect("read timeout");
    stream
        .write_all(ident.as_bytes())
        .expect("raw plain identity");
    stream.flush().ok();

    let mut sess = kdc_native::tls::TlsSession::Server(
        kdc_native::tls::server_connection(&ctx).expect("raw server conn"),
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    while sess.is_handshaking() && Instant::now() < deadline {
        match sess.read_tls(&mut stream) {
            Ok(0) => break,
            Ok(_) => {
                sess.process_new_packets().expect("raw tls packets");
            }
            Err(ref e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut => {}
            Err(e) => panic!("raw tls read: {e}"),
        }
        while sess.wants_write() {
            sess.write_tls(&mut stream).expect("raw tls write");
        }
    }
    assert!(
        !sess.is_handshaking(),
        "raw dialer TLS handshake must complete"
    );
    // v8：加密通道内需二次 identity，否则对端按未认证链路处理。
    assert!(raw_send(&mut stream, &mut sess, ident.as_bytes()));
    (stream, sess)
}

/// 写入并在链路已断时返回 false（供「故意撑爆链路」的用例使用）。
fn raw_send(
    stream: &mut std::net::TcpStream,
    sess: &mut kdc_native::tls::TlsSession,
    data: &[u8],
) -> bool {
    let mut off = 0;
    while off < data.len() {
        match sess.writer_write(&data[off..]) {
            Ok(0) => return false,
            Ok(n) => off += n,
            Err(_) => return false,
        }
        while sess.wants_write() {
            if sess.write_tls(stream).is_err() {
                return false;
            }
        }
    }
    true
}

/// 契约 103：重复启动必须派 `ALREADY_STARTED` 事件并返回 false。
#[test]
fn duplicate_start_reports_already_started() {
    let events = Events::new();
    let cfg = config('z', "dup-stack", 18090, 19190, "/tmp/kdc-rust-e2e-dup");
    assert!(
        kdc_native::stack::start_global_with(cfg.clone(), Default::default(), None),
        "first start should succeed"
    );
    assert!(
        !kdc_native::stack::start_global_with(cfg, Default::default(), None),
        "second start must be rejected"
    );
    let err = events
        .wait(Duration::from_secs(2), |e| {
            e.event_type == EventType::Error && e.error_code == kdc_native::errors::ALREADY_STARTED
        })
        .expect("duplicate start must report ALREADY_STARTED(103)");
    assert!(
        err.error_message.contains("already"),
        "unexpected message: {}",
        err.error_message
    );
    kdc_native::stack::stop_global();
}

/// D1：未配对设备发起 payload 请求 ⇒ 202 + FatalLink（断链）。
#[test]
fn untrusted_payload_request_closes_link() {
    let events = Events::new();
    let a_id = device_id('m');
    let b_id = device_id('n');
    let _ = std::fs::remove_dir_all("/tmp/kdc-rust-e2e-ut-a");
    let _ = std::fs::remove_dir_all("/tmp/kdc-rust-e2e-ut-b");
    let a = Stack::start(config(
        'm',
        "untrusted-a",
        18092,
        19192,
        "/tmp/kdc-rust-e2e-ut-a",
    ))
    .expect("start a");
    let b = Stack::start(config(
        'n',
        "untrusted-b",
        18093,
        19193,
        "/tmp/kdc-rust-e2e-ut-b",
    ))
    .expect("start b");
    assert!(a.connect_to_peer("127.0.0.1".to_owned(), b.bound_tcp_port()));
    assert!(
        events
            .wait(Duration::from_secs(10), |e| {
                e.event_type == EventType::Connected && e.device_id == a_id
            })
            .is_some(),
        "未钉扎也应能连接（连通性 ≠ 配对）"
    );

    let src = "/tmp/kdc-rust-e2e-ut-src.bin";
    std::fs::write(src, b"untrusted-payload").unwrap();
    let id = a.send_payload(
        &b_id,
        "kdeconnect.share.request",
        "{\"filename\":\"ut.bin\"}",
        src,
    );
    assert_ne!(id, 0, "sendPayload should allocate a transfer id");

    let err = events
        .wait(Duration::from_secs(10), |e| {
            e.event_type == EventType::Error
                && e.error_code == kdc_native::errors::PROTOCOL_VIOLATION
                && e.error_message.contains("not paired/trusted")
        })
        .expect("untrusted payload must report PROTOCOL_VIOLATION(202)");
    assert_eq!(err.device_id, a_id);
    assert!(
        events
            .wait(Duration::from_secs(10), |e| {
                e.event_type == EventType::Disconnected && e.device_id == b_id
            })
            .is_some(),
        "FatalLink ⇒ 未配对 payload 请求必须断链（A 侧应收到 disconnected）"
    );
    a.stop();
    b.stop();
}

/// D3：非法 JSON ⇒ 104 BAD_JSON（DropPacket），链路保持可用。
#[test]
fn bad_json_is_dropped_without_closing_link() {
    let events = Events::new();
    let raw_id = device_id('p');
    let b = Stack::start(config(
        'q',
        "raw-target-json",
        18094,
        19194,
        "/tmp/kdc-rust-e2e-raw-b",
    ))
    .expect("start b");
    let (mut stream, mut sess) = raw_dialer(b.bound_tcp_port(), 'p');
    assert!(
        events
            .wait(Duration::from_secs(10), |e| {
                e.event_type == EventType::PairingRequest && e.device_id == raw_id
            })
            .is_some(),
        "raw dialer identity should reach the stack"
    );

    assert!(raw_send(&mut stream, &mut sess, b"{not-json}\n"));
    let err = events
        .wait(Duration::from_secs(5), |e| {
            e.event_type == EventType::Error
                && e.device_id == raw_id
                && e.error_code == kdc_native::errors::BAD_JSON
        })
        .expect("invalid JSON must report BAD_JSON(104)");
    assert_eq!(err.device_id, raw_id);

    // DropPacket ⇒ 链路继续：后续一个合法 ping 必须照常派发。
    let ping = "{\"id\":2,\"type\":\"kdeconnect.ping\",\"body\":{}}\n";
    assert!(raw_send(&mut stream, &mut sess, ping.as_bytes()));
    assert!(
        events
            .wait(Duration::from_secs(5), |e| {
                e.event_type == EventType::PacketReceived
                    && e.device_id == raw_id
                    && e.packet == ping
            })
            .is_some(),
        "link must survive a bad JSON frame"
    );
    assert!(
        events
            .wait(Duration::from_secs(1), |e| {
                e.event_type == EventType::Disconnected && e.device_id == raw_id
            })
            .is_none(),
        "DropPacket must not close the link"
    );
    b.stop();
}

/// D2：加密通道内单帧超长 ⇒ 203 + FatalLink（与明文 identity 超长路径一致）。
#[test]
fn oversize_frame_reports_line_too_long() {
    let events = Events::new();
    let raw_id = device_id('r');
    let b = Stack::start(config(
        's',
        "raw-target-oversize",
        18095,
        19195,
        "/tmp/kdc-rust-e2e-ov-b",
    ))
    .expect("start b");
    let (mut stream, mut sess) = raw_dialer(b.bound_tcp_port(), 'r');
    assert!(
        events
            .wait(Duration::from_secs(10), |e| {
                e.event_type == EventType::PairingRequest && e.device_id == raw_id
            })
            .is_some(),
        "raw dialer identity should reach the stack"
    );

    // 填充一条不含 '\n' 的超长帧（> MAX_PACKET_SIZE）。
    let chunk = vec![b'x'; 1024 * 1024];
    let mut sent = 0usize;
    while sent <= kdc_native::limits::MAX_PACKET_SIZE {
        if !raw_send(&mut stream, &mut sess, &chunk) {
            break; // 对端已按 FatalLink 断链
        }
        sent += chunk.len();
    }
    assert!(
        sent > kdc_native::limits::MAX_PACKET_SIZE,
        "test must feed more than one max frame (sent={sent})"
    );
    let err = events
        .wait(Duration::from_secs(20), |e| {
            e.event_type == EventType::Error
                && e.device_id == raw_id
                && e.error_code == kdc_native::errors::LINE_TOO_LONG
        })
        .expect("oversize frame must report LINE_TOO_LONG(203)");
    assert_eq!(err.device_id, raw_id);
    assert!(
        events
            .wait(Duration::from_secs(5), |e| {
                e.event_type == EventType::Disconnected && e.device_id == raw_id
            })
            .is_some(),
        "FatalLink ⇒ 超长帧必须断链"
    );
    b.stop();
}
