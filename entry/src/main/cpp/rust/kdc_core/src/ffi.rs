// SPDX-License-Identifier: GPL-2.0-or-later
//! C ABI 边界：C++ shim（`net/packet_io.cpp`、`net/cert_util.cpp`）经此调用 Rust 实现。
//!
//! # 内存约定（R1 任务书 §4.1，选「调用者分配 + 长度重试」）
//! - 所有返回数据的函数统一签名 `(…输入…, out: *mut u8, out_cap: usize) -> i32`：
//!   返回值为**需要写入的字节数**；`> out_cap` 表示缓冲不足（此时**不写任何字节**），
//!   调用方扩容后重试；**负数**表示语义失败（解析失败/无匹配 PEM 段等）。
//!
//!   > ⚠️ **例外（不适用「扩容重试」）**：`kdc_extract_frame` —— 它的 `Frame` 分支在 `write_out`
//!   > 因缓冲不足未写入时，**仍会把该帧从接收缓冲前移消费**（`new_len` 已更新）⇒ 同一帧**无法重试**。
//!   > 调用方**必须**以 `max_size` 预分配 `out`（本仓 C++ shim 即如此），否则该帧会被静默丢弃。
//!   > 该行为已由 `tests` 中 `extract_frame_consumes_frame_even_when_out_too_small` 固定（CodeArts MSG127 裁决2）。
//! - Rust 侧不返回堆指针 ⇒ 无跨堆释放问题（不需要 `kdc_string_free`）。
//! - 多字段输出用 **NUL 分隔的单缓冲**（`deviceId\0deviceName\0deviceType\0`），
//!   由 C++ shim 自行切分；这保持 ABI 表面最小。
//! - `extract_frame` 三态用固定码表达：`>0` 帧长、`0` 半包、`-2` 超限丢弃、`-1` 错误。
//!
//! # 安全
//! 本模块是全 crate 唯一的 unsafe 边界（`lib.rs` 里 `#![deny(unsafe_code)]`）。
//! 每个函数先做空指针/长度校验，再把 `(ptr,len)` 还原为切片；不读写调用方缓冲区边界之外。
#![allow(unsafe_code)]

use crate::cert;
use crate::packet;

/// 把 `(ptr,len)` 还原为切片；ptr 为空且 len>0 视为非法（返回 None）。
///
/// # Safety
/// 调用方保证 `ptr` 在 `len` 字节内可读（C++ shim 传入的都是其自有缓冲）。
unsafe fn as_slice<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// 尽力把结果写入调用方缓冲；不足时只返回所需长度（不写入）。
///
/// # Safety
/// 调用方保证 `out` 可写 `out_cap` 字节（out 为空时 out_cap 必须为 0）。
unsafe fn write_out(data: &[u8], out: *mut u8, out_cap: usize) -> i32 {
    let need = data.len();
    if need > out_cap || (need > 0 && out.is_null()) {
        return need as i32;
    }
    if need > 0 {
        unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), out, need) };
    }
    need as i32
}

/// 把 NUL 分隔的多字段拼成一个待写入缓冲。
fn join_nul(fields: &[&str]) -> Vec<u8> {
    let mut out = Vec::new();
    for f in fields {
        out.extend_from_slice(f.as_bytes());
        out.push(0);
    }
    out
}

// ————————————— cert_util.h 的对应实现 —————————————

#[no_mangle]
pub extern "C" fn kdc_b64_encode(data: *const u8, len: usize, out: *mut u8, out_cap: usize) -> i32 {
    let Some(input) = (unsafe { as_slice(data, len) }) else {
        return -1;
    };
    let s = cert::base64_encode(input);
    unsafe { write_out(s.as_bytes(), out, out_cap) }
}

#[no_mangle]
pub extern "C" fn kdc_der_to_pem(
    label: *const u8,
    label_len: usize,
    der: *const u8,
    der_len: usize,
    out: *mut u8,
    out_cap: usize,
) -> i32 {
    let (Some(label), Some(der)) = (unsafe { as_slice(label, label_len) }, unsafe {
        as_slice(der, der_len)
    }) else {
        return -1;
    };
    let Ok(label) = std::str::from_utf8(label) else {
        return -1;
    };
    let s = cert::der_to_pem(label, der);
    unsafe { write_out(s.as_bytes(), out, out_cap) }
}

