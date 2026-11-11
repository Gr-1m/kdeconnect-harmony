// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! 二进制 payload 传输（`payload/payload.cpp` 的 Rust 等价）。
//!
//! 协议要点：
//! - 发送方（TLS server）先打开 `payloadTransferInfo.port` 监听并发出控制包，
//!   对端连入后由本机推文件；
//! - 接收方（TLS client）在收到带 payload 元数据的 packet 后回连对端端口；
//! - payload 通道同样校验对端证书 CN == deviceId；
//! - 30s 建连/握手超时、30s 无进展超时、接收完成后的 spool 由 settle 处置。

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::net::{SocketAddrV4, TcpListener, TcpStream};
use std::os::unix::io::FromRawFd;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::state::Shared;
use crate::tls::{self, TlsSession};
use crate::types::{
    EventType, NetEvent, PAYLOAD_ACCEPT_TIMEOUT_MS, PAYLOAD_CHUNK, PAYLOAD_PORT_MIN,
    PAYLOAD_PROGRESS_INTERVAL_MS, PAYLOAD_RECEIVE_KEEP_MS, PAYLOAD_SPOOL_DIR_DEFAULT,
    PAYLOAD_STALL_TIMEOUT_MS, TCP_PORT_MAX,
};
use crate::{loge, logi, logw};

/// `payloadTransfer` 事件的错误码（契约 v0.2 / `DESIGN_FILESHARE_20261110.md` §5）。
/// ArkTS 已按此表消费（`PayloadController.ets` 的 `errorCode === 7` = 对端未取件）。
pub mod code {
    pub const OK: i32 = 0;
    /// 端口连接失败 / 30s 超时（含发送方监听无人连入）。
    pub const PORT_TIMEOUT: i32 = 1;
    /// 通道 TLS 握手/证书/角色失败。
    pub const TLS_FAILED: i32 = 2;
    /// 传输中断（对端提前关闭 / 读写失败 / 无进展）。
    pub const INTERRUPTED: i32 = 3;
    /// 本端文件读失败 / 权限不足。
    pub const READ_FAILED: i32 = 4;
    /// 落盘失败 / 空间不足。
    pub const DISK_FAILED: i32 = 5;
    /// 用户主动取消。
    pub const USER_CANCELLED: i32 = 6;
    /// 对端超时未取件（spool 自动回收）。
    pub const PEER_UNFETCHED: i32 = 7;
}

#[derive(Default)]
struct JobState {
    name: String,
    code: i32,
    message: String,
}

pub struct PayloadJob {
    pub id: u64,
    pub device_id: String,
    pub file_name: String,
    pub send: bool,
    pub total: i64,
    pub done: AtomicI64,
    pub finished: AtomicBool,
    pub finished_at: Mutex<Option<Instant>>,
    state: Mutex<JobState>,
    pub spool_path: Mutex<String>,
    shutdown: AtomicBool,
    socket: Mutex<Option<TcpStream>>,
    deadline: Mutex<Option<Instant>>,
    last_progress: Mutex<Instant>,
    last_progress_event: Mutex<Instant>,
}

impl PayloadJob {
    fn new(id: u64, device_id: String, file_name: String, send: bool, total: i64) -> Self {
        let now = Instant::now();
        Self {
            id,
            device_id,
            file_name,
            send,
            total,
            done: AtomicI64::new(0),
            finished: AtomicBool::new(false),
            finished_at: Mutex::new(None),
            state: Mutex::new(JobState::default()),
            spool_path: Mutex::new(String::new()),
            shutdown: AtomicBool::new(false),
            socket: Mutex::new(None),
            deadline: Mutex::new(Some(now + Duration::from_millis(PAYLOAD_ACCEPT_TIMEOUT_MS))),
            last_progress: Mutex::new(now),
            // 首个分片必须发出一条 progress：否则传输较快时整段一个 progress 都不发
            // （基线 = 创建时刻，而 data 常在 <100ms 内跑完）⇒ UI 行永远停在 `0% · 0 / 总大小`。
            // 把节流基线放到「一个节流窗之前」，等价于「首片必发、其后 100ms 节流」。
            last_progress_event: Mutex::new(
                now.checked_sub(Duration::from_millis(PAYLOAD_PROGRESS_INTERVAL_MS))
                    .unwrap_or(now),
            ),
        }
    }

    fn set_socket(&self, stream: &TcpStream) {
        if let Ok(mut guard) = self.socket.lock() {
            *guard = stream.try_clone().ok();
        }
    }

