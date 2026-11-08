// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! 网络栈生命周期与三个后台线程：TCP listener / UDP discovery / timer。
//!
//! 与旧 C++ 栈的对应关系：
//! - `NetStack::start/stop` → [`Stack::start`] / [`Stack::stop`]；
//! - epoll 事件循环 → 每连接线程 + 定时线程（无共享 I/O 状态，锁只保护内存表）；
//! - 事件出口 → [`Shared::emit_event`] → NAPI TSFN。

use std::io;
use std::net::{TcpListener, UdpSocket};
use std::os::unix::io::FromRawFd;
use std::sync::atomic::Ordering;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

use crate::connection;
use crate::discovery;
use crate::events::emit_connect_error;
use crate::net_util::{find_listening_tcp_port, is_private_ipv4};
use crate::payload;
use crate::state::Shared;
use crate::types::{
    EventType, NetConfig, NetEvent, DISCOVERY_BROADCAST_FAST_COUNT, DISCOVERY_BROADCAST_FAST_MS,
    DISCOVERY_BROADCAST_WHILE_LINKED, DISCOVERY_TIMEOUT_MS, DISCOVERY_LONG_INTERVAL_MS,
    LISTEN_BACKLOG, LOOP_TICK_MS, MAX_UNPAIRED_CONNECTIONS, TCP_PORT_MAX, TCP_PORT_MIN, UDP_PORT,
};
use crate::{loge, logi};

pub struct Stack {
    pub shared: Arc<Shared>,
    threads: Mutex<Vec<std::thread::JoinHandle<()>>>,
}

impl Stack {
    pub fn start(config: NetConfig) -> Result<Arc<Self>, String> {
        Self::start_with(config, std::collections::HashMap::new(), None)
    }

    pub fn start_with(
        config: NetConfig,
        trusted: std::collections::HashMap<String, String>,
        caps: Option<(Vec<String>, Vec<String>)>,
    ) -> Result<Arc<Self>, String> {
        if config.device_id.is_empty() {
            return Err("deviceId is empty".to_owned());
        }
        let tls = crate::tls::build_context(&config.cert_pem, &config.key_pem)?;
        let listener = bind_listener(config.tcp_port)
            .map_err(|e| format!("tcp listen failed: {e}"))?;
        let bound_port = listener
            .local_addr()
            .map_err(|e| format!("tcp local_addr: {e}"))?
            .port();
        let udp_port = if config.udp_port == 0 {
            UDP_PORT
        } else {
            config.udp_port
        };
        let udp = discovery::bind_udp(udp_port)
            .map_err(|e| format!("udp init failed: {e}"))?;
        let shared = Shared::new(config, tls, bound_port);
        // 在启动任何线程之前应用启动前回灌的信任/能力，避免开屏期竞态。
        for (device_id, pem) in trusted {
            shared.set_trusted(&device_id, &pem);
        }
        if let Some((incoming, outgoing)) = caps {
            if let Ok(mut c) = shared.caps_in.lock() {
                *c = incoming;
            }
            if let Ok(mut c) = shared.caps_out.lock() {
                *c = outgoing;
            }
        }
        let stack = Arc::new(Self {
            shared: shared.clone(),
            threads: Mutex::new(Vec::new()),
        });

        // 首次广播（start() 成功即宣告在线）。
        let _ = discovery::broadcast(&udp, udp_port, &shared.identity_frame());

        spawn_thread(
            &stack,
            format!("kdc-listener-{bound_port}"),
            {
                let shared = shared.clone();
                move || listener_loop(shared, listener)
            },
        );
        spawn_thread(&stack, "kdc-discovery".to_owned(), {
            let shared = shared.clone();
            let udp = udp.try_clone().ok();
            move || {
                if let Some(udp) = udp {
                    discovery_loop(shared, udp);
                }
            }
        });
        spawn_thread(&stack, "kdc-timer".to_owned(), {
            let shared = shared.clone();
            move || timer_loop(shared, udp, udp_port)
        });

        logi!(
            "net stack started (full Rust): deviceId={} tcpPort={} udpPort={}",
            shared.config.device_id,
            bound_port,
            udp_port
        );
        Ok(stack)
    }