#[no_mangle]
pub extern "C" fn kdc_pem_to_der(
    pem: *const u8,
    pem_len: usize,
    label: *const u8,
    label_len: usize,
    out: *mut u8,
    out_cap: usize,
) -> i32 {
    let (Some(pem), Some(label)) = (unsafe { as_slice(pem, pem_len) }, unsafe {
        as_slice(label, label_len)
    }) else {
        return -1;
    };
    let (Ok(pem), Ok(label)) = (std::str::from_utf8(pem), std::str::from_utf8(label)) else {
        return -1;
    };
    let der = cert::pem_to_der(pem, label);
    if der.is_empty() {
        return -1; // 与 C++ 语义一致：失败 = 空结果
    }
    unsafe { write_out(&der, out, out_cap) }
}

#[no_mangle]
pub extern "C" fn kdc_extract_spki(der: *const u8, len: usize, out: *mut u8, out_cap: usize) -> i32 {
    let Some(der) = (unsafe { as_slice(der, len) }) else {
        return -1;
    };
    let spki = cert::extract_spki_der(der);
    if spki.is_empty() {
        return -1;
    }
    unsafe { write_out(&spki, out, out_cap) }
}

#[no_mangle]
pub extern "C" fn kdc_extract_subject_dn(
    der: *const u8,
    len: usize,
    out: *mut u8,
    out_cap: usize,
) -> i32 {
    let Some(der) = (unsafe { as_slice(der, len) }) else {
        return -1;
    };
    let dn = cert::extract_subject_dn_der(der);
    if dn.is_empty() {
        return -1;
    }
    unsafe { write_out(&dn, out, out_cap) }
}

#[no_mangle]
pub extern "C" fn kdc_verification_code(
    own: *const u8,
    own_len: usize,
    peer: *const u8,
    peer_len: usize,
    pairing_timestamp: i64,
    out: *mut u8,
    out_cap: usize,
) -> i32 {
    let (Some(own), Some(peer)) = (unsafe { as_slice(own, own_len) }, unsafe {
        as_slice(peer, peer_len)
    }) else {
        return -1;
    };
    if own.is_empty() || peer.is_empty() {
        return -1; // C++：空 SPKI ⇒ 空串（失败）
    }
    let code = cert::compute_verification_code(own, peer, pairing_timestamp);
    if code.is_empty() {
        return -1;
    }
    unsafe { write_out(code.as_bytes(), out, out_cap) }
}

// ————————————— packet_io.h 的对应实现 —————————————

/// 三态：`>0` 完整帧长度（帧已写入 out）、`0` 半包（buf 未变）、`-2` 超限帧被丢弃、`-1` 参数错误。
/// ⚠️ 与通用约定不同：`> out_cap`（缓冲不足）时**帧仍会被消费掉**（缓冲前移），不可扩容重试；
///    调用方必须以 `max_size` 预分配 `out`。详见本文件头注释的「例外」小节。
/// `buf`/`buf_len` 为**就地修改**的接收缓冲（丢帧/取帧后剩余内容写回，新的长度经 `new_len` 返回）。
#[no_mangle]
pub extern "C" fn kdc_extract_frame(
    buf: *mut u8,
    buf_len: usize,
    max_size: usize,
    out: *mut u8,
    out_cap: usize,
    new_len: *mut usize,
) -> i32 {
    let Some(bytes) = (unsafe { as_slice(buf, buf_len) }) else {
        return -1;
    };
    // R-OPT-1：零拷贝扫描 —— 不再 `from_utf8(..).to_string()`（原实现每帧多两次分配/拷贝）。
    // 语义变化（AtomCode P3，已记入 devdocs/EXP_LESSONS_20260916_splash_freeze.md §5.2）：
    // 本路径**不再做 UTF-8 预校验**，含非法 UTF-8 的行由「返回 -1」变为「按普通帧提取」，
    // 非法字节交由下游 cJSON 按「非法 JSON 丢弃该行」处理（帧本身是 JSON 文本）。
    // 注意顺序：**先**把帧写入 out，**再**把剩余字节前移；否则前移会覆盖尚未输出的帧字节。
    match packet::scan_frame(bytes, max_size) {
        packet::FrameScan::Half => {
            if !new_len.is_null() {
                unsafe { *new_len = buf_len };
            }
            0
        }
        packet::FrameScan::DroppedOversize { consumed } => {
            let remaining = &bytes[consumed..];
            if remaining.len() > buf_len {
                return -1; // 不可能：丢帧只会缩短
            }
            if !remaining.is_empty() {
                unsafe { std::ptr::copy(remaining.as_ptr(), buf, remaining.len()) };
            }
            if !new_len.is_null() {
                unsafe { *new_len = remaining.len() };
            }
            -2
        }
        packet::FrameScan::Frame { len } => {
            let rc = unsafe { write_out(&bytes[..len], out, out_cap) };
            if rc < 0 {
                return rc;
            }
            let remaining = &bytes[len..];
            if remaining.len() > buf_len {
                return -1;
            }
            if !remaining.is_empty() {
                unsafe { std::ptr::copy(remaining.as_ptr(), buf, remaining.len()) };
            }
            if !new_len.is_null() {
                unsafe { *new_len = remaining.len() };
            }
            rc
        }
    }
}

