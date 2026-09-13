#!/usr/bin/env bash
# R1：为 host（本机）测试构建 kdc_core 静态库，并把 .a 的绝对路径打到 stdout
# （日志走 stderr，便于 run.sh 用 $(...) 捕获路径）。
#
# 工具链：优先 PATH 上的 cargo/rustc（本机 rustup 已配 default stable = 1.98.1，与系统同版），
# 若 shim 不可用则回落到系统 /usr/bin。可用环境变量强制指定：
#   CARGO=/path/to/cargo RUSTC=/path/to/rustc ./build_host.sh
set -euo pipefail

CRATE_DIR="$(cd "$(dirname "$0")/kdc_core" && pwd)"
TARGET_DIR="${KDC_RUST_TARGET_DIR:-/tmp/kdc_rust_target}"

CARGO_BIN="${CARGO:-}"
RUSTC_BIN="${RUSTC:-}"
if [ -z "$CARGO_BIN" ]; then
    if command -v cargo >/dev/null 2>&1; then CARGO_BIN=$(command -v cargo); else CARGO_BIN=/usr/bin/cargo; fi
fi
if [ -z "$RUSTC_BIN" ]; then
    if command -v rustc >/dev/null 2>&1; then RUSTC_BIN=$(command -v rustc); else RUSTC_BIN=/usr/bin/rustc; fi
fi

echo "[build_host] cargo=$CARGO_BIN rustc=$RUSTC_BIN target_dir=$TARGET_DIR" >&2
cd "$CRATE_DIR"
RUSTC="$RUSTC_BIN" "$CARGO_BIN" build --release --target-dir "$TARGET_DIR" >&2

LIB="$TARGET_DIR/release/libkdc_core.a"
if [ ! -f "$LIB" ]; then
    echo "[build_host] 未产出 $LIB" >&2
    exit 1
fi
echo "$LIB"
