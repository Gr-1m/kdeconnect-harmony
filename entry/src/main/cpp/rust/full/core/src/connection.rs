// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! 单条控制链路的状态机：
//! 明文 identity → TLS 握手 → 加密 identity 二次校验 → 帧派发。
//!
//! 角色约定（KDE 三端强制）：拨号方 = TLS server，被拨方 = TLS client。
//! identity 帧不含证书；对端证书只能从 TLS 层取。

use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::events::{emit_connect_error, emit_connect_error_os};
use crate::packet;
use crate::payload;
use crate::state::{role_for, Shared};
use crate::tls::{self, TlsSession};
use crate::types::{
    ConnectionState, EventType, NetEvent, TlsRole, CONN_RATE_LIMIT_MS, MAX_IDENTITY_PACKET_SIZE,
    MAX_PACKET_SIZE, PLAIN_IDENTITY_TIMEOUT_MS,
};
use crate::{loge, logi};

const READ_POLL_MS: u64 = 50;
const PLAIN_READ_POLL_MS: u64 = 10;
const TLS_HANDSHAKE_POLL_MS: u64 = 200;

#[derive(Default, Clone)]
pub struct ConnState {
    pub state: ConnectionState,
    pub device_id: String,
    pub device_name: String,
    pub device_type: String,
    pub cn_verified: bool,
    pub connected_notified: bool,
    pub peer_cert_der: Vec<u8>,
    pub peer_cert_pem: String,
    pub peer_cn: String,
    pub role: TlsRole,
}

pub struct ConnHandle {
    pub id: u64,
    pub is_incoming: bool,
    pub host: String,
    pub port: u16,
    pub state: Mutex<ConnState>,
    pub tx: Sender<Vec<u8>>,
    pub tx_bytes: AtomicUsize,
    pub shutdown: AtomicBool,
    /// 用于跨线程 shutdown（`TcpStream` 的 clone 共享同一 fd；`shutdown` 影响底层 socket）。
    stream: Mutex<Option<TcpStream>>,
}

impl ConnHandle {
    pub fn new(
        id: u64,
        is_incoming: bool,
        host: String,
        port: u16,
        stream: &TcpStream,
        tx: Sender<Vec<u8>>,
    ) -> Self {
        Self {
            id,
            is_incoming,
            host,
            port,
            state: Mutex::new(ConnState {
                state: if is_incoming {
                    ConnectionState::PlainIdentity
                } else {
                    ConnectionState::Idle
                },
                role: role_for(is_incoming),
                ..Default::default()
            }),
            tx,
            tx_bytes: AtomicUsize::new(0),
            shutdown: AtomicBool::new(false),
            stream: Mutex::new(stream.try_clone().ok()),
        }
    }

    pub fn device_id(&self) -> Option<String> {
        self.state
            .lock()
            .ok()
            .map(|s| s.device_id.clone())
            .filter(|id| !id.is_empty())
    }

    pub fn connection_state(&self) -> ConnectionState {
        self.state
            .lock()
            .map(|s| s.state)
            .unwrap_or(ConnectionState::Closed)
    }

    pub fn set_stream(&self, stream: &TcpStream) {
        if let Ok(mut guard) = self.stream.lock() {
            *guard = stream.try_clone().ok();
        }
    }

    pub fn shutdown_socket(&self) {
        if let Ok(guard) = self.stream.lock() {
            if let Some(stream) = guard.as_ref() {
                let _ = stream.shutdown(std::net::Shutdown::Both);
            }
        }
    }
}

/// 入向连接线程入口。
pub fn run_incoming(
    shared: Arc<Shared>,
    handle: Arc<ConnHandle>,
    mut stream: TcpStream,
    rx: Receiver<Vec<u8>>,
) {
    let result = incoming_inner(&shared, &handle, &mut stream, rx);
    if let Err(err) = result {
        if !handle.shutdown.load(Ordering::SeqCst) {
            match err {
                ConnError::Io(e) => {
                    let device = handle.device_id().unwrap_or_default();
                    shared.emit_error(
                        &device,
                        crate::errors::PROTOCOL_VIOLATION,
                        &format!("plain identity read failed: {e}"),
                        &handle.host,
                        0,
                    );
                }
                ConnError::Tls(message) => {
                    let device = handle.device_id().unwrap_or_default();
                    shared.emit_error(
                        &device,
                        crate::errors::PROTOCOL_VIOLATION,
                        &format!("tls handshake failed: {message}"),
                        &handle.host,
                        0,
                    );
                }
                ConnError::Protocol(message) => {
                    let device = handle.device_id().unwrap_or_default();
                    shared.emit_error(&device, protocol_code(&message), &message, &handle.host, 0);
                }
                ConnError::Closed => {}
            }
        }
    }
    shared.finalize_conn(handle.id, "incoming closed");
}

