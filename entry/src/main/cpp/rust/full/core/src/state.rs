// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! 线程间共享状态：连接注册表、信任存储、发现节流、payload 任务表。
//!
//! 线程模型（全 Rust 版）：
//! - listener / discovery / 每条控制连接 / 每个 payload 传输各自一个线程；
//! - 共享状态只在这一个 `Shared` 里，锁临界区只做内存操作（不做文件/网络 I/O）；
//! - 事件出口 [`Shared::emit_event`] 是唯一派发点（NAPI 层保证线程安全）。

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use crate::connection::{ConnHandle, ConnState};
use crate::events;
use crate::limits::PAYLOAD_SPOOL_DIR_DEFAULT;
use crate::payload::{self, PayloadJob};
use crate::tls::TlsContext;
use crate::types::{
    ConnectionState, EventType, NetConfig, NetEvent, TlsRole, DISCOVERY_DEDUP_EVENT_MS,
    MAX_TX_QUEUE_BYTES,
};

/// transferId 序列号落盘文件名（放在 spool 目录内，与 payload 历史无关）。
///
/// 目的：`payloadTransferId` 只用于本端 transfer 关联（事件回填、keep/discard/cancel 定位），
/// **不进协议包**；但 ArkTS 侧会把它持久化进 payload history，若每次重启都从 1 开始计数，
/// 新传输就会与历史条目**同号**并继承其 `settled=true`（MSG217 缺陷 A）。
/// 故序列号跨进程重启必须单调（MSG218）。
const TRANSFER_SEQ_FILE: &str = ".transfer_seq";

/// 进程内 transferId 分配器（**唯一分配点**）：同进程内多个 `Shared`（共享甚至复用同一 spool 目录）
/// 因此也不会重号；构造时按持久化文件抬高下界，分配时逐次落盘 ⇒ **跨重启单调**。
static NEXT_TRANSFER_ID: AtomicU64 = AtomicU64::new(1);

fn transfer_seq_path(spool_dir: &str) -> PathBuf {
    let dir = if spool_dir.is_empty() {
        PAYLOAD_SPOOL_DIR_DEFAULT
    } else {
        spool_dir
    };
    PathBuf::from(dir).join(TRANSFER_SEQ_FILE)
}

/// 读取文件里的「下一个可用 transferId」（缺失/损坏 ⇒ 1）。
fn read_persisted_next(spool_dir: &str) -> u64 {
    fs::read_to_string(transfer_seq_path(spool_dir))
        .ok()
        .and_then(|text| text.trim().parse::<u64>().ok())
        .unwrap_or(1)
        .max(1)
}

/// 启动时把进程内分配器抬高到「文件里的下一个可用值」（只抬高、不回退）。
fn seed_transfer_id(spool_dir: &str) {
    NEXT_TRANSFER_ID.fetch_max(read_persisted_next(spool_dir), Ordering::Relaxed);
}

/// 落盘「下一个可用 transferId」（分配后立即写：崩溃/杀进程后也不会复用已发出的 id）。
/// 写入失败仅降级为「进程内单调」（不致命，记一条日志）。
fn save_next_job_id(spool_dir: &str, next: u64) {
    let path = transfer_seq_path(spool_dir);
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Err(e) = fs::write(&path, next.to_string()) {
        crate::logw!("transfer seq persist failed ({}): {e}", path.display());
    }
}

pub struct Shared {
    pub config: NetConfig,
    pub tls: TlsContext,
    pub bound_tcp_port: AtomicU16,
    pub caps_in: Mutex<Vec<String>>,
    pub caps_out: Mutex<Vec<String>>,
    pub trusted: Mutex<HashMap<String, String>>,
    /// deviceId → 对端叶证书 PEM（掉线后保留，供验证码/详情查询）。
    pub peer_certs: Mutex<HashMap<String, String>>,
    pub conns: Mutex<HashMap<u64, Arc<ConnHandle>>>,
    /// deviceId → 当前最新连接 id（加密态/握手态均可）。
    pub device_conn: Mutex<HashMap<String, u64>>,
    pub last_discovered: Mutex<HashMap<String, Instant>>,
    pub last_accept: Mutex<HashMap<String, Instant>>,
    pub last_seen: Mutex<HashMap<String, Instant>>,
    /// host → 验证过的对端 TCP 端口（UDP identity / 出向建链成功才写）。
    pub port_cache: Mutex<HashMap<String, u16>>,
    pub jobs: Mutex<HashMap<u64, Arc<PayloadJob>>>,
    pub next_conn_id: AtomicU64,
    pub shutdown: AtomicBool,
    pub force_broadcast: AtomicBool,
}

