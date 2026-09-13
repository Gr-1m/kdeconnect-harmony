//! kdc_core —— R1：`net/packet_io` 与 `net/cert_util` 两个纯函数模块的 Rust 实现。
//!
//! 设计约束（R1 任务书 `MSG93_TO_CODEARTS.md` §1/§3 与 `PROCESS.md §8`）：
//! - 只做**纯函数**：无系统调用、无 TLS、无 NAPI；`#![deny(unsafe_code)]` 全 crate，
//!   唯一的例外是 C ABI 边界（`ffi.rs` 内局部 `#[allow(unsafe_code)]`，逐项注释）。
//! - 公开契约（`net/packet_io.h`、`net/cert_util.h`）**逐字不变**，调用方零改动；
//!   C++ 侧只保留薄 shim，内部转调本 crate 的 C ABI。
//! - 行为以现有 C++ 实现为**唯一参照**（含边界语义），迁移期用 `tests/test_main.cpp`
//!   的既有断言 + `tests/run.sh` 全套用例做行为对照。

#![deny(unsafe_code)]

pub mod cert;
mod ffi;
pub mod packet;