/// 出向连接线程入口（`connect_timeout` 也在这里完成，NAPI 线程不阻塞）。
pub fn run_outgoing(shared: Arc<Shared>, handle: Arc<ConnHandle>, rx: Receiver<Vec<u8>>) {
    let timeout = Duration::from_millis(if shared.config.connect_handshake_timeout_ms > 0 {
        shared.config.connect_handshake_timeout_ms
    } else {
        crate::types::CONNECT_HANDSHAKE_TIMEOUT_MS
    });
    let mut stream = match TcpStream::connect_timeout(
        &match format!("{}:{}", handle.host, handle.port).parse() {
            Ok(addr) => addr,
            Err(_) => {
                emit_connect_error(
                    &handle.host,
                    handle.port,
                    crate::errors::BAD_PARAM,
                    "invalid address",
                );
                shared.finalize_conn(handle.id, "invalid address");
                return;
            }
        },
        timeout,
    ) {
        Ok(stream) => stream,
        Err(e) => {
            emit_connect_error_os(
                &handle.host,
                handle.port,
                crate::errors::PEER_NOT_CONNECTED,
                "connect failed",
                e.raw_os_error().unwrap_or(libc::ECONNREFUSED),
            );
            shared.finalize_conn(handle.id, "connect failed");
            return;
        }
    };
    logi!(
        "outgoing tcp connected to {}:{} (id={})",
        handle.host,
        handle.port,
        handle.id
    );
    handle.set_stream(&stream);
    let result = outgoing_inner(&shared, &handle, &mut stream, rx);
    if let Err(err) = result {
        if !handle.shutdown.load(Ordering::SeqCst) {
            match err {
                ConnError::Io(e) => {
                    emit_connect_error_os(
                        &handle.host,
                        handle.port,
                        crate::errors::PEER_NOT_CONNECTED,
                        "connect failed",
                        e.raw_os_error().unwrap_or(libc::EIO),
                    );
                }
                ConnError::Tls(message) => {
                    emit_connect_error(
                        &handle.host,
                        handle.port,
                        crate::errors::PROTOCOL_VIOLATION,
                        &format!("tls handshake failed: {message}"),
                    );
                }
                ConnError::Protocol(message) => {
                    let device = handle.device_id().unwrap_or_default();
                    shared.emit_error(
                        &device,
                        protocol_code(&message),
                        &message,
                        &handle.host,
                        handle.port,
                    );
                }
                ConnError::Closed => {
                    logi!(
                        "outgoing peer closed before/without TLS handshake ({}:{}, device={:?})",
                        handle.host,
                        handle.port,
                        handle.device_id()
                    );
                }
            }
        }
    }
    shared.finalize_conn(handle.id, "outgoing closed");
}

/// `ConnError::Protocol` 文案 → kcbridge 错误码（`contract/errors.v1.json`）。
/// 依据 MAP_ERRORCODE_KCBRIDGE §2：证书类→201、超长→203、身份非法→204、其余协议违例→202。
fn protocol_code(message: &str) -> i32 {
    let m = message.to_ascii_lowercase();
    if m.contains("cert") || m.contains("cn ") || m.contains("cn=") || m.contains("cn !=") {
        crate::errors::CERT_MISMATCH
    } else if m.contains("too large") {
        crate::errors::LINE_TOO_LONG
    } else if m.contains("from self") || m.contains("rate limited") {
        crate::errors::PROTOCOL_VIOLATION
    } else if m.contains("identity") {
        crate::errors::IDENTITY_INVALID
    } else {
        crate::errors::PROTOCOL_VIOLATION
    }
}

#[derive(Debug)]
enum ConnError {
    Io(io::Error),
    Tls(String),
    Protocol(String),
    Closed,
}

