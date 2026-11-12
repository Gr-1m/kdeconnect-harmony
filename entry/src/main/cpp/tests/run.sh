#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# native host 回归门禁（全 Rust 栈，2026-11-07 起）。
#
# - `kdc_native`：核心协议/TLS/发现/payload 单元测试 + 两套栈真实互联 E2E；
# - `kdeconnect_napi`：只做 `cargo check`（cdylib 的 NAPI 符号在宿主机不可链接）；
# - 装配契约完整性：沿用原门禁（读 ArkTS，但作为 native 门禁的强制收尾）。
#
# 不再依赖 gcc/make/BearSSL；只需要 Rust 工具链（cargo）。
set -euo pipefail
cd "$(dirname "$0")"

MANIFEST="../rust/full/Cargo.toml"

echo "== cargo test -p kdc_native =="
cargo test -p kdc_native --manifest-path "$MANIFEST"

echo "== cargo check -p kdeconnect_napi =="
cargo check -p kdeconnect_napi --manifest-path "$MANIFEST"

# —— 格式/lint 门禁（MSG250 P0-3；对齐参考库 kc-* 的 check.sh 思路）——
# 组件缺失即门禁失败（不得静默跳过）。
if ! cargo fmt --version >/dev/null 2>&1; then
    echo "rustfmt 未安装：rustup component add rustfmt"
    exit 1
fi
echo "== cargo fmt --all -- --check =="
cargo fmt --manifest-path "$MANIFEST" --all -- --check

echo "== cargo clippy --workspace --all-targets -D warnings =="
cargo clippy --manifest-path "$MANIFEST" --workspace --all-targets -- -D warnings

# —— 装配契约完整性（CodeArts MSG129 F2；AtomChecker MSG119 建议2）——
# 失败即门禁失败；脚本缺失同样失败（不得静默跳过——「假通过」已在本轮被证明是真风险）。
INJ="$PWD/../../../../../tools/check-injection-contract.py"
if [ ! -f "$INJ" ]; then
    echo "injection contract checker not found: tools/check-injection-contract.py"
    exit 1
fi
python3 "$INJ"
