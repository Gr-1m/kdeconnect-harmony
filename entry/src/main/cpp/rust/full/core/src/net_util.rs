// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! 地址策略与端口探测（`net/net_util.cpp` 的等价实现）。
//!
//! 两者都是安全/可用性关键路径：私网判定必须有边界回归；端口探测必须排除
//! 「自连接」（探测 socket 本地端口恰好等于目标端口时内核会判成功）。

use std::net::{Ipv4Addr, SocketAddrV4};
use std::os::unix::io::{FromRawFd, RawFd};

/// 仅私网 IPv4 视为可直连：10/8、127/8、172.16/12、192.168/16、169.254/16。
/// 非法串（非四段、越界、尾部垃圾、空串）一律 false。
pub fn is_private_ipv4(host: &str) -> bool {
    let mut parts = host.split('.');
    let mut octets = [0u8; 4];
    for (idx, slot) in octets.iter_mut().enumerate() {
        let Some(part) = parts.next() else {
            return false;
        };
        if part.is_empty() || part.len() > 3 || !part.bytes().all(|b| b.is_ascii_digit()) {
            return false;
        }
        let Ok(value) = part.parse::<u16>() else {
            return false;
        };
        if value > 255 {
            return false;
        }
        *slot = value as u8;
        if idx == 3 && parts.next().is_some() {
            return false;
        }
    }
    let [a, b, _, _] = octets;
    a == 10
        || a == 127
        || (a == 172 && (16..=31).contains(&b))
        || (a == 192 && b == 168)
        || (a == 169 && b == 254)
}

/// 在 `[min_port, max_port]` 内找出真正在 listen 的 TCP 端口；0 = 无监听者。
///
/// 并行非阻塞 connect + 单轮 poll（与 C++ 实现同语义）：返回命中的最小端口。
/// 每条 sockaddr 只判定一次 `SO_ERROR`（读即清除），并排除自连接。
pub fn find_listening_tcp_port(host: &str, min_port: u16, max_port: u16, timeout_ms: i32) -> u16 {
    let Ok(addr) = host.parse::<Ipv4Addr>() else {
        return 0;
    };
    if min_port == 0 || max_port < min_port {
        return 0;
    }

    struct Probe {
        fd: RawFd,
        port: u16,
    }

    let mut probes: Vec<Probe> = Vec::with_capacity((max_port - min_port + 1) as usize);
    for port in min_port..=max_port {
        // SAFETY: socket(2) 只返回 fd；失败时立即返回。
        let fd = unsafe {
            libc::socket(
                libc::AF_INET,
                libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
                0,
            )
        };
        if fd < 0 {
            continue;
        }
        let sa = sockaddr_in(addr, port);
        // SAFETY: sa 指向有效的 sockaddr_in。
        let rc = unsafe {
            libc::connect(
                fd,
                &sa as *const libc::sockaddr_in as *const libc::sockaddr,
                std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
            )
        };
        if rc == 0 {
            // 立即成功：仍要排除自连接（本地临时端口 == 目标端口）。
            probes.push(Probe { fd, port });
            continue;
        }
        let err = std::io::Error::last_os_error();
        if err.raw_os_error() == Some(libc::EINPROGRESS) {
            probes.push(Probe { fd, port });
        } else {
            // SAFETY: fd 由本函数创建且未移交。
            unsafe { libc::close(fd) };
        }
    }

    if probes.is_empty() {
        return 0;
    }

    let mut pollfds: Vec<libc::pollfd> = probes
        .iter()
        .map(|p| libc::pollfd {
            fd: p.fd,
            events: libc::POLLOUT,
            revents: 0,
        })
        .collect();
    // SAFETY: pollfds 长度正确且可写。
    unsafe {
        libc::poll(
            pollfds.as_mut_ptr(),
            pollfds.len() as libc::nfds_t,
            timeout_ms,
        );
    }

    let mut best = 0u16;
    for (i, probe) in probes.iter().enumerate() {
        let revents = pollfds[i].revents;
        let mut ok = false;
        if revents & (libc::POLLOUT | libc::POLLERR | libc::POLLHUP) != 0 {
            let mut err: libc::c_int = 0;
            let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
            // SAFETY: err/len 均为有效可写内存。
            let rc = unsafe {
                libc::getsockopt(
                    probe.fd,
                    libc::SOL_SOCKET,
                    libc::SO_ERROR,
                    &mut err as *mut _ as *mut libc::c_void,
                    &mut len,
                )
            };
            if rc == 0 && err == 0 {
                ok = true;
            }
        }
        if ok {
            // 自连接：探测 socket 的内核分配端口恰好等于目标端口时 connect 会成功。
            let mut local: libc::sockaddr_in = unsafe { std::mem::zeroed() };
            let mut len = std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t;
            // SAFETY: local/len 均为有效可写内存。
            let rc = unsafe {
                libc::getsockname(
                    probe.fd,
                    &mut local as *mut _ as *mut libc::sockaddr,
                    &mut len,
                )
            };
            if rc == 0 && u16::from_be(local.sin_port) == probe.port {
                ok = false;
            }
        }
        if ok && (best == 0 || probe.port < best) {
            best = probe.port;
        }
        // SAFETY: fd 由本函数创建且未移交。
        unsafe { libc::close(probe.fd) };
    }
    best
}