impl From<io::Error> for ConnError {
    fn from(e: io::Error) -> Self {
        ConnError::Io(e)
    }
}

fn incoming_inner(
    shared: &Arc<Shared>,
    handle: &Arc<ConnHandle>,
    stream: &mut TcpStream,
    rx: Receiver<Vec<u8>>,
) -> Result<(), ConnError> {
    stream.set_read_timeout(Some(Duration::from_millis(TLS_HANDSHAKE_POLL_MS)))?;
    stream.set_write_timeout(Some(Duration::from_millis(2000)))?;

    let frame = read_plain_identity(stream, PLAIN_IDENTITY_TIMEOUT_MS)?;
    let text = std::str::from_utf8(&frame)
        .map_err(|_| ConnError::Protocol("plain identity is not UTF-8".to_owned()))?;
    let info = packet::parse_identity(text)
        .ok_or_else(|| ConnError::Protocol("invalid plain identity frame".to_owned()))?;
    if info.device_id == shared.config.device_id {
        return Err(ConnError::Protocol("plain identity from self".to_owned()));
    }

    // 同设备已有存活链路 ⇒ 合法替换，跳过限流。
    let same_alive = !shared.conns_with_device(&info.device_id).is_empty();
    if !same_alive {
        let now = Instant::now();
        let key = format!("{}|{}", handle.host, info.device_id);
        let too_soon = shared
            .last_accept
            .lock()
            .ok()
            .and_then(|mut map| {
                let previous = map.get(&key).copied();
                map.insert(key, now);
                previous
            })
            .is_some_and(|prev| {
                now.duration_since(prev).as_millis() < u128::from(CONN_RATE_LIMIT_MS)
            });
        if too_soon {
            return Err(ConnError::Protocol(
                "connection rate limited (retry later)".to_owned(),
            ));
        }
    }

    {
        let mut state = handle
            .state
            .lock()
            .map_err(|_| ConnError::Protocol("state poisoned".to_owned()))?;
        state.state = ConnectionState::TlsHandshake;
        state.device_id = info.device_id.clone();
        state.device_name = info.device_name.clone();
        state.device_type = info.device_type.clone();
    }
    shared.remember_port(&handle.host, info.tcp_port);
    shared.emit_discovered(
        &info.device_id,
        &info.device_name,
        &info.device_type,
        &handle.host,
        info.tcp_port,
    );
    if let Ok(state) = handle.state.lock() {
        shared.emit_pairing_request(&state, &handle.host, handle.port);
    }

    // 入向 = TLS client。
    let mut session = TlsSession::Client(
        tls::client_connection(&shared.tls, &handle.host)
            .map_err(|e| ConnError::Tls(e.to_string()))?,
    );
    handshake(&mut session, stream, shared_handshake_timeout(shared))?;
    logi!(
        "incoming tls client handshake done ({}:{}, cn={:?})",
        handle.host,
        handle.port,
        session.peer_cn()
    );

    let leaf = session.peer_leaf().unwrap_or_default();
    let cn = session.peer_cn().unwrap_or_default();
    if cn.is_empty() || cn != info.device_id {
        return Err(ConnError::Protocol("peer cert CN != deviceId".to_owned()));
    }
    if let Some(trusted) = shared.trusted_cert(&info.device_id) {
        let trusted_der = crate::cert_ext::cert_der_from_pem(&trusted);
        if leaf != trusted_der {
            // 只返回 Protocol，由 run_incoming 的统一错误出口派发一次 error 事件；
            // 这里再 emit 会导致 ArkTS 收到重复错误（实测出现过两条）。
            return Err(ConnError::Protocol(
                "certificate mismatch (device re-pair required)".to_owned(),
            ));
        }
    }
    let pem = crate::cert_ext::cert_pem_from_der(&leaf);
    {
        let mut state = handle
            .state
            .lock()
            .map_err(|_| ConnError::Protocol("state poisoned".to_owned()))?;
        state.state = ConnectionState::Encrypted;
        state.cn_verified = true;
        state.peer_cert_der = leaf;
        state.peer_cert_pem = pem.clone();
        state.peer_cn = cn;
        if !state.connected_notified {
            state.connected_notified = true;
            shared.remember_peer_cert(&state.device_id, pem.clone());
            shared.emit_connected(&state, true, &handle.host, handle.port);
        }
    }

    let mut pending = Vec::new();
    pending.extend_from_slice(shared.identity_frame().as_bytes());
    read_loop(shared, handle, stream, rx, session, pending)
}