    fn clear_deadline(&self) {
        if let Ok(mut guard) = self.deadline.lock() {
            *guard = None;
        }
    }

    fn note_progress(&self) -> bool {
        let now = Instant::now();
        if let Ok(mut last) = self.last_progress.lock() {
            *last = now;
        }
        let should_emit = self
            .last_progress_event
            .lock()
            .map(|mut last| {
                if now.duration_since(*last).as_millis()
                    >= u128::from(PAYLOAD_PROGRESS_INTERVAL_MS)
                {
                    *last = now;
                    true
                } else {
                    false
                }
            })
            .unwrap_or(false);
        should_emit
    }

    fn emit(&self, shared: &Shared, state: &str, code: i32, message: &str) {
        let spool = self.spool_path.lock().map(|p| p.clone()).unwrap_or_default();
        if let Ok(mut s) = self.state.lock() {
            s.name = state.to_owned();
            s.code = code;
            s.message = message.to_owned();
        }
        shared.emit_event(NetEvent {
            event_type: EventType::PayloadTransfer,
            device_id: self.device_id.clone(),
            payload_transfer_id: self.id,
            payload_direction_send: self.send,
            payload_state: state.to_owned(),
            payload_file_name: self.file_name.clone(),
            payload_file_path: spool,
            payload_size: self.total,
            payload_bytes_done: self.done.load(Ordering::Relaxed),
            error_code: code,
            error_message: message.to_owned(),
            ..Default::default()
        });
    }

    /// 终态收敛：幂等；失败/取消的接收任务会清理半成品 spool。
    fn finish(&self, shared: &Shared, state: &str, code: i32, message: &str) {
        if self.finished.swap(true, Ordering::SeqCst) {
            return;
        }
        self.shutdown.store(true, Ordering::SeqCst);
        if let Ok(mut at) = self.finished_at.lock() {
            *at = Some(Instant::now());
        }
        if let Ok(guard) = self.socket.lock() {
            if let Some(stream) = guard.as_ref() {
                let _ = stream.shutdown(std::net::Shutdown::Both);
            }
        }
        if !self.send && state != "finished" {
            if let Ok(mut spool) = self.spool_path.lock() {
                if !spool.is_empty() {
                    let _ = fs::remove_file(&*spool);
                    spool.clear();
                }
            }
        }
        self.emit(shared, state, code, message);
        if state == "finished" {
            logi!(
                "[KDC-PAYLOAD] id={} send={} state={} bytes={}",
                self.id,
                self.send,
                state,
                self.done.load(Ordering::Relaxed)
            );
        } else {
            logw!(
                "[KDC-PAYLOAD] id={} send={} state={} code={} msg={}",
                self.id,
                self.send,
                state,
                code,
                message
            );
        }
    }
}

fn valid_device_id(device_id: &str) -> bool {
    kdc_core::packet::is_valid_device_id(device_id)
}

fn bind_payload_listener() -> io::Result<(TcpListener, u16)> {
    for port in PAYLOAD_PORT_MIN..=TCP_PORT_MAX {
        // SAFETY: socket(2) 返回 fd；失败/后续失败路径都会 close。
        let fd = unsafe {
            libc::socket(
                libc::AF_INET,
                libc::SOCK_STREAM | libc::SOCK_CLOEXEC,
                0,
            )
        };
        if fd < 0 {
            continue;
        }
        let one: libc::c_int = 1;
        // SAFETY: one 是有效的 c_int。
        unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_REUSEADDR,
                &one as *const _ as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            );
        }
        let mut addr: libc::sockaddr_in = unsafe { std::mem::zeroed() };
        addr.sin_family = libc::AF_INET as libc::sa_family_t;
        addr.sin_port = port.to_be();
        addr.sin_addr.s_addr = libc::INADDR_ANY;
        // SAFETY: addr 是有效 sockaddr_in。
        let bound = unsafe {
            libc::bind(
                fd,
                &addr as *const _ as *const libc::sockaddr,
                std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
            )
        } == 0;
        let listening = bound && unsafe { libc::listen(fd, 1) } == 0;
        if listening {
            // SAFETY: fd 有效且所有权移交 TcpListener。
            let listener = unsafe { TcpListener::from_raw_fd(fd) };
            listener.set_nonblocking(true)?;
            return Ok((listener, port));
        }
        // SAFETY: fd 由本函数创建且未移交。
        unsafe { libc::close(fd) };
    }
    Err(io::Error::new(
        io::ErrorKind::AddrInUse,
        "no free payload port",
    ))
}