impl Shared {
    pub fn new(config: NetConfig, tls: TlsContext, bound_tcp_port: u16) -> Arc<Self> {
        // 先按持久化文件抬高 transferId 分配器（需借 config.spool_dir，必须在 config 被移动前）。
        seed_transfer_id(&config.spool_dir);
        Arc::new(Self {
            config,
            tls,
            bound_tcp_port: AtomicU16::new(bound_tcp_port),
            caps_in: Mutex::new(vec![
                "kdeconnect.ping".to_owned(),
                "kdeconnect.identity".to_owned(),
                "kdeconnect.pair".to_owned(),
            ]),
            caps_out: Mutex::new(vec!["kdeconnect.ping".to_owned()]),
            trusted: Mutex::new(HashMap::new()),
            peer_certs: Mutex::new(HashMap::new()),
            conns: Mutex::new(HashMap::new()),
            device_conn: Mutex::new(HashMap::new()),
            last_discovered: Mutex::new(HashMap::new()),
            last_accept: Mutex::new(HashMap::new()),
            last_seen: Mutex::new(HashMap::new()),
            port_cache: Mutex::new(HashMap::new()),
            jobs: Mutex::new(HashMap::new()),
            next_conn_id: AtomicU64::new(1),
            shutdown: AtomicBool::new(false),
            force_broadcast: AtomicBool::new(false),
        })
    }

    pub fn alloc_conn_id(&self) -> u64 {
        self.next_conn_id.fetch_add(1, Ordering::Relaxed)
    }

    /// 分配 transferId：进程内全局自增（同进程多实例不重号），并落盘「下一个可用值」
    /// ⇒ 跨进程重启单调（MSG218）。
    pub fn alloc_job_id(&self) -> u64 {
        let id = NEXT_TRANSFER_ID.fetch_add(1, Ordering::Relaxed);
        save_next_job_id(&self.config.spool_dir, id + 1);
        id
    }

    /// 当前对外 identity（UDP 广播与 TLS 两条路径共用 caps 单一来源）。
    pub fn identity_frame(&self) -> String {
        let incoming = self.caps_in.lock().map(|c| c.clone()).unwrap_or_default();
        let outgoing = self.caps_out.lock().map(|c| c.clone()).unwrap_or_default();
        crate::packet::build_identity(
            &self.config.device_id,
            &self.config.device_name,
            &self.config.device_type,
            self.bound_tcp_port.load(Ordering::Relaxed),
            &incoming,
            &outgoing,
        )
    }

    /// 唯一事件派发口：DeviceDiscovered 2s 去重（UDP + 拨入两条来源会重复告知）。
    pub fn emit_event(&self, event: NetEvent) {
        if event.event_type == EventType::DeviceDiscovered && !event.device_id.is_empty() {
            let now = Instant::now();
            let mut map = match self.last_discovered.lock() {
                Ok(m) => m,
                Err(_) => return,
            };
            if let Some(last) = map.get(&event.device_id) {
                if now.duration_since(*last).as_millis() < u128::from(DISCOVERY_DEDUP_EVENT_MS) {
                    return;
                }
            }
            map.insert(event.device_id.clone(), now);
        }
        events::emit(event);
    }

    pub fn emit_error(&self, device_id: &str, code: i32, message: &str, host: &str, port: u16) {
        crate::logw!(
            "error device={} host={}:{} code={} msg={}",
            if device_id.is_empty() { "?" } else { device_id },
            if host.is_empty() { "?" } else { host },
            port,
            code,
            message
        );
        self.emit_event(NetEvent {
            event_type: EventType::Error,
            device_id: device_id.to_owned(),
            host: host.to_owned(),
            tcp_port: port,
            error_code: code,
            error_message: message.to_owned(),
            ..Default::default()
        });
    }

    pub fn emit_connected(&self, state: &ConnState, is_incoming: bool, host: &str, port: u16) {
        self.emit_event(NetEvent {
            event_type: EventType::Connected,
            device_id: state.device_id.clone(),
            device_name: state.device_name.clone(),
            device_type: state.device_type.clone(),
            host: host.to_owned(),
            tcp_port: if is_incoming { 0 } else { port },
            role: state.role,
            ..Default::default()
        });
    }

    pub fn emit_pairing_request(&self, state: &ConnState, host: &str, port: u16) {
        self.emit_event(NetEvent {
            event_type: EventType::PairingRequest,
            device_id: state.device_id.clone(),
            device_name: state.device_name.clone(),
            device_type: state.device_type.clone(),
            host: host.to_owned(),
            tcp_port: port,
            ..Default::default()
        });
    }