fn outgoing_inner(
    shared: &Arc<Shared>,
    handle: &Arc<ConnHandle>,
    stream: &mut TcpStream,
    rx: Receiver<Vec<u8>>,
) -> Result<(), ConnError> {
    stream.set_read_timeout(Some(Duration::from_millis(TLS_HANDSHAKE_POLL_MS)))?;
    stream.set_write_timeout(Some(Duration::from_millis(2000)))?;

    // 拨号方先发明文 identity，再起 TLS server 握手。
    stream.write_all(shared.identity_frame().as_bytes())?;
    logi!(
        "outgoing plain identity sent to {}:{}",
        handle.host,
        handle.port
    );
    {
        let mut state = handle
            .state
            .lock()
            .map_err(|_| ConnError::Protocol("state poisoned".to_owned()))?;
        state.state = ConnectionState::TlsHandshake;
    }

    let mut session = TlsSession::Server(
        tls::server_connection(&shared.tls).map_err(|e| ConnError::Tls(e.to_string()))?,
    );
    handshake(&mut session, stream, shared_handshake_timeout(shared))?;
    logi!(
        "outgoing tls server handshake done ({}:{}, cn={:?})",
        handle.host,
        handle.port,
        session.peer_cn()
    );

    let leaf = session.peer_leaf().unwrap_or_default();
    let cn = session.peer_cn().unwrap_or_default();
    {
        let mut state = handle
            .state
            .lock()
            .map_err(|_| ConnError::Protocol("state poisoned".to_owned()))?;
        state.peer_cert_der = leaf;
        state.peer_cert_pem = if state.peer_cert_der.is_empty() {
            String::new()
        } else {
            crate::cert_ext::cert_pem_from_der(&state.peer_cert_der)
        };
        state.peer_cn = cn;
    }

    let mut pending = Vec::new();
    pending.extend_from_slice(shared.identity_frame().as_bytes());
    read_loop(shared, handle, stream, rx, session, pending)
}

fn shared_handshake_timeout(shared: &Shared) -> Duration {
    Duration::from_millis(if shared.config.connect_handshake_timeout_ms > 0 {
        shared.config.connect_handshake_timeout_ms
    } else {
        crate::types::CONNECT_HANDSHAKE_TIMEOUT_MS
    })
}

/// 非阻塞式读一个明文 identity 帧：`peek` 定位 `\n` 后只消费这一帧，
/// 避免把紧随其后的 TLS 记录头吞进明文缓冲。
fn read_plain_identity(stream: &mut TcpStream, timeout_ms: u64) -> Result<Vec<u8>, ConnError> {
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let mut peek = [0u8; MAX_IDENTITY_PACKET_SIZE + 1];
    loop {
        if Instant::now() > deadline {
            return Err(ConnError::Io(io::Error::new(
                io::ErrorKind::TimedOut,
                "plain identity timeout",
            )));
        }
        match stream.peek(&mut peek) {
            Ok(0) => {
                return Err(ConnError::Closed);
            }
            Ok(n) => {
                if let Some(pos) = peek[..n].iter().position(|&b| b == b'\n') {
                    let want = pos + 1;
                    let mut frame = vec![0u8; want];
                    let mut filled = 0;
                    while filled < want {
                        match stream.read(&mut frame[filled..]) {
                            Ok(0) => return Err(ConnError::Closed),
                            Ok(read) => filled += read,
                            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                            Err(e) => return Err(ConnError::Io(e)),
                        }
                    }
                    return Ok(frame);
                }
                if n >= MAX_IDENTITY_PACKET_SIZE {
                    return Err(ConnError::Protocol(
                        "plain identity frame too large".to_owned(),
                    ));
                }
                std::thread::sleep(Duration::from_millis(PLAIN_READ_POLL_MS));
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(PLAIN_READ_POLL_MS));
            }
            Err(e) if e.kind() == io::ErrorKind::TimedOut => {}
            Err(e) => return Err(ConnError::Io(e)),
        }
    }
}

