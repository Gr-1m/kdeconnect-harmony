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

echo "== cargo test -p kdc_native（lib / 契约 / hostile）=="
cargo test -p kdc_native --manifest-path "$MANIFEST" --lib
cargo test -p kdc_native --manifest-path "$MANIFEST" \
    --test contract_errors --test contract_scenarios --test hostile_inputs

# 双栈 E2E：**允许一次重试**（MSG264 §3 裁决；曾观测到一次瞬时抖动，6 次复跑未复现）。
# 注意：避免与模拟器冷启（tools/start-both.sh）并行执行——冷启时宿主 CPU/网络负载会放大时序抖动。
# 若连续复现 ≥2 次，改用 `cargo test ... --test stack_e2e -- --nocapture` 抓明细定位。
echo "== cargo test -p kdc_native --test stack_e2e（失败重试一次）=="
if ! cargo test -p kdc_native --manifest-path "$MANIFEST" --test stack_e2e; then
    echo "!! stack_e2e 第一轮失败 —— 重试一次（MSG264 §3）"
    cargo test -p kdc_native --manifest-path "$MANIFEST" --test stack_e2e
fi

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

# —— native 契约门禁（MSG259 P1-2）：Index.d.ts ↔ napi 导出 / capabilities ↔ bootstrap caps ——
# 失败即门禁失败；脚本缺失同样失败（同 injection 契约口径）。
CTR="$PWD/../../../../../tools/check-native-contract.py"
if [ ! -f "$CTR" ]; then
    echo "native contract checker not found: tools/check-native-contract.py"
    exit 1
fi
python3 "$CTR"

# —— ArkTS native 边界（P0-4/P1-1 阶段 A；Omp-ArkTS）：只能 net/KcBridge.ets import native ——
# 与前面的 injection 契约同口径：脚本缺失或越界都算门禁失败（不得静默跳过）。
NBI="$PWD/../../../../../tools/check-native-import.py"
if [ ! -f "$NBI" ]; then
    echo "native import boundary checker not found: tools/check-native-import.py"
    exit 1
fi
python3 "$NBI"

# —— ArkTS defaultEnabled 镜像 ↔ contract（P1-3；防契约改了开关默认值而 UI 失配）——
PDF="$PWD/../../../../../tools/check-plugin-defaults.py"
if [ ! -f "$PDF" ]; then
    echo "plugin defaults checker not found: tools/check-plugin-defaults.py"
    exit 1
fi
python3 "$PDF"

# —— ArkTS 契约版本常量 ↔ contract/kcbridge.d.ts 哈希（B-4；过期即门禁失败）——
GCV="$PWD/../../../../../tools/gen-contract-version.py"
if [ ! -f "$GCV" ]; then
    echo "contract version generator not found: tools/gen-contract-version.py"
    exit 1
fi
python3 "$GCV" --check

# —— ArkTS 错误码镜像 ↔ contract/errors.v1.json（B-3；码/名/kind/disposition 四项）——
ECC="$PWD/../../../../../tools/check-error-codes.py"
if [ ! -f "$ECC" ]; then
    echo "error code checker not found: tools/check-error-codes.py"
    exit 1
fi
python3 "$ECC"