    pub fn emit_discovered(&self, device_id: &str, name: &str, dtype: &str, host: &str, port: u16) {
        self.emit_event(NetEvent {
            event_type: EventType::DeviceDiscovered,
            device_id: device_id.to_owned(),
            device_name: name.to_owned(),
            device_type: dtype.to_owned(),
            host: host.to_owned(),
            tcp_port: port,
            ..Default::default()
        });
    }

    // —————— 连接注册表 ——————

    pub fn register_conn(&self, handle: Arc<ConnHandle>) {
        if let Ok(mut map) = self.conns.lock() {
            map.insert(handle.id, handle);
        }
    }

    pub fn conn(&self, id: u64) -> Option<Arc<ConnHandle>> {
        self.conns.lock().ok()?.get(&id).cloned()
    }

    pub fn conns_with_device(&self, device_id: &str) -> Vec<Arc<ConnHandle>> {
        let Ok(map) = self.conns.lock() else {
            return Vec::new();
        };
        map.values()
            .filter(|c| c.device_id().as_deref() == Some(device_id))
            .cloned()
            .collect()
    }

    pub fn unpaired_count(&self) -> usize {
        let Ok(map) = self.conns.lock() else {
            return 0;
        };
        map.values()
            .filter(|c| c.device_id().is_none_or(|id| id.is_empty()))
            .count()
    }

    pub fn linked_devices(&self) -> Vec<String> {
        let Ok(map) = self.conns.lock() else {
            return Vec::new();
        };
        let mut out: Vec<String> = map
            .values()
            .filter_map(|c| {
                let state = c.state.lock().ok()?;
                if !state.device_id.is_empty() && state.state == ConnectionState::Encrypted {
                    Some(state.device_id.clone())
                } else {
                    None
                }
            })
            .collect();
        out.sort();
        out.dedup();
        out
    }

    /// 设备身份落定后登记最新连接；返回是否需要替换旧链路。
    pub fn bind_device(&self, device_id: &str, conn_id: u64) -> Vec<u64> {
        let mut stale = Vec::new();
        if let Ok(map) = self.conns.lock() {
            for (id, conn) in map.iter() {
                if *id == conn_id {
                    continue;
                }
                if conn.device_id().as_deref() == Some(device_id) {
                    stale.push(*id);
                }
            }
        }
        if let Ok(mut index) = self.device_conn.lock() {
            index.insert(device_id.to_owned(), conn_id);
        }
        stale
    }

    /// 连接线程退出/主动关闭的统一收尾（幂等）。
    ///
    /// `Disconnected` 只在「该设备已无其它存活链路」时派发；链路替换不得误杀在传 payload。
    pub fn finalize_conn(&self, id: u64, reason: &str) {
        let removed = self.conns.lock().ok().and_then(|mut map| map.remove(&id));
        let Some(conn) = removed else {
            return;
        };
        conn.shutdown.store(true, Ordering::SeqCst);
        conn.shutdown_socket();
        let device_id = conn.device_id().unwrap_or_default();
        if device_id.is_empty() {
            crate::logi!("connection closed: {reason} (id={id}, no device id)");
            return;
        }
        let still_alive = self
            .conns
            .lock()
            .map(|map| {
                map.values().any(|c| {
                    c.id != id
                        && c.device_id().as_deref() == Some(device_id.as_str())
                        && !c.shutdown.load(Ordering::SeqCst)
                })
            })
            .unwrap_or(false);
        if !still_alive {
            // 栈停止（shutdown）时不派发 Disconnected：与旧 C++ `stop()` 语义一致，
            // 避免 ArkTS 在主动 stop 后收到一批「设备断开」；payload 也无需逐个判失败。
            if !self.shutdown.load(Ordering::SeqCst) {
                self.emit_event(NetEvent {
                    event_type: EventType::Disconnected,
                    device_id: device_id.clone(),
                    ..Default::default()
                });
                payload::on_device_down(self, &device_id);
            }
            if let Ok(mut index) = self.device_conn.lock() {
                if index.get(&device_id) == Some(&id) {
                    index.remove(&device_id);
                }
            }
        } else {
            crate::logi!("link replaced: {device_id} still has a live link (closed id={id})");
        }
        crate::logi!("connection closed: {reason} (id={id}, device={device_id})");
    }