fn handshake(
    session: &mut TlsSession,
    stream: &mut TcpStream,
    timeout: Duration,
) -> Result<(), ConnError> {
    let deadline = Instant::now() + timeout;
    while session.is_handshaking() {
        if Instant::now() > deadline {
            return Err(ConnError::Tls("handshake timeout".to_owned()));
        }
        match session.read_tls(stream) {
            Ok(0) => return Err(ConnError::Closed),
            Ok(_) => {
                session
                    .process_new_packets()
                    .map_err(|e| ConnError::Tls(e.to_string()))?;
            }
            Err(e)
                if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut => {
            }
            Err(e) => return Err(ConnError::Io(e)),
        }
        flush_tls(session, stream)?;
    }
    flush_tls(session, stream)
}

fn flush_tls(session: &mut TlsSession, stream: &mut TcpStream) -> Result<(), ConnError> {
    loop {
        match session.write_tls(stream) {
            Ok(0) => return Ok(()),
            Ok(_) => {}
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(()),
            Err(e) => return Err(ConnError::Io(e)),
        }
    }
}

fn read_loop(
    shared: &Arc<Shared>,
    handle: &Arc<ConnHandle>,
    stream: &mut TcpStream,
    rx: Receiver<Vec<u8>>,
    mut session: TlsSession,
    mut pending_out: Vec<u8>,
) -> Result<(), ConnError> {
    stream.set_read_timeout(Some(Duration::from_millis(READ_POLL_MS)))?;
    let mut rx_buf: Vec<u8> = Vec::new();
    // 帧切分游标：已确认「不含 '\n'」的缓冲前缀长度（见步骤 5）。
    let mut scan_from: usize = 0;

    loop {
        if handle.shutdown.load(Ordering::SeqCst) {
            return Ok(());
        }
        // 1) 先把待发帧交给 TLS 引擎并泵出
        drain_out(&mut session, stream, &rx, &mut pending_out, handle)?;
        flush_tls(&mut session, stream)?;

        // 2) 读 TLS 记录（read timeout 让循环有机会处理写队列/关闭）
        match session.read_tls(stream) {
            Ok(0) => break,
            Ok(_) => {
                if let Err(e) = session.process_new_packets() {
                    return Err(ConnError::Tls(e.to_string()));
                }
            }
            Err(e)
                if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut => {
            }
            Err(e) => return Err(ConnError::Io(e)),
        }

        // 3) 排空解密后的应用数据
        loop {
            let mut buf = [0u8; 16 * 1024];
            match session.reader_read(&mut buf) {
                Ok(0) => break,
                Ok(n) => rx_buf.extend_from_slice(&buf[..n]),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(ConnError::Io(e)),
            }
        }

        // 4) 握手完成当次也要排空（对端常把 identity 紧跟在握手后）
        drain_out(&mut session, stream, &rx, &mut pending_out, handle)?;
        flush_tls(&mut session, stream)?;

        // 5) 按 '\n' 切帧并派发。
        //    `scan_from` = 已确认「不含 '\n'」的前缀长度：每轮只扫新增字节，
        //    否则一条 32 MiB 的无换行帧会被反复从头扫描（O(n²)，实测单连接烧 ~100 s CPU）。
        loop {
            let (item, next_from) =
                packet::extract_frame_from(&mut rx_buf, MAX_PACKET_SIZE, scan_from);
            scan_from = next_from;
            match item {
                None => break,
                Some(Ok(frame)) => {
                    if handle_frame(shared, handle, &frame).is_err() {
                        return Ok(());
                    }
                }
                Some(Err(())) => {
                    // 契约 203 LINE_TOO_LONG：disposition=FatalLink ⇒ 派事件 + 断链
                    // （与明文 identity 超长路径行为一致）。
                    let device_id = handle.device_id().unwrap_or_default();
                    shared.emit_error(
                        &device_id,
                        crate::errors::LINE_TOO_LONG,
                        "frame exceeds max size",
                        &handle.host,
                        handle.port,
                    );
                    shared.close_conn(handle.id, "line too long");
                    return Ok(());
                }
            }
        }
    }
    Ok(())
}