fn spool_dir(shared: &Shared) -> String {
    if shared.config.spool_dir.is_empty() {
        PAYLOAD_SPOOL_DIR_DEFAULT.to_owned()
    } else {
        shared.config.spool_dir.clone()
    }
}

fn body_file_name(body_json: &str) -> String {
    serde_json::from_str::<Value>(body_json)
        .ok()
        .and_then(|v| v.get("filename").and_then(Value::as_str).map(str::to_owned))
        .unwrap_or_default()
}

pub fn start_send(
    shared: &Arc<Shared>,
    device_id: &str,
    packet_type: &str,
    body_json: &str,
    file_path: &str,
) -> u64 {
    if !valid_device_id(device_id) {
        return 0;
    }
    let Ok(meta) = fs::metadata(file_path) else {
        return 0;
    };
    let total = meta.len() as i64;
    let file = match File::open(file_path) {
        Ok(f) => f,
        Err(_) => return 0,
    };

    let (listener, bound) = if total > 0 {
        match bind_payload_listener() {
            Ok(v) => (Some(v.0), v.1),
            Err(e) => {
                loge!("payload send: bind failed: {e}");
                return 0;
            }
        }
    } else {
        (None, 0)
    };

    let body: Value = serde_json::from_str(body_json).unwrap_or_else(|_| json!({}));
    let file_name = body_file_name(body_json);
    let mut root = json!({
        "id": 0,
        "type": packet_type,
        "body": body,
        "payloadSize": total,
    });
    if total > 0 {
        root["payloadTransferInfo"] = json!({ "port": bound });
    }
    let mut frame = serde_json::to_string(&root).unwrap_or_else(|_| "{}".to_owned());
    frame.push('\n');

    if !shared.send_to_device(device_id, &frame) {
        return 0;
    }

    let id = shared.alloc_job_id();
    let job = Arc::new(PayloadJob::new(
        id,
        device_id.to_owned(),
        file_name,
        true,
        total,
    ));
    if let Ok(mut jobs) = shared.jobs.lock() {
        jobs.insert(id, job.clone());
    }
    job.emit(shared, "started", 0, "");

    if total == 0 {
        job.finish(shared, "finished", 0, "");
        return id;
    }

    let shared2 = shared.clone();
    let job2 = job.clone();
    let listener = listener.expect("listener for non-empty payload");
    std::thread::Builder::new()
        .name(format!("kdc-payload-send-{id}"))
        .spawn(move || send_thread(shared2, job2, listener, file))
        .ok();
    id
}

fn send_thread(shared: Arc<Shared>, job: Arc<PayloadJob>, listener: TcpListener, mut file: File) {
    let deadline = Instant::now() + Duration::from_millis(PAYLOAD_ACCEPT_TIMEOUT_MS);
    let mut stream = loop {
        if job.shutdown.load(Ordering::SeqCst) {
            job.finish(&shared, "cancelled", code::USER_CANCELLED, "cancelled by local user");
            return;
        }
        match listener.accept() {
            Ok((stream, _)) => break stream,
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                if Instant::now() > deadline {
                    job.finish(&shared, "failed", code::PORT_TIMEOUT, "payload accept timeout");
                    return;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(_e) => {
                job.finish(&shared, "failed", code::PORT_TIMEOUT, "payload accept failed");
                return;
            }
        }
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(2000)));
    job.set_socket(&stream);

    let mut session = match tls::server_connection(&shared.tls) {
        Ok(c) => TlsSession::Server(c),
        Err(e) => {
            job.finish(&shared, "failed", code::TLS_FAILED, &format!("payload tls init failed: {e}"));
            return;
        }
    };
    if let Err(e) = tls_handshake(&mut session, &mut stream, Duration::from_secs(30)) {
        job.finish(&shared, "failed", code::TLS_FAILED, &format!("payload tls handshake failed: {e}"));
        return;
    }
    job.clear_deadline();
    match session.peer_cn() {
        Some(cn) if cn == job.device_id => {}
        other => {
            job.finish(
                &shared,
                "failed",
                code::TLS_FAILED,
                &format!("payload peer cert mismatch (cn={other:?})"),
            );
            return;
        }
    }

    let mut buf = vec![0u8; PAYLOAD_CHUNK];
    loop {
        if job.shutdown.load(Ordering::SeqCst) {
            job.finish(&shared, "cancelled", code::USER_CANCELLED, "cancelled by local user");
            return;
        }
        let n = match file.read(&mut buf) {
            Ok(0) => {
                if job.total >= 0 && job.done.load(Ordering::Relaxed) < job.total {
                    job.finish(&shared, "failed", code::READ_FAILED, "payload source shorter than payloadSize");
                } else {
                    let _ = tls_flush(&mut session, &mut stream);
                    job.finish(&shared, "finished", 0, "");
                }
                return;
            }
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(_e) => {
                job.finish(&shared, "failed", code::READ_FAILED, "payload source read failed");
                return;
            }
        };
        if let Err(_e) = tls_write_all(&mut session, &mut stream, &buf[..n]) {
            job.finish(&shared, "failed", code::INTERRUPTED, "payload tls write failed");
            return;
        }
        job.done.fetch_add(n as i64, Ordering::Relaxed);
        if job.note_progress() {
            job.emit(&shared, "progress", 0, "");
        }
    }
}

