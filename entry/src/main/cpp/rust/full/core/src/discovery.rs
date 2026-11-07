// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//! UDP 发现（`net/udp_discovery.cpp` + `net_stack_discovery.cpp` 的发送/接收部分）。
//!
//! 行为约束（勿回退，证据见 CPP_GUIDE §5b）：
//! - 发送 = 逐网卡子网定向广播 + 全局广播兜底；
//! - 已建链时默认不重播（KDE 收到广播会新建链路并替换旧链路，打断在传 payload）；
//! - 启动初期 5s×5 次，之后 60s 一次，长时间不停。

use std::io;
use std::net::{Ipv4Addr, SocketAddrV4, UdpSocket};
use std::os::unix::io::{FromRawFd, RawFd};
use std::time::Duration;

use crate::types::UDP_PORT;

/// 创建 UDP 发现 socket：`SO_REUSEADDR` + `SO_BROADCAST` + 非阻塞 + 绑 `0.0.0.0:port`。
pub fn bind_udp(port: u16) -> io::Result<UdpSocket> {
    // SAFETY: socket(2) 返回 fd；后续 setsockopt/bind 失败路径都会 close。
    let fd: RawFd = unsafe {
        libc::socket(
            libc::AF_INET,
            libc::SOCK_DGRAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
            0,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let setup = (|| -> io::Result<()> {
        let one: libc::c_int = 1;
        for name in [libc::SO_REUSEADDR, libc::SO_BROADCAST] {
            // SAFETY: `one` 是有效的 c_int，长度与类型一致。
            let rc = unsafe {
                libc::setsockopt(
                    fd,
                    libc::SOL_SOCKET,
                    name,
                    &one as *const libc::c_int as *const libc::c_void,
                    std::mem::size_of::<libc::c_int>() as libc::socklen_t,
                )
            };
            if rc != 0 {
                return Err(io::Error::last_os_error());
            }
        }
        let mut addr: libc::sockaddr_in = unsafe { std::mem::zeroed() };
        addr.sin_family = libc::AF_INET as libc::sa_family_t;
        addr.sin_port = port.to_be();
        addr.sin_addr.s_addr = libc::INADDR_ANY;
        // SAFETY: addr 是有效的 sockaddr_in。
        let rc = unsafe {
            libc::bind(
                fd,
                &addr as *const _ as *const libc::sockaddr,
                std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
            )
        };
        if rc != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    })();
    if let Err(e) = setup {
        // SAFETY: fd 由本函数创建，尚未移交。
        unsafe { libc::close(fd) };
        return Err(e);
    }
    // SAFETY: fd 有效且所有权移交给 UdpSocket。
    Ok(unsafe { UdpSocket::from_raw_fd(fd) })
}

/// 一次发现广播：向每个网卡的子网广播地址 + 全局广播各发一份。
pub fn broadcast(udp: &UdpSocket, port: u16, identity: &str) -> io::Result<usize> {
    let mut sent = 0;
    for addr in broadcast_addresses() {
        if udp
            .send_to(identity.as_bytes(), SocketAddrV4::new(addr, port))
            .is_ok()
        {
            sent += 1;
        }
    }
    // 全局广播兜底：部分 HarmonyOS 版本会拒绝，但其它网卡定向广播通常仍成功。
    if udp
        .send_to(
            identity.as_bytes(),
            SocketAddrV4::new(Ipv4Addr::BROADCAST, port),
        )
        .is_ok()
    {
        sent += 1;
    }
    Ok(sent)
}

/// 读取一个 UDP identity。返回 `(json, 源 IP)`；无数据/解析失败 → None。
pub fn read_identity(udp: &UdpSocket, buf: &mut [u8]) -> Option<(String, String)> {
    let (n, from) = udp.recv_from(buf).ok()?;
    let host = match from {
        std::net::SocketAddr::V4(v4) => v4.ip().to_string(),
        std::net::SocketAddr::V6(_) => return None,
    };
    let json = std::str::from_utf8(&buf[..n]).ok()?.to_owned();
    Some((json, host))
}

/// 枚举 `IFF_UP | IFF_BROADCAST` 的 IPv4 接口，返回 `ip | !mask`。
pub fn broadcast_addresses() -> Vec<Ipv4Addr> {
    let mut out = Vec::new();
    let mut ifap: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: getifaddrs 成功时返回链表，失败返回非 0。
    if unsafe { libc::getifaddrs(&mut ifap) } != 0 {
        return out;
    }
    let mut cur = ifap;
    while !cur.is_null() {
        // SAFETY: cur 是 getifaddrs 返回的有效链表节点。
        let ifa = unsafe { &*cur };
        if !ifa.ifa_addr.is_null()
            && !ifa.ifa_netmask.is_null()
            && ifa.ifa_flags & (libc::IFF_UP as u32) != 0
            && ifa.ifa_flags & (libc::IFF_BROADCAST as u32) != 0
            // SAFETY: 非空且由内核填充。
            && unsafe { (*ifa.ifa_addr).sa_family } == libc::AF_INET as libc::sa_family_t
        {
            // SAFETY: 上面的 family 检查保证可以按 sockaddr_in 读取。
            let addr = unsafe { &*(ifa.ifa_addr as *const libc::sockaddr_in) };
            let mask = unsafe { &*(ifa.ifa_netmask as *const libc::sockaddr_in) };
            let ip = u32::from_ne_bytes(addr.sin_addr.s_addr.to_ne_bytes());
            let mask = u32::from_ne_bytes(mask.sin_addr.s_addr.to_ne_bytes());
            let bcast = Ipv4Addr::from((ip | !mask).to_ne_bytes());
            if !out.contains(&bcast) {
                out.push(bcast);
            }
        }
        // SAFETY: cur 由链表维护。
        cur = unsafe { (*cur).ifa_next };
    }
    // SAFETY: getifaddrs 分配的链表必须 freeifaddrs。
    unsafe { libc::freeifaddrs(ifap) };
    out
}

/// 发现线程的轮询粒度（非阻塞 socket 无数据时的睡眠）。
pub const DISCOVERY_POLL_MS: u64 = 50;

pub fn sleep_poll() {
    std::thread::sleep(Duration::from_millis(DISCOVERY_POLL_MS));
}

/// 默认端口（测试/调用方注入 0 时使用）。
pub fn default_udp_port(port: u16) -> u16 {
    if port == 0 {
        UDP_PORT
    } else {
        port
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binds_and_sends_loopback() {
        let rx = bind_udp(0).unwrap();
        let port = rx.local_addr().unwrap().port();
        let tx = bind_udp(0).unwrap();
        // 直接向 127.0.0.1 发（广播地址在 CI/容器里不稳定，这里只验证 socket 通路）。
        tx.send_to(b"hello", SocketAddrV4::new(Ipv4Addr::LOCALHOST, port))
            .unwrap();
        let mut buf = [0u8; 64];
        let (json, host) = read_identity(&rx, &mut buf).unwrap();
        assert_eq!(json, "hello");
        assert_eq!(host, "127.0.0.1");
    }

    #[test]
    fn default_port() {
        assert_eq!(default_udp_port(0), UDP_PORT);
        assert_eq!(default_udp_port(9999), 9999);
    }
}