fn drain_out(
    session: &mut TlsSession,
    stream: &mut TcpStream,
    rx: &Receiver<Vec<u8>>,
    pending: &mut Vec<u8>,
    handle: &ConnHandle,
) -> Result<(), ConnError> {
    while let Ok(frame) = rx.try_recv() {
        let _ = handle.tx_bytes.fetch_sub(frame.len(), Ordering::Relaxed);
        pending.extend_from_slice(&frame);
    }
    while !pending.is_empty() {
        match session.writer_write(pending) {
            Ok(0) => break,
            Ok(n) => {
                pending.drain(..n);
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
            Err(e) => return Err(ConnError::Io(e)),
        }
    }
    // 兜底：如果引擎仍有待写记录，flush_tls 已在调用点执行。
    let _ = stream;
    Ok(())
}

fn handle_frame(shared: &Arc<Shared>, handle: &Arc<ConnHandle>, frame: &[u8]) -> Result<(), ()> {
    let text = match std::str::from_utf8(frame) {
        Ok(t) => t,
        Err(_) => {
            loge!("invalid UTF-8 frame dropped (id={})", handle.id);
            return Ok(());
        }
    };
    let json = text.trim_end_matches('\n');
    if json.is_empty() {
        return Ok(());
    }
    let parsed = match packet::parse_packet(json) {
        Some(p) => p,
        None => {
            // 契约 104 BAD_JSON：disposition=DropPacket ⇒ 派事件、链路继续。
            let device_id = handle.device_id().unwrap_or_default();
            shared.emit_error(
                &device_id,
                crate::errors::BAD_JSON,
                "invalid JSON frame",
                &handle.host,
                handle.port,
            );
            return Ok(());
        }
    };

    if parsed.r#type == "kdeconnect.identity" {
        if let Some(info) = packet::parse_identity(json) {
            if info.device_id == shared.config.device_id {
                return Err(());
            }
            logi!(
                "peer identity over TLS: {} ({}) from {}:{}",
                info.device_id,
                info.device_name,
                handle.host,
                handle.port
            );
            let first_time = handle.device_id().is_none();
            if first_time {
                let (leaf, cn) = {
                    let state = handle.state.lock().map_err(|_| ())?;
                    (state.peer_cert_der.clone(), state.peer_cn.clone())
                };
                if cn.is_empty() || cn != info.device_id {
                    shared.emit_error(
                        &info.device_id,
                        crate::errors::CERT_MISMATCH,
                        "peer cert CN != deviceId",
                        &handle.host,
                        handle.port,
                    );
                    shared.close_conn(handle.id, "cert CN mismatch");
                    return Err(());
                }
                if let Some(trusted) = shared.trusted_cert(&info.device_id) {
                    let trusted_der = crate::cert_ext::cert_der_from_pem(&trusted);
                    if leaf != trusted_der {
                        shared.emit_error(
                            &info.device_id,
                            crate::errors::CERT_MISMATCH,
                            "certificate mismatch (device re-pair required)",
                            &handle.host,
                            handle.port,
                        );
                        shared.close_conn(handle.id, "certificate mismatch");
                        return Err(());
                    }
                }
                {
                    let mut state = handle.state.lock().map_err(|_| ())?;
                    state.device_id = info.device_id.clone();
                    state.device_name = info.device_name.clone();
                    state.device_type = info.device_type.clone();
                    state.cn_verified = true;
                    if !state.peer_cert_der.is_empty() {
                        state.peer_cert_pem =
                            crate::cert_ext::cert_pem_from_der(&state.peer_cert_der);
                    }
                }
                shared.remember_peer_cert(&info.device_id, {
                    let state = handle.state.lock().map_err(|_| ())?;
                    state.peer_cert_pem.clone()
                });
                // 先登记新链路，再关闭同设备旧链路（顺序不可颠倒）。
                shared.bind_device(&info.device_id, handle.id);
                for stale in shared.conns_with_device(&info.device_id) {
                    if stale.id != handle.id {
                        shared.close_conn(stale.id, "replaced by newer link");
                    }
                }
                if !handle.is_incoming {
                    shared.remember_port(&handle.host, handle.port);
                }
            } else {
                if let Ok(mut state) = handle.state.lock() {
                    state.device_name = info.device_name.clone();
                    state.device_type = info.device_type.clone();
                }
            }

            let snapshot = {
                let mut state = handle.state.lock().map_err(|_| ())?;
                let notify = !state.connected_notified;
                if notify {
                    state.connected_notified = true;
                }
                (state.clone(), notify)
            };
            shared.emit_pairing_request(&snapshot.0, &handle.host, handle.port);
            if snapshot.1 {
                shared.emit_connected(&snapshot.0, handle.is_incoming, &handle.host, handle.port);
            }
        }
    }

    // identity 帧也要继续走 packetReceived（ArkTS 的 caps 协商依赖它）。
    let mut transfer_id = 0u64;
    let device_id = handle.device_id().unwrap_or_default();
    if parsed.payload_size != 0 && parsed.payload_port != 0 && !device_id.is_empty() {
        let trusted = shared.trusted_cert(&device_id).is_some();
        if trusted {
            transfer_id = payload::start_receive(
                shared,
                &device_id,
                &handle.host,
                parsed.payload_port,
                parsed.payload_size,
                &parsed.body,
            );
        } else {
            // 契约 202 disposition=FatalLink：未配对设备发 payload 请求 ⇒ 派事件 + 断链
            // （AGENTS.md：未配对设备只收 `kdeconnect.pair`，其余丢弃并 unpair）。
            shared.emit_error(
                &device_id,
                crate::errors::PROTOCOL_VIOLATION,
                "payload rejected: device not paired/trusted",
                &handle.host,
                0,
            );
            shared.close_conn(handle.id, "payload request from untrusted peer");
            return Err(());
        }
    }
    if parsed.payload_size != 0 && transfer_id == 0 {
        // 端口缺失属「payload 超时」类（401, DropPacket）⇒ 只派事件；
        // 其余（deviceId 未知/未受信，见上一条 FatalLink 分支）属策略拒绝（202）⇒ 派事件 + 断链。
        if parsed.payload_port == 0 {
            shared.emit_error(
                &device_id,
                crate::errors::PAYLOAD_TIMEOUT,
                "payload not started (port missing/0)",
                &handle.host,
                0,
            );
        } else {
            shared.emit_error(
                &device_id,
                crate::errors::PROTOCOL_VIOLATION,
                "payload not started (deviceId unknown)",
                &handle.host,
                0,
            );
            shared.close_conn(handle.id, "payload request from unknown/untrusted peer");
            return Err(());
        }
    }

    shared.emit_event(NetEvent {
        event_type: EventType::PacketReceived,
        device_id,
        packet: text.to_owned(),
        payload_size: parsed.payload_size,
        payload_transfer_port: parsed.payload_port,
        payload_transfer_id: transfer_id,
        ..Default::default()
    });
    Ok(())
}