    pub fn stop(&self) {
        if self.shared.shutdown.swap(true, Ordering::SeqCst) {
            return;
        }
        let ids: Vec<u64> = self
            .shared
            .conns
            .lock()
            .map(|m| m.keys().copied().collect())
            .unwrap_or_default();
        for id in ids {
            self.shared.close_conn(id, "stack stop");
        }
        let handles: Vec<_> = self
            .threads
            .lock()
            .map(|mut h| h.drain(..).collect())
            .unwrap_or_default();
        for handle in handles {
            let _ = handle.join();
        }
        logi!("net stack stopped");
    }

    pub fn send_packet(&self, device_id: &str, packet_json: &str) -> bool {
        self.shared.send_to_device(device_id, packet_json)
    }

    pub fn connect_to_peer(&self, host: String, port: u16) -> bool {
        if host.is_empty() {
            self.shared.emit_error(
                "",
                libc::EINVAL,
                "connectToPeer: host required when port unknown",
                "",
                0,
            );
            return false;
        }
        if port == 0 {
            let shared = self.shared.clone();
            std::thread::Builder::new()
                .name(format!("kdc-probe-{host}"))
                .spawn(move || probe_then_dial(shared, host))
                .ok();
            return true;
        }
        connection::spawn_outgoing(&self.shared, host, port)
    }

    pub fn disconnect(&self, device_id: &str) {
        self.shared.close_device(device_id);
    }

    pub fn set_capabilities(&self, incoming: Vec<String>, outgoing: Vec<String>) {
        if let Ok(mut caps) = self.shared.caps_in.lock() {
            *caps = incoming;
        }
        if let Ok(mut caps) = self.shared.caps_out.lock() {
            *caps = outgoing;
        }
        let identity = self.shared.identity_frame();
        let conns: Vec<_> = self
            .shared
            .conns
            .lock()
            .map(|m| m.values().cloned().collect())
            .unwrap_or_default();
        for conn in conns {
            if conn.connection_state() == crate::types::ConnectionState::Encrypted {
                let _ = self.shared.enqueue_to_conn(&conn, &identity);
            }
        }
        self.shared.force_broadcast.store(true, Ordering::SeqCst);
    }

    pub fn trigger_broadcast(&self) {
        self.shared.force_broadcast.store(true, Ordering::SeqCst);
    }

    pub fn get_peer_certificate(&self, device_id: &str) -> String {
        self.shared.peer_cert_pem(device_id)
    }

    pub fn get_own_certificate(&self) -> String {
        self.shared.config.cert_pem.clone()
    }

    pub fn get_pair_verification_code(&self, device_id: &str, timestamp: i64) -> String {
        self.shared.pair_verification_code(device_id, timestamp)
    }

    pub fn set_trusted_certificate(&self, device_id: &str, cert_pem: &str) {
        self.shared.set_trusted(device_id, cert_pem);
    }

    pub fn remove_trusted_certificate(&self, device_id: &str) {
        self.shared.remove_trusted(device_id);
    }

    pub fn send_payload(
        &self,
        device_id: &str,
        packet_type: &str,
        body_json: &str,
        file_path: &str,
    ) -> u64 {
        payload::start_send(&self.shared, device_id, packet_type, body_json, file_path)
    }

    pub fn keep_payload(&self, transfer_id: u64, dest_path: &str) -> bool {
        payload::settle(&self.shared, transfer_id, dest_path, true)
    }

    pub fn discard_payload(&self, transfer_id: u64) -> bool {
        payload::settle(&self.shared, transfer_id, "", false)
    }

    pub fn cancel_payload(&self, transfer_id: u64) {
        payload::cancel(&self.shared, transfer_id);
    }

    pub fn bound_tcp_port(&self) -> u16 {
        self.shared.bound_tcp_port.load(Ordering::Relaxed)
    }
}

impl Drop for Stack {
    fn drop(&mut self) {
        self.stop();
    }
}

fn spawn_thread(stack: &Arc<Stack>, name: String, f: impl FnOnce() + Send + 'static) {
    match std::thread::Builder::new().name(name).spawn(f) {
        Ok(handle) => {
            if let Ok(mut threads) = stack.threads.lock() {
                threads.push(handle);
            }
        }
        Err(e) => loge!("failed to spawn thread: {e}"),
    }
}