pub fn start_receive(
    shared: &Arc<Shared>,
    device_id: &str,
    host: &str,
    port: u16,
    payload_size: i64,
    body_json: &str,
) -> u64 {
    if !valid_device_id(device_id) {
        return 0;
    }
    let Ok(addr) = format!("{host}:{port}").parse::<SocketAddrV4>() else {
        return 0;
    };
    let dir = spool_dir(shared);
    if fs::create_dir_all(&dir).is_err() {
        return 0;
    }
    let id = shared.alloc_job_id();
    let spool = format!("{dir}/payload_{id}.bin");
    let file = match OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&spool)
    {
        Ok(f) => f,
        Err(e) => {
            loge!("payload receive: spool open failed: {e}");
            return 0;
        }
    };
    let job = Arc::new(PayloadJob::new(
        id,
        device_id.to_owned(),
        body_file_name(body_json),
        false,
        payload_size,
    ));
    if let Ok(mut p) = job.spool_path.lock() {
        *p = spool;
    }
    if let Ok(mut jobs) = shared.jobs.lock() {
        jobs.insert(id, job.clone());
    }
    job.emit(shared, "started", 0, "");

    let shared2 = shared.clone();
    let job2 = job.clone();
    std::thread::Builder::new()
        .name(format!("kdc-payload-recv-{id}"))
        .spawn(move || receive_thread(shared2, job2, addr, file))
        .ok();
    id
}

fn receive_thread(shared: Arc<Shared>, job: Arc<PayloadJob>, addr: SocketAddrV4, mut file: File) {
    let mut stream = match TcpStream::connect_timeout(
        &std::net::SocketAddr::V4(addr),
        Duration::from_millis(PAYLOAD_ACCEPT_TIMEOUT_MS),
    ) {
        Ok(s) => s,
        Err(_e) => {
            job.finish(&shared, "failed", code::PORT_TIMEOUT, "payload connect failed");
            return;
        }
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(2000)));
    job.set_socket(&stream);

    let mut session = match tls::client_connection(&shared.tls, &addr.ip().to_string()) {
        Ok(c) => TlsSession::Client(c),
        Err(e) => {
            job.finish(&shared, "failed", code::TLS_FAILED, &format!("payload tls init failed: {e}"));
            return;
        }
    };
    if let Err(e) = tls_handshake(&mut session, &mut stream, Duration::from_secs(30)) {
        job.finish(&shared, "failed", code::TLS_FAILED, &format!("payload tls handshake failed: {e}"));
        return;
    }
    job.clear_deadline();
    match session.peer_cn() {
        Some(cn) if cn == job.device_id => {}
        other => {
            job.finish(
                &shared,
                "failed",
                code::TLS_FAILED,
                &format!("payload peer cert mismatch (cn={other:?})"),
            );
            return;
        }
    }

    let mut buf = vec![0u8; PAYLOAD_CHUNK];
    let mut eof = false;
    while job.total < 0 || job.done.load(Ordering::Relaxed) < job.total {
        if job.shutdown.load(Ordering::SeqCst) {
            job.finish(&shared, "cancelled", code::USER_CANCELLED, "cancelled by local user");
            return;
        }
        match session.read_tls(&mut stream) {
            Ok(0) => {
                eof = true;
            }
            Ok(_) => {
                if let Err(e) = session.process_new_packets() {
                    job.finish(&shared, "failed", code::INTERRUPTED, &format!("payload tls read failed: {e}"));
                    return;
                }
            }
            Err(e)
                if e.kind() == io::ErrorKind::WouldBlock
                    || e.kind() == io::ErrorKind::TimedOut => {}
            Err(_e) => {
                job.finish(&shared, "failed", code::INTERRUPTED, "payload tls read failed");
                return;
            }
        }
        loop {
            match session.reader_read(&mut buf) {
                Ok(0) => {
                    eof = true;
                    break;
                }
                Ok(n) => {
                    if let Err(_e) = file.write_all(&buf[..n]) {
                        job.finish(&shared, "failed", code::DISK_FAILED, "payload spool write failed");
                        return;
                    }
                    let done = job.done.fetch_add(n as i64, Ordering::Relaxed) + n as i64;
                    if job.note_progress() {
                        job.emit(&shared, "progress", 0, "");
                    }
                    if job.total >= 0 && done >= job.total {
                        break;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(_e) => {
                    job.finish(&shared, "failed", code::INTERRUPTED, "payload tls read failed");
                    return;
                }
            }
        }
        if job.total >= 0 && job.done.load(Ordering::Relaxed) >= job.total {
            job.finish(&shared, "finished", 0, "");
            return;
        }
        if eof {
            if job.total < 0 {
                job.finish(&shared, "finished", 0, "");
            } else {
                job.finish(&shared, "failed", code::INTERRUPTED, "payload peer closed early");
            }
            return;
        }
    }
    job.finish(&shared, "finished", 0, "");
}

fn tls_handshake(
    session: &mut TlsSession,
    stream: &mut TcpStream,
    timeout: Duration,
) -> io::Result<()> {
    let deadline = Instant::now() + timeout;
    while session.is_handshaking() {
        if Instant::now() > deadline {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "handshake timeout"));
        }
        match session.read_tls(stream) {
            Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "eof")),
            Ok(_) => session
                .process_new_packets()
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.to_string()))?,
            Err(e)
                if e.kind() == io::ErrorKind::WouldBlock
                    || e.kind() == io::ErrorKind::TimedOut => {}
            Err(e) => return Err(e),
        }
        tls_flush(session, stream)?;
    }
    tls_flush(session, stream)
}