/// 监听线程调用：登记并启动一条入向连接。
pub fn spawn_incoming(shared: &Arc<Shared>, stream: TcpStream) -> bool {
    let host = stream
        .peer_addr()
        .ok()
        .and_then(|a| match a {
            std::net::SocketAddr::V4(v4) => Some(v4.ip().to_string()),
            std::net::SocketAddr::V6(_) => None,
        })
        .unwrap_or_default();
    let (tx, rx) = std::sync::mpsc::channel();
    let id = shared.alloc_conn_id();
    let handle = Arc::new(ConnHandle::new(id, true, host, 0, &stream, tx));
    shared.register_conn(handle.clone());
    let shared2 = shared.clone();
    std::thread::Builder::new()
        .name(format!("kdc-in-{id}"))
        .spawn(move || run_incoming(shared2, handle, stream, rx))
        .is_ok()
}

/// 由 NAPI 线程/栈调用：构造并登记一条出向连接。
pub fn spawn_outgoing(shared: &Arc<Shared>, host: String, port: u16) -> bool {
    // 真正连接在 run_outgoing 内做；stream 建立后由 `set_stream` 补登记（供跨线程 shutdown）。
    let (tx, rx) = std::sync::mpsc::channel();
    let id = shared.alloc_conn_id();
    let handle = Arc::new(ConnHandle {
        id,
        is_incoming: false,
        host,
        port,
        state: Mutex::new(ConnState {
            state: ConnectionState::Idle,
            role: TlsRole::Server,
            ..Default::default()
        }),
        tx,
        tx_bytes: AtomicUsize::new(0),
        shutdown: AtomicBool::new(false),
        stream: Mutex::new(None),
    });
    shared.register_conn(handle.clone());
    let shared2 = shared.clone();
    std::thread::Builder::new()
        .name(format!("kdc-out-{id}"))
        .spawn(move || run_outgoing(shared2, handle, rx))
        .is_ok()
}