/// capability 数组用**并排数组**传入（ptrs/lens + count）；返回 identity 帧文本（含结尾 '\n'）。
#[no_mangle]
pub extern "C" fn kdc_build_identity(
    device_id: *const u8,
    device_id_len: usize,
    device_name: *const u8,
    device_name_len: usize,
    device_type: *const u8,
    device_type_len: usize,
    tcp_port: u16,
    protocol_version: i32,
    in_ptrs: *const *const u8,
    in_lens: *const usize,
    in_count: usize,
    out_ptrs: *const *const u8,
    out_lens: *const usize,
    out_count: usize,
    out: *mut u8,
    out_cap: usize,
) -> i32 {
    let (Some(id), Some(name), Some(kind)) = (
        unsafe { as_slice(device_id, device_id_len) },
        unsafe { as_slice(device_name, device_name_len) },
        unsafe { as_slice(device_type, device_type_len) },
    ) else {
        return -1;
    };
    let (Ok(id), Ok(name), Ok(kind)) = (
        std::str::from_utf8(id),
        std::str::from_utf8(name),
        std::str::from_utf8(kind),
    ) else {
        return -1;
    };

    // SAFETY：caps 数组由 C++ shim 以「并排数组 + 数量」传入；逐项做空指针校验。
    let collect = |ptrs: *const *const u8, lens: *const usize, count: usize| -> Option<Vec<String>> {
        if count == 0 {
            return Some(Vec::new());
        }
        if ptrs.is_null() || lens.is_null() {
            return None;
        }
        let mut v = Vec::with_capacity(count);
        for i in 0..count {
            let p = unsafe { *ptrs.add(i) };
            let l = unsafe { *lens.add(i) };
            let bytes = unsafe { as_slice(p, l) }?;
            v.push(std::str::from_utf8(bytes).ok()?.to_string());
        }
        Some(v)
    };
    let (Some(incoming), Some(outgoing)) = (
        collect(in_ptrs, in_lens, in_count),
        collect(out_ptrs, out_lens, out_count),
    ) else {
        return -1;
    };

    let frame = packet::build_identity(id, name, kind, tcp_port, protocol_version, &incoming, &outgoing);
    unsafe { write_out(frame.as_bytes(), out, out_cap) }
}

/// 输出 `deviceId\0deviceName\0deviceType\0`；`tcp_port` 经 out 参数返回。
#[no_mangle]
pub extern "C" fn kdc_parse_identity(
    json: *const u8,
    json_len: usize,
    out: *mut u8,
    out_cap: usize,
    tcp_port: *mut u16,
) -> i32 {
    let Some(json) = (unsafe { as_slice(json, json_len) }) else {
        return -1;
    };
    let Ok(json) = std::str::from_utf8(json) else {
        return -1;
    };
    let Some(info) = packet::parse_identity(json) else {
        return -1;
    };
    if !tcp_port.is_null() {
        unsafe { *tcp_port = info.tcp_port };
    }
    let blob = join_nul(&[info.device_id.as_str(), info.device_name.as_str(), info.device_type.as_str()]);
    unsafe { write_out(&blob, out, out_cap) }
}