/// 绑定 TCP 监听端口：目标被占时顺序回退到 1764（与 KDE 同款语义）。
fn bind_listener(preferred: u16) -> io::Result<TcpListener> {
    let start = if preferred == 0 {
        TCP_PORT_MIN
    } else {
        preferred
    };
    let end = if preferred == 0 || preferred < TCP_PORT_MAX {
        TCP_PORT_MAX
    } else {
        preferred
    };
    let mut last_err = io::Error::new(io::ErrorKind::AddrInUse, "no free tcp port");
    for port in start..=end {
        // SAFETY: socket(2) 返回 fd；失败路径均 close。
        let fd = unsafe {
            libc::socket(
                libc::AF_INET,
                libc::SOCK_STREAM | libc::SOCK_CLOEXEC,
                0,
            )
        };
        if fd < 0 {
            last_err = io::Error::last_os_error();
            continue;
        }
        let one: libc::c_int = 1;
        // SAFETY: one 是有效 c_int。
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
        // SAFETY: fd 由本函数创建。
        let listening = bound && unsafe { libc::listen(fd, LISTEN_BACKLOG) } == 0;
        if listening {
            // SAFETY: fd 有效且所有权移交给 TcpListener。
            let listener = unsafe { TcpListener::from_raw_fd(fd) };
            listener.set_nonblocking(true)?;
            return Ok(listener);
        }
        last_err = io::Error::last_os_error();
        // SAFETY: fd 由本函数创建且未移交。
        unsafe { libc::close(fd) };
    }
    Err(last_err)
}