fn tls_flush(session: &mut TlsSession, stream: &mut TcpStream) -> io::Result<()> {
    loop {
        match session.write_tls(stream) {
            Ok(0) => return Ok(()),
            Ok(_) => {}
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(()),
            Err(e) => return Err(e),
        }
    }
}

fn tls_write_all(
    session: &mut TlsSession,
    stream: &mut TcpStream,
    mut data: &[u8],
) -> io::Result<()> {
    while !data.is_empty() {
        match session.writer_write(data) {
            Ok(0) => {
                tls_flush(session, stream)?;
                std::thread::sleep(Duration::from_millis(2));
            }
            Ok(n) => {
                data = &data[n..];
                tls_flush(session, stream)?;
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                tls_flush(session, stream)?;
                std::thread::sleep(Duration::from_millis(2));
            }
            Err(e) => return Err(e),
        }
    }
    tls_flush(session, stream)
}

pub fn settle(shared: &Shared, id: u64, dest_path: &str, keep: bool) -> bool {
    let job = shared
        .jobs
        .lock()
        .ok()
        .and_then(|jobs| jobs.get(&id).cloned());
    let Some(job) = job else {
        return false;
    };
    if !job.finished.load(Ordering::SeqCst) || job.send {
        return false;
    }
    if keep && (dest_path.is_empty() || dest_path.contains("..")) {
        loge!("payload settle: invalid destPath '{dest_path}' (id={id})");
        return false;
    }
    let spool = job.spool_path.lock().map(|p| p.clone()).unwrap_or_default();
    if spool.is_empty() {
        return false;
    }

    let ok = if !keep {
        fs::remove_file(&spool).is_ok()
    } else {
        match fs::rename(&spool, dest_path) {
            Ok(()) => true,
            Err(_) => copy_then_remove(&spool, dest_path),
        }
    };
    if ok {
        if let Ok(mut jobs) = shared.jobs.lock() {
            jobs.remove(&id);
        }
    }
    ok
}

fn copy_then_remove(src: &str, dst: &str) -> bool {
    let ok = fs::copy(src, dst).is_ok();
    if ok {
        let _ = fs::remove_file(src);
    } else {
        let _ = fs::remove_file(dst);
    }
    ok
}