/// 1 = 合法，0 = 非法（无失败态）。
#[no_mangle]
pub extern "C" fn kdc_is_valid_device_id(id: *const u8, len: usize) -> i32 {
    let Some(id) = (unsafe { as_slice(id, len) }) else {
        return 0;
    };
    let Ok(id) = std::str::from_utf8(id) else {
        return 0;
    };
    i32::from(packet::is_valid_device_id(id))
}

/// 输出 `type\0body\0`；`payload_size`/`payload_port` 经 out 参数返回。
#[no_mangle]
pub extern "C" fn kdc_parse_packet(
    json: *const u8,
    json_len: usize,
    out: *mut u8,
    out_cap: usize,
    payload_size: *mut i64,
    payload_port: *mut u16,
) -> i32 {
    let Some(json) = (unsafe { as_slice(json, json_len) }) else {
        return -1;
    };
    let Ok(json) = std::str::from_utf8(json) else {
        return -1;
    };
    let Some(pkt) = packet::parse_packet(json) else {
        return -1;
    };
    if !payload_size.is_null() {
        unsafe { *payload_size = pkt.payload_size };
    }
    if !payload_port.is_null() {
        unsafe { *payload_port = pkt.payload_port };
    }
    let blob = join_nul(&[pkt.r#type.as_str(), pkt.body.as_str()]);
    unsafe { write_out(&blob, out, out_cap) }
}


#[cfg(test)]
mod tests {
    //! T7：C ABI 边界单测（AtomCode MSG112 T7 —— ffi 所有权与 panic 边界）。
    //!
    //! 锁定的是**内存约定**而非算法（算法在 cert.rs/packet.rs 已有 24 例）：
    //!   ① 缓冲协议：返回值恒为「需要写入的字节数」；`need > out_cap` 时**一个字节都不写**；
    //!      写入不得越界（用 0xAA 哨兵断言尾部未被触碰）；
    //!   ② 空指针/长度校验：`ptr` 为空且 `len>0` ⇒ 语义失败（负数），绝不解引用；
    //!   ③ NUL 分隔多字段与 out 参数的既有格式；
    //!   ④ `extract_frame` 三态（`>0` 帧长 / `0` 半包 / `-2` 超限丢弃 / `-1` 参数错）+ 就地前移；
    //!   ⑤ **恶意输入不 panic**：release 侧 `panic = "abort"`，panic 逃逸即硬崩，故该属性是硬安全要求。
    //!      测试用 dev profile（unwind）以 catch_unwind 断言。

    use super::*;
    use std::panic::{catch_unwind, AssertUnwindSafe};

    const CANARY: u8 = 0xAA;

    fn canary(cap: usize) -> Vec<u8> {
        vec![CANARY; cap]
    }

    fn all_canary(b: &[u8]) -> bool {
        b.iter().all(|&x| x == CANARY)
    }

    /// 32 位合法 deviceId（协议正则 `^[a-zA-Z0-9_-]{32,38}$`，且 = 证书 CN）。
    const DEV_ID: &str = "0123456789abcdef0123456789abcdef";

    // —————— ① 缓冲协议 ——————

    #[test]
    fn write_out_never_writes_when_too_small() {
        let input = b"hello"; // base64("hello") == "aGVsbG8="（8 字节）
        // 尺寸查询：out=null, cap=0 ⇒ 返回所需长度
        assert_eq!(
            kdc_b64_encode(input.as_ptr(), input.len(), std::ptr::null_mut(), 0),
            8
        );
        // 缓冲不足：返回所需长度，且一个字节都不能动
        let mut small = canary(4);
        let rc = kdc_b64_encode(input.as_ptr(), input.len(), small.as_mut_ptr(), small.len());
        assert_eq!(rc, 8);
        assert!(rc > small.len() as i32, "调用方据 rc > out_cap 判定扩容重试");
        assert!(all_canary(&small), "缓冲不足时不得写入任何字节");
        // 恰好容纳
        let mut exact = canary(8);
        assert_eq!(
            kdc_b64_encode(input.as_ptr(), input.len(), exact.as_mut_ptr(), exact.len()),
            8
        );
        assert_eq!(&exact, b"aGVsbG8=");
        // 富余：写入区之后仍是哨兵（不越界写）
        let mut big = canary(32);
        assert_eq!(
            kdc_b64_encode(input.as_ptr(), input.len(), big.as_mut_ptr(), big.len()),
            8
        );
        assert_eq!(&big[..8], b"aGVsbG8=");
        assert!(all_canary(&big[8..]), "不得写到写入长度之外");
    }

    // —————— ② 空指针 / 长度校验 ——————

    #[test]
    fn null_pointer_and_length_validation() {
        let mut out = canary(16);
        // len==0 且 ptr 为空 ⇒ 合法空输入
        assert_eq!(kdc_b64_encode(std::ptr::null(), 0, out.as_mut_ptr(), out.len()), 0);
        // ptr 为空但 len>0 ⇒ 非法 ⇒ -1（不读、不崩）
        assert_eq!(kdc_b64_encode(std::ptr::null(), 5, out.as_mut_ptr(), out.len()), -1);
        assert!(all_canary(&out), "失败路径不得触碰输出缓冲");
        // 正常输入但 out 为空 ⇒ 只返回长度（write_out 的防御分支：need>0 && out.is_null()）
        assert_eq!(kdc_b64_encode(b"hello".as_ptr(), 5, std::ptr::null_mut(), 8), 8);
    }

    // —————— ③ NUL 分隔多字段 + out 参数 ——————

    #[test]
    fn parse_identity_nul_blob_and_out_params() {
        let json = format!(
            "{{\"id\":1,\"type\":\"kdeconnect.identity\",\"version\":8,\"body\":{{\"deviceId\":\"{}\",\"deviceName\":\"Dev\",\"deviceType\":\"phone\",\"protocolVersion\":8,\"tcpPort\":1716,\"incomingCapabilities\":[],\"outgoingCapabilities\":[]}}}}",
            DEV_ID
        );
        let mut out = canary(128);
        let mut port: u16 = 0;
        let rc = kdc_parse_identity(
            json.as_ptr(),
            json.len(),
            out.as_mut_ptr(),
            out.len(),
            &mut port,
        );
        assert!(rc > 0, "合法 identity 应解析成功");
        let blob = &out[..rc as usize];
        assert_eq!(
            blob,
            b"0123456789abcdef0123456789abcdef\0Dev\0phone\0",
            "字段顺序与 NUL 分隔格式是 ABI 契约"
        );
        assert_eq!(port, 1716, "tcp_port 经 out 参数返回");
        // 缓冲不足：不写 + 返回所需长度
        let mut small = canary(4);
        let need = kdc_parse_identity(
            json.as_ptr(),
            json.len(),
            small.as_mut_ptr(),
            small.len(),
            &mut port,
        );
        assert!(need > 4);
        assert!(all_canary(&small), "缓冲不足时不得写入任何字节");
        // 非法输入 ⇒ 负数（语义失败）
        let bad = b"not json";
        assert!(
            kdc_parse_identity(bad.as_ptr(), bad.len(), out.as_mut_ptr(), out.len(), &mut port) < 0
        );
    }

    #[test]
    fn parse_packet_blob_and_payload_out_params() {
        let json = b"{\"id\":2,\"type\":\"kdeconnect.ping\",\"body\":{\"message\":\"hi\"}}";
        let mut out = canary(256);
        let mut size: i64 = 0;
        let mut port: u16 = 0;
        let rc = kdc_parse_packet(json.as_ptr(), json.len(), out.as_mut_ptr(), out.len(), &mut size, &mut port);
        assert!(rc > 0);
        let blob = &out[..rc as usize];
        assert!(blob.starts_with(b"kdeconnect.ping\0"), "blob = type\\0body\\0");
        assert_eq!(*blob.last().unwrap(), 0u8, "blob 以 NUL 收尾");
        assert_eq!(size, 0, "无 payloadSize ⇒ 0");
        // 非法 JSON ⇒ 负数
        assert!(kdc_parse_packet(b"{".as_ptr(), 1, out.as_mut_ptr(), out.len(), &mut size, &mut port) < 0);
    }

    #[test]
    fn is_valid_device_id_bounds() {
        let ok = DEV_ID.as_bytes();
        assert_eq!(kdc_is_valid_device_id(ok.as_ptr(), ok.len()), 1);
        // 长度边界：32 / 38 合法；31 / 39 非法
        let s38 = "a".repeat(38);
        let s31 = "a".repeat(31);
        let s39 = "a".repeat(39);
        assert_eq!(kdc_is_valid_device_id(s38.as_ptr(), s38.len()), 1);
        assert_eq!(kdc_is_valid_device_id(s31.as_ptr(), s31.len()), 0);
        assert_eq!(kdc_is_valid_device_id(s39.as_ptr(), s39.len()), 0);
        // 非法字符
        let bad = b"0123456789abcdef0123456789abcde!";
        assert_eq!(kdc_is_valid_device_id(bad.as_ptr(), bad.len()), 0);
        // 空输入
        assert_eq!(kdc_is_valid_device_id(std::ptr::null(), 0), 0);
    }

    #[test]
    fn build_identity_frame_ends_with_newline() {
        let caps_in: [&[u8]; 1] = [b"kdeconnect.ping"];
        let caps_out: [&[u8]; 1] = [b"kdeconnect.ping"];
        let ptrs_in: [*const u8; 1] = [caps_in[0].as_ptr()];
        let lens_in: [usize; 1] = [caps_in[0].len()];
        let ptrs_out: [*const u8; 1] = [caps_out[0].as_ptr()];
        let lens_out: [usize; 1] = [caps_out[0].len()];
        let mut out = canary(512);
        let rc = kdc_build_identity(
            DEV_ID.as_ptr(),
            DEV_ID.len(),
            b"Dev".as_ptr(),
            3,
            b"phone".as_ptr(),
            5,
            1716,
            8,
            ptrs_in.as_ptr(),
            lens_in.as_ptr(),
            1,
            ptrs_out.as_ptr(),
            lens_out.as_ptr(),
            1,
            out.as_mut_ptr(),
            out.len(),
        );
        assert!(rc > 0);
        let frame = &out[..rc as usize];
        assert_eq!(*frame.last().unwrap(), b'\n', "帧尾必须带换行（协议以 \\n 分隔）");
        let text = std::str::from_utf8(frame).expect("identity 帧为 UTF-8 文本");
        assert!(text.contains("kdeconnect.identity"));
        assert!(text.contains(DEV_ID));
    }

    // —————— ④ extract_frame 三态 + 就地前移 ——————

    #[test]
    fn extract_frame_tristate_and_inplace_shift() {
        let mut out = canary(256);
        let mut new_len: usize = usize::MAX;

        // 完整帧：返回帧长、out 写入该帧、剩余内容前移到缓冲头部
        let mut buf = b"{\"a\":1}\nrest".to_vec();
        let rc = kdc_extract_frame(buf.as_mut_ptr(), buf.len(), 1 << 20, out.as_mut_ptr(), out.len(), &mut new_len);
        assert_eq!(rc, 8, "帧长（含换行）");
        assert_eq!(&out[..8], b"{\"a\":1}\n");
        assert_eq!(new_len, 4, "剩余长度经 new_len 返回");
        assert_eq!(&buf[..4], b"rest", "剩余字节已前移");

        // 半包：返回 0、缓冲原样、new_len == buf_len
        let mut half = b"{\"a\":".to_vec();
        let snapshot = half.clone();
        let mut nl2: usize = 0;
        let rc2 = kdc_extract_frame(half.as_mut_ptr(), half.len(), 1 << 20, out.as_mut_ptr(), out.len(), &mut nl2);
        assert_eq!(rc2, 0);
        assert_eq!(half, snapshot, "半包不得改动缓冲");
        assert_eq!(nl2, half.len());

        // 超限丢弃：max_size 很小 ⇒ -2，且被丢帧之后的剩余内容前移
        let mut big = b"aaaaaaaaaa\nx".to_vec();
        let mut nl3: usize = 0;
        let rc3 = kdc_extract_frame(big.as_mut_ptr(), big.len(), 4, out.as_mut_ptr(), out.len(), &mut nl3);
        assert_eq!(rc3, -2);
        assert_eq!(nl3, 1);
        assert_eq!(&big[..1], b"x");

        // 参数错误：ptr 空且 len>0 ⇒ -1
        let mut nl4: usize = 0;
        assert_eq!(
            kdc_extract_frame(std::ptr::null_mut(), 5, 1 << 20, out.as_mut_ptr(), out.len(), &mut nl4),
            -1
        );
    }

    /// 记录一处**契约不一致**（不修，先由 CodeArts 裁决）：
    /// 头注释约定「缓冲不足 ⇒ 不写任何字节，调用方扩容后重试」，但 `Frame` 分支即使
    /// `write_out` 因缓冲不足未写入，也**已经把该帧从接收缓冲前移消费掉** ⇒ 同一帧无法重试。
    /// 调用方必须以 `max_size` 预分配 out（本仓 C++ shim 即如此），否则帧会静默丢失。
    #[test]
    fn extract_frame_consumes_frame_even_when_out_too_small() {
        let mut buf = b"{\"a\":1}\nrest".to_vec();
        let mut small = canary(2);
        let mut new_len: usize = 0;
        let rc = kdc_extract_frame(buf.as_mut_ptr(), buf.len(), 1 << 20, small.as_mut_ptr(), small.len(), &mut new_len);
        assert_eq!(rc, 8, "返回值仍是所需长度");
        assert!(all_canary(&small), "缓冲不足时确实未写入");
        // 但帧已被消费：剩余 "rest" 前移，new_len = 4
        assert_eq!(new_len, 4);
        assert_eq!(&buf[..4], b"rest");
    }

    // —————— ⑤ 恶意输入不 panic（release 侧 panic=abort ⇒ 硬安全要求）——————

    #[test]
    fn hostile_inputs_never_panic() {
        let cases: &[&[u8]] = &[
            b"",
            b"\0",
            b"{",
            b"\xff\xfe\x00\x01",
            b"-----BEGIN CERTIFICATE-----\n",
            &[0x30, 0x82, 0xff, 0xff],
            b"{\"type\":\"kdeconnect.identity\"}",
        ];
        for c in cases {
            let mut out = canary(64);
            let mut frame_buf = canary(64);
            let mut new_len: usize = 0;
            let mut port: u16 = 0;
            let mut size: i64 = 0;
            let res = catch_unwind(AssertUnwindSafe(|| {
                let (ptr, len) = (c.as_ptr(), c.len());
                kdc_b64_encode(ptr, len, out.as_mut_ptr(), out.len());
                kdc_der_to_pem(b"CERTIFICATE".as_ptr(), 11, ptr, len, out.as_mut_ptr(), out.len());
                kdc_pem_to_der(ptr, len, b"CERTIFICATE".as_ptr(), 11, out.as_mut_ptr(), out.len());
                kdc_extract_spki(ptr, len, out.as_mut_ptr(), out.len());
                kdc_extract_subject_dn(ptr, len, out.as_mut_ptr(), out.len());
                kdc_verification_code(ptr, len, ptr, len, 0, out.as_mut_ptr(), out.len());
                kdc_parse_identity(ptr, len, out.as_mut_ptr(), out.len(), &mut port);
                kdc_parse_packet(ptr, len, out.as_mut_ptr(), out.len(), &mut size, &mut port);
                kdc_is_valid_device_id(ptr, len);
                // extract_frame 用**独立**缓冲，避免同一缓冲既作 buf 又作 out（别名）
                kdc_extract_frame(frame_buf.as_mut_ptr(), frame_buf.len(), 1 << 20, out.as_mut_ptr(), out.len(), &mut new_len);
            }));
            assert!(res.is_ok(), "hostile input caused panic: {:?}", c);
        }
    }

    #[test]
    fn repeated_calls_stay_consistent() {
        let input = b"The quick brown fox jumps over the lazy dog";
        let mut first = canary(128);
        let need = kdc_b64_encode(input.as_ptr(), input.len(), first.as_mut_ptr(), first.len());
        assert!(need > 0);
        for _ in 0..1000 {
            let mut out = canary(128);
            let rc = kdc_b64_encode(input.as_ptr(), input.len(), out.as_mut_ptr(), out.len());
            assert_eq!(rc, need, "重复调用结果必须稳定");
            assert_eq!(&out[..need as usize], &first[..need as usize]);
            assert!(all_canary(&out[need as usize..]), "不得越界写");
        }
    }
}
