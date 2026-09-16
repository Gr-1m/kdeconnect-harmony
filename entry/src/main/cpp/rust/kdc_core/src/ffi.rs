//! C ABI 边界：C++ shim（`net/packet_io.cpp`、`net/cert_util.cpp`）经此调用 Rust 实现。
//!
//! # 内存约定（R1 任务书 §4.1，选「调用者分配 + 长度重试」）
//! - 所有返回数据的函数统一签名 `(…输入…, out: *mut u8, out_cap: usize) -> i32`：
//!   返回值为**需要写入的字节数**；`> out_cap` 表示缓冲不足（此时**不写任何字节**），
//!   调用方扩容后重试；**负数**表示语义失败（解析失败/无匹配 PEM 段等）。
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