    /// 主动关闭某条连接（先在注册表移除并派发事件，再 shutdown socket 唤醒读线程）。
    pub fn close_conn(&self, id: u64, reason: &str) {
        if let Some(conn) = self.conn(id) {
            conn.shutdown.store(true, Ordering::SeqCst);
            conn.shutdown_socket();
        }
        self.finalize_conn(id, reason);
    }

    pub fn close_device(&self, device_id: &str) -> bool {
        let conns = self.conns_with_device(device_id);
        let any = !conns.is_empty();
        for conn in conns {
            self.close_conn(conn.id, "disconnect requested");
        }
        any
    }

    /// 向指定连接入队（caps 重发 identity 等定向场景）。
    pub fn enqueue_to_conn(&self, conn: &ConnHandle, frame: &str) -> bool {
        let queued = conn.tx_bytes.load(Ordering::Relaxed);
        if queued + frame.len() > MAX_TX_QUEUE_BYTES {
            return false;
        }
        conn.tx_bytes.fetch_add(frame.len(), Ordering::Relaxed);
        if conn.tx.send(frame.as_bytes().to_vec()).is_err() {
            conn.tx_bytes.fetch_sub(frame.len(), Ordering::Relaxed);
            return false;
        }
        true
    }

    /// 控制帧入队：优先加密链路，其次握手链路（P0-b：握手期只入队，由连接线程 flush）。
    pub fn send_to_device(&self, device_id: &str, frame: &str) -> bool {
        let candidates = self.conns_with_device(device_id);
        let target = candidates
            .iter()
            .find(|c| c.connection_state() == ConnectionState::Encrypted)
            .or_else(|| {
                candidates
                    .iter()
                    .find(|c| c.connection_state() == ConnectionState::TlsHandshake)
            });
        let Some(conn) = target else {
            return false;
        };
        let queued = conn.tx_bytes.load(Ordering::Relaxed);
        if queued + frame.len() > MAX_TX_QUEUE_BYTES {
            self.emit_error(
                device_id,
                crate::errors::SEND_FAILED,
                "sendPacket: tx queue full",
                "",
                0,
            );
            return false;
        }
        conn.tx_bytes.fetch_add(frame.len(), Ordering::Relaxed);
        if conn.tx.send(frame.as_bytes().to_vec()).is_err() {
            conn.tx_bytes.fetch_sub(frame.len(), Ordering::Relaxed);
            return false;
        }
        true
    }

    // —————— 发现/端口缓存 ——————

    pub fn remember_port(&self, host: &str, port: u16) {
        if host.is_empty() || port == 0 {
            return;
        }
        if let Ok(mut map) = self.port_cache.lock() {
            map.insert(host.to_owned(), port);
        }
    }

    pub fn cached_port(&self, host: &str) -> u16 {
        self.port_cache
            .lock()
            .ok()
            .and_then(|m| m.get(host).copied())
            .unwrap_or(0)
    }

    pub fn forget_port(&self, host: &str) {
        if let Ok(mut map) = self.port_cache.lock() {
            map.remove(host);
        }
    }

    pub fn mark_seen(&self, device_id: &str, now: Instant) -> bool {
        let mut map = match self.last_seen.lock() {
            Ok(m) => m,
            Err(_) => return true,
        };
        let first = !map.contains_key(device_id);
        let debounced = !first
            && map
                .get(device_id)
                .is_some_and(|last| now.duration_since(*last).as_millis() < 500);
        map.insert(device_id.to_owned(), now);
        !debounced
    }

    // —————— 证书 ——————

    pub fn peer_cert_pem(&self, device_id: &str) -> String {
        self.peer_certs
            .lock()
            .ok()
            .and_then(|m| m.get(device_id).cloned())
            .or_else(|| {
                self.trusted
                    .lock()
                    .ok()
                    .and_then(|m| m.get(device_id).cloned())
            })
            .unwrap_or_default()
    }

    pub fn remember_peer_cert(&self, device_id: &str, pem: String) {
        if device_id.is_empty() || pem.is_empty() {
            return;
        }
        if let Ok(mut map) = self.peer_certs.lock() {
            map.insert(device_id.to_owned(), pem);
        }
    }

    pub fn trusted_cert(&self, device_id: &str) -> Option<String> {
        self.trusted.lock().ok()?.get(device_id).cloned()
    }

    pub fn set_trusted(&self, device_id: &str, pem: &str) {
        if let Ok(mut map) = self.trusted.lock() {
            map.insert(device_id.to_owned(), pem.to_owned());
        }
    }

    pub fn remove_trusted(&self, device_id: &str) {
        if let Ok(mut map) = self.trusted.lock() {
            map.remove(device_id);
        }
    }