pub fn cancel(shared: &Shared, id: u64) {
    let job = shared
        .jobs
        .lock()
        .ok()
        .and_then(|jobs| jobs.get(&id).cloned());
    if let Some(job) = job {
        if !job.finished.load(Ordering::SeqCst) {
            job.finish(shared, "cancelled", code::USER_CANCELLED, "cancelled by local user");
        }
    }
}

pub fn on_device_down(shared: &Shared, device_id: &str) {
    let jobs: Vec<Arc<PayloadJob>> = shared
        .jobs
        .lock()
        .map(|jobs| jobs.values().cloned().collect())
        .unwrap_or_default();
    for job in jobs {
        if !job.finished.load(Ordering::SeqCst) && job.device_id == device_id {
            job.finish(shared, "failed", code::INTERRUPTED, "control connection closed");
        }
    }
}

pub fn tick(shared: &Shared, now: Instant) {
    let jobs: Vec<Arc<PayloadJob>> = shared
        .jobs
        .lock()
        .map(|jobs| jobs.values().cloned().collect())
        .unwrap_or_default();
    let mut reap = Vec::new();
    for job in jobs {
        if job.finished.load(Ordering::SeqCst) {
            let finished_at = job.finished_at.lock().ok().and_then(|at| *at);
            if let Some(at) = finished_at {
                let age = now.duration_since(at).as_millis();
                if job.send && age >= u128::from(crate::types::PAYLOAD_JOB_REAP_MS) {
                    reap.push(job.id);
                } else if !job.send && age >= u128::from(PAYLOAD_RECEIVE_KEEP_MS) {
                    // 契约 v0.2 code 7：对端超时未取件（spool 自动回收）。
                    // 任务已 finished，不能再走 finish()（幂等早返回），此处直接补一条 failed 事件，
                    // ArkTS 据此把条目显示为「未取件」。
                    job.emit(
                        shared,
                        "failed",
                        code::PEER_UNFETCHED,
                        "payload spool expired (peer did not fetch)",
                    );
                    if let Ok(spool) = job.spool_path.lock() {
                        if !spool.is_empty() {
                            let _ = fs::remove_file(&*spool);
                        }
                    }
                    reap.push(job.id);
                }
            }
            continue;
        }
        let expired = job
            .deadline
            .lock()
            .ok()
            .and_then(|d| *d)
            .is_some_and(|d| now > d);
        if expired {
            // deadline 覆盖「accept 等待」与「TLS 握手」两段；统一报 1（端口超时），
            // 具体阶段留在 errorMessage。
            job.finish(shared, "failed", code::PORT_TIMEOUT, "payload handshake/accept timeout");
            continue;
        }
        let stalled = job
            .last_progress
            .lock()
            .map(|last| now.duration_since(*last).as_millis() >= u128::from(PAYLOAD_STALL_TIMEOUT_MS))
            .unwrap_or(false);
        if stalled {
            job.finish(shared, "failed", code::INTERRUPTED, "payload stalled (no progress)");
        }
    }
    if !reap.is_empty() {
        if let Ok(mut jobs) = shared.jobs.lock() {
            for id in reap {
                jobs.remove(&id);
            }
        }
    }
}

pub fn job_count(shared: &Arc<Shared>) -> usize {
    shared.jobs.lock().map(|jobs| jobs.len()).unwrap_or(0)
}

/// 保持模块被链接（测试/诊断入口）。
pub fn file_name_of(body_json: &str) -> String {
    body_file_name(body_json)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_progress_event_is_emitted_immediately() {
        // 小文件（如 75B png）通常**只有一个分片**：若首片恰落在 100ms 节流窗内就一个 progress 都不发，
        // UI 行会一直停在 `0% · 0 / 总大小`（MSG229 §2 真机现象）。
        // 约定：首个分片必发、其后按 PAYLOAD_PROGRESS_INTERVAL_MS 节流。
        let job = PayloadJob::new(1, "d".repeat(32), "a.png".to_owned(), false, 75);
        assert!(job.note_progress(), "首个分片必须立即出 progress");
        assert!(!job.note_progress(), "紧随其后的分片应被节流拦住");
    }

    #[test]
    fn filename_extraction() {
        assert_eq!(
            body_file_name(r#"{"filename":"a.jpg","size":1}"#),
            "a.jpg"
        );
        assert_eq!(body_file_name("{}"), "");
    }

    #[test]
    fn payload_listener_binds_range() {
        let (listener, port) = bind_payload_listener().unwrap();
        assert!((PAYLOAD_PORT_MIN..=TCP_PORT_MAX).contains(&port));
        drop(listener);
    }
}