fn sockaddr_in(addr: Ipv4Addr, port: u16) -> libc::sockaddr_in {
    let mut sa: libc::sockaddr_in = unsafe { std::mem::zeroed() };
    sa.sin_family = libc::AF_INET as libc::sa_family_t;
    sa.sin_port = port.to_be();
    sa.sin_addr.s_addr = u32::from_ne_bytes(addr.octets());
    sa
}

/// 目标地址用于日志时的 `IP:port` 形态。
pub fn endpoint(host: &str, port: u16) -> String {
    format!("{host}:{port}")
}

/// 从 `std::net::TcpStream` 取对端 IPv4 文本；用于 identity 无 host 字段的场景。
pub fn peer_host(stream: &std::net::TcpStream) -> Option<String> {
    match stream.peer_addr().ok()? {
        std::net::SocketAddr::V4(v4) => Some(v4.ip().to_string()),
        std::net::SocketAddr::V6(_) => None,
    }
}

/// 从 socket fd 取对端 IPv4 文本（accept 后、尚未包装成 TcpStream 时也可用）。
pub fn peer_host_fd(fd: RawFd) -> Option<String> {
    let mut sa: libc::sockaddr_in = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t;
    // SAFETY: sa/len 均为有效可写内存。
    let rc = unsafe { libc::getpeername(fd, &mut sa as *mut _ as *mut libc::sockaddr, &mut len) };
    if rc != 0 {
        return None;
    }
    let octets = sa.sin_addr.s_addr.to_ne_bytes();
    Some(Ipv4Addr::from(octets).to_string())
}

/// 包装原始 fd 为 `TcpStream`（调用方保证 fd 唯一所有权）。
///
/// # Safety
/// `fd` 必须是有效的、未移交的 TCP socket；返回的 stream 关闭时负责 `close(fd)`。
pub unsafe fn stream_from_fd(fd: RawFd) -> std::io::Result<std::net::TcpStream> {
    // SAFETY: 由调用方保证。
    Ok(unsafe { std::net::TcpStream::from_raw_fd(fd) })
}

/// 便于测试：`SocketAddrV4` → `Ipv4Addr`。
pub fn addr_ip(addr: SocketAddrV4) -> Ipv4Addr {
    *addr.ip()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn private_ipv4_boundaries() {
        for ok in [
            "10.0.0.1",
            "10.255.255.255",
            "127.0.0.1",
            "172.16.0.1",
            "172.31.255.255",
            "192.168.1.10",
            "169.254.1.1",
        ] {
            assert!(is_private_ipv4(ok), "{ok} should be private");
        }
        for bad in [
            "8.8.8.8",
            "172.15.255.255",
            "172.32.0.0",
            "192.169.1.1",
            "169.253.1.1",
            "10.0.0",
            "10.0.0.1.2",
            "10.0.0.256",
            "10.0.0.-1",
            "10.0.0.",
            "",
            "abc",
        ] {
            assert!(!is_private_ipv4(bad), "{bad} should be public/invalid");
        }
    }

    #[test]
    fn port_probe_finds_listener() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        assert_eq!(find_listening_tcp_port("127.0.0.1", port, port, 500), port);
        drop(listener);
        assert_eq!(find_listening_tcp_port("127.0.0.1", port, port, 100), 0);
    }
}