fn listener_loop(shared: Arc<Shared>, listener: TcpListener) {
    while !shared.shutdown.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((stream, _)) => {
                let host = stream
                    .peer_addr()
                    .ok()
                    .and_then(|a| match a {
                        std::net::SocketAddr::V4(v4) => Some(v4.ip().to_string()),
                        std::net::SocketAddr::V6(_) => None,
                    })
                    .unwrap_or_default();
                if !is_private_ipv4(&host) {
                    loge!("reject non-private peer {host}");
                    continue;
                }
                if shared.unpaired_count() >= MAX_UNPAIRED_CONNECTIONS {
                    loge!("too many unpaired connections, rejecting {host}");
                    continue;
                }
                connection::spawn_incoming(&shared, stream);
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => {
                loge!("accept failed: {e}");
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
}

fn discovery_loop(shared: Arc<Shared>, udp: UdpSocket) {
    let mut buf = vec![0u8; 16 * 1024];
    while !shared.shutdown.load(Ordering::SeqCst) {
        match discovery::read_identity(&udp, &mut buf) {
            Some((json, host)) => {
                let Some(info) = crate::packet::parse_identity(&json) else {
                    loge!("failed to parse identity from UDP");
                    continue;
                };
                if info.device_id == shared.config.device_id {
                    continue;
                }
                let now = Instant::now();
                if !shared.mark_seen(&info.device_id, now) {
                    continue;
                }
                shared.remember_port(&host, info.tcp_port);
                shared.emit_discovered(
                    &info.device_id,
                    &info.device_name,
                    &info.device_type,
                    &host,
                    info.tcp_port,
                );
                logi!(
                    "device discovered: {} ({}) at {}:{}",
                    info.device_id,
                    info.device_name,
                    host,
                    info.tcp_port
                );
            }
            None => discovery::sleep_poll(),
        }
    }
}

fn timer_loop(shared: Arc<Shared>, udp: UdpSocket, udp_port: u16) {
    let mut last_broadcast = Instant::now();
    let mut broadcast_count = 1u32;
    while !shared.shutdown.load(Ordering::SeqCst) {
        let now = Instant::now();

        // DeviceLost：无活跃链路且 60s 未见广播（有链路则刷新时间戳）。
        let linked = shared.linked_devices();
        let mut lost = Vec::new();
        if let Ok(mut seen) = shared.last_seen.lock() {
            for (device_id, last) in seen.iter_mut() {
                if linked.iter().any(|id| id == device_id) {
                    *last = now;
                    continue;
                }
                if now.duration_since(*last).as_millis() >= u128::from(DISCOVERY_TIMEOUT_MS) {
                    lost.push(device_id.clone());
                }
            }
            for device_id in &lost {
                seen.remove(device_id);
            }
        }
        for device_id in lost {
            logi!("device lost (no broadcast and no link): {device_id}");
            shared.emit_event(NetEvent {
                event_type: EventType::DeviceLost,
                device_id,
                ..Default::default()
            });
        }

        // 周期广播：已建链时默认不播（KDE 收到广播会替换链路）。
        let forced = shared.force_broadcast.swap(false, Ordering::SeqCst);
        let allowed = forced || linked.is_empty() || DISCOVERY_BROADCAST_WHILE_LINKED;
        let interval = if broadcast_count < DISCOVERY_BROADCAST_FAST_COUNT {
            DISCOVERY_BROADCAST_FAST_MS
        } else {
            DISCOVERY_LONG_INTERVAL_MS
        };
        if allowed
            && (forced || now.duration_since(last_broadcast).as_millis() >= u128::from(interval))
        {
            let _ = discovery::broadcast(&udp, udp_port, &shared.identity_frame());
            last_broadcast = now;
            broadcast_count = broadcast_count.saturating_add(1);
        }

        payload::tick(&shared, now);
        std::thread::sleep(Duration::from_millis(LOOP_TICK_MS));
    }
}

fn probe_then_dial(shared: Arc<Shared>, host: String) {
    let min = if shared.config.port_probe_min != 0 {
        shared.config.port_probe_min
    } else {
        TCP_PORT_MIN
    };
    let max = if shared.config.port_probe_max != 0 {
        shared.config.port_probe_max
    } else {
        TCP_PORT_MAX
    };
    let mut port = shared.cached_port(&host);
    if port != 0
        && find_listening_tcp_port(&host, port, port, crate::types::PORT_PROBE_TIMEOUT_MS as i32)
            == 0
    {
        logi!("port cache for {host} is stale ({port}), dropping");
        shared.forget_port(&host);
        port = 0;
    }
    if port == 0 {
        port = find_listening_tcp_port(
            &host,
            min,
            max,
            crate::types::PORT_PROBE_TIMEOUT_MS as i32,
        );
    }
    if port == 0 {
        logi!("port probe: no listener on {host} in {min}-{max}");
        emit_connect_error(&host, 0, libc::EHOSTUNREACH, "port probe");
        return;
    }
    logi!("port resolved for {host}: {port}");
    connection::spawn_outgoing(&shared, host, port);
}

static CURRENT: LazyLock<Mutex<Option<Arc<Stack>>>> = LazyLock::new(|| Mutex::new(None));

pub fn current() -> Option<Arc<Stack>> {
    CURRENT.lock().ok().and_then(|guard| guard.clone())
}

pub fn start_global(config: NetConfig) -> bool {
    start_global_with(config, std::collections::HashMap::new(), None)
}

pub fn start_global_with(
    config: NetConfig,
    trusted: std::collections::HashMap<String, String>,
    caps: Option<(Vec<String>, Vec<String>)>,
) -> bool {
    {
        let guard = match CURRENT.lock() {
            Ok(g) => g,
            Err(_) => return false,
        };
        if guard.is_some() {
            loge!("net stack already running");
            return false;
        }
    }
    match Stack::start_with(config, trusted, caps) {
        Ok(stack) => {
            if let Ok(mut guard) = CURRENT.lock() {
                *guard = Some(stack);
            }
            true
        }
        Err(e) => {
            loge!("net stack start failed: {e}");
            false
        }
    }
}

pub fn stop_global() {
    let stack = CURRENT.lock().ok().and_then(|mut guard| guard.take());
    if let Some(stack) = stack {
        stack.stop();
    }
}

/// 测试辅助：停止并清空全局栈。
pub fn take_global() -> Option<Arc<Stack>> {
    CURRENT.lock().ok().and_then(|mut guard| guard.take())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn listener_falls_back_when_busy() {
        let first = bind_listener(0).unwrap();
        let first_port = first.local_addr().unwrap().port();
        let second = bind_listener(0).unwrap();
        let second_port = second.local_addr().unwrap().port();
        assert_ne!(first_port, second_port);
    }
}