    pub fn peer_cn(&self, device_id: &str) -> Option<String> {
        let pem = self.peer_cert_pem(device_id);
        if pem.is_empty() {
            return None;
        }
        let der = crate::cert_ext::cert_der_from_pem(&pem);
        crate::cert_ext::subject_cn_from_der(&der)
    }

    pub fn pair_verification_code(&self, device_id: &str, timestamp: i64) -> String {
        let peer_pem = self.peer_cert_pem(device_id);
        if peer_pem.is_empty() {
            return String::new();
        }
        let peer_der = crate::cert_ext::cert_der_from_pem(&peer_pem);
        let peer_spki = kdc_core::cert::extract_spki_der(&peer_der);
        let own_der = crate::cert_ext::cert_der_from_pem(&self.config.cert_pem);
        let own_spki = kdc_core::cert::extract_spki_der(&own_der);
        if peer_spki.is_empty() || own_spki.is_empty() {
            return String::new();
        }
        kdc_core::cert::compute_verification_code(&own_spki, &peer_spki, timestamp)
    }
}

/// 连接角色：拨号方 = TLS server，被拨方 = TLS client。
pub fn role_for(is_incoming: bool) -> TlsRole {
    if is_incoming {
        TlsRole::Client
    } else {
        TlsRole::Server
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cert_gen;
    use crate::tls;

    const DEVICE_ID: &str = "0123456789abcdef0123456789abcdef";

    fn ctx() -> TlsContext {
        let pair = cert_gen::generate_self_signed_ec(DEVICE_ID, 10).expect("cert");
        tls::build_context(&pair.cert_pem, &pair.key_pem).expect("tls ctx")
    }

    fn config_with_spool(spool: &str) -> NetConfig {
        NetConfig {
            device_id: DEVICE_ID.to_owned(),
            device_name: "seq-test".to_owned(),
            device_type: "phone".to_owned(),
            spool_dir: spool.to_owned(),
            ..Default::default()
        }
    }

    fn tmp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kdc-seq-{}-{tag}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::create_dir_all(&dir);
        dir
    }

    #[test]
    fn transfer_seq_file_roundtrip_and_corrupt_fallback() {
        let dir = tmp_dir("roundtrip");
        let spool = dir.to_string_lossy().to_string();
        assert_eq!(read_persisted_next(&spool), 1, "文件缺失应回退到 1");
        save_next_job_id(&spool, 7);
        assert_eq!(read_persisted_next(&spool), 7);
        assert_eq!(read_persisted_next(&spool), 7, "重复读取必须一致");
        // 损坏内容 ⇒ 安全回退（不 panic、不产生 0）
        fs::write(transfer_seq_path(&spool), "garbage").unwrap();
        assert_eq!(read_persisted_next(&spool), 1);
        fs::write(transfer_seq_path(&spool), "0").unwrap();
        assert_eq!(read_persisted_next(&spool), 1, "0 不是合法 transferId");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn job_ids_stay_monotonic_across_restarts() {
        let dir = tmp_dir("restart");
        let spool = dir.to_string_lossy().to_string();
        let cfg = config_with_spool(&spool);

        // 第一「次进程」：分配两个 id
        let first = Shared::new(cfg.clone(), ctx(), 0);
        let a1 = first.alloc_job_id();
        let a2 = first.alloc_job_id();
        assert!(a1 < a2);
        drop(first);

        // 把进程内分配器清零 ⇒ 只能靠持久化文件续号（否则本用例会假通过）
        NEXT_TRANSFER_ID.store(1, Ordering::Relaxed);

        // 第二「次进程」：新 id 必须大于上一会话最大值
        let second = Shared::new(cfg, ctx(), 0);
        let b1 = second.alloc_job_id();
        assert!(
            b1 > a2,
            "重启后 transferId 必须 > 上次最大值（{b1} vs {a2}）"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn job_ids_never_repeat_in_process_even_sharing_spool() {
        let dir = tmp_dir("shared");
        let spool = dir.to_string_lossy().to_string();
        let a = Shared::new(config_with_spool(&spool), ctx(), 0);
        let b = Shared::new(config_with_spool(&spool), ctx(), 0);
        let a1 = a.alloc_job_id();
        let b1 = b.alloc_job_id();
        let a2 = a.alloc_job_id();
        assert_ne!(a1, b1, "同进程共享 spool 目录的两个 Shared 不得重号");
        assert_ne!(b1, a2);
        let _ = fs::remove_dir_all(&dir);
    }
}
