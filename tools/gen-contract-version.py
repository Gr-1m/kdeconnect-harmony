#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 契约版本生成 / 校验（B-4；CCR-3 §2.3；MSG268 §1.3）。
#
# 契约版本 = 桥层契约文件 `contract/kcbridge.d.ts` 的内容哈希。**算法必须与 Rust 侧
# `kdc_native::contract::contract_version_of` 逐字节一致**：
#
#   1. 读 `contract/kcbridge.d.ts` 原始字节；
#   2. **换行归一化**：`\r\n` → `\n`（两机协作：Win10 工作区可能是 CRLF，不能让哈希随之漂移）；
#   3. 其余字节**原样**参与（孤立 `\r` 保留）；
#   4. **FNV-1a 32 位**（offset basis `0x811c9dc5`，prime `0x01000193`，逐字节 `h ^= b; h *= prime`）。
#
# 用 FNV-1a 的理由：零依赖（Rust/Python 各 6 行即可一致）、确定性、无需引入哈希 crate。
#
# 用法：
#   python3 tools/gen-contract-version.py            # 校验（默认，等价 --check）；不一致 ⇒ rc=1，不写文件
#   python3 tools/gen-contract-version.py --update   # 写入两个吊床点（Rust 常量 + ArkTS 常量）
#   python3 tools/gen-contract-version.py --require-ets  # 校验时把「ArkTS 常量缺失」也判失败
#
# 吊床点（hook）：
#   1. Rust：`entry/src/main/cpp/rust/full/core/src/contract.rs` 的 `CONTRACT_VERSION_EXPECTED`
#      —— 运行时值由 `include_str!` 嵌入的契约算出，单测与它比对；
#   2. ArkTS：`entry/src/main/ets/common/ContractVersion.ets` 的 `EXPECTED_CONTRACT_VERSION`
#      —— 桥层启动早期与 native `contractVersion()` 比对，不匹配 ⇒ 拒绝 `start()`（E109 语义）。

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTRACT = ROOT / 'contract/kcbridge.d.ts'
RUST_CONST_RS = ROOT / 'entry/src/main/cpp/rust/full/core/src/contract.rs'
ETS_TARGET = ROOT / 'entry/src/main/ets/common/ContractVersion.ets'

RUST_CONST_NAME = 'CONTRACT_VERSION_EXPECTED'
ETS_CONST_NAME = 'EXPECTED_CONTRACT_VERSION'
FNV_OFFSET = 0x811C9DC5
FNV_PRIME = 0x01000193
MASK32 = 0xFFFFFFFF


def contract_version() -> int:
    raw = CONTRACT.read_bytes().replace(b'\r\n', b'\n')
    h = FNV_OFFSET
    for b in raw:
        h = (h ^ b) & MASK32
        h = (h * FNV_PRIME) & MASK32
    return h


def render_ets(version: int) -> str:
    return f'''// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 【生成文件，勿手改】由 `tools/gen-contract-version.py` 依据 `contract/kcbridge.d.ts` 生成（B-4 / CCR-3 §2.3）。
// 算法（须与 native `contract.rs` 一致）：读契约原始字节 → `\\r\\n`→`\\n` 归一化 → FNV-1a 32 位。
// 契约任何改动 ⇒ 本常量必须重生成（`run.sh` 内有 `--check` 门禁；CI 另比对 native 返回值）。

/** 契约哈希（`contract/kcbridge.d.ts`）；改动即评审点 */
export const {ETS_CONST_NAME}: number = {version};

/**
 * 启动校验判定（纯函数，便于宿主单测）：native 返回的契约版本与本常量一致才允许 `start()`。
 * 不匹配 ⇒ 调用方必须**拒绝启动**并记录（E109 语义），不得静默继续（CCR-3 §2.3）。
 */
export function contractVersionOk(actual: number): boolean {{
  return actual === {ETS_CONST_NAME};
}}
'''


def read_rust_constant(text: str) -> int | None:
    m = re.search(rf'pub const {RUST_CONST_NAME}: u32 = (0x[0-9a-fA-F_]+);', text)
    return int(m.group(1).replace('_', ''), 16) if m else None


def write_rust_constant(value: int) -> None:
    text = RUST_CONST_RS.read_text(encoding='utf-8')
    new = re.sub(
        rf'(pub const {RUST_CONST_NAME}: u32 = )0x[0-9a-fA-F_]+;',
        lambda m: f'{m.group(1)}0x{value:08x};',
        text,
    )
    if new == text:
        raise SystemExit(f'FAIL: 未找到 {RUST_CONST_NAME} 定义 → {RUST_CONST_RS}')
    RUST_CONST_RS.write_text(new, encoding='utf-8')


def read_ets_constant() -> int | None:
    if not ETS_TARGET.is_file():
        return None
    m = re.search(rf'{ETS_CONST_NAME}\s*:\s*number\s*=\s*(0x[0-9a-fA-F]+|\d+)', ETS_TARGET.read_text(encoding='utf-8'))
    return int(m.group(1), 0) if m else None


def main() -> int:
    args = sys.argv[1:]
    update = '--update' in args
    require_ets = '--require-ets' in args

    if not CONTRACT.is_file():
        print(f'FAIL: 契约文件缺失 → {CONTRACT}')
        return 2
    version = contract_version()

    if update:
        write_rust_constant(version)
        ETS_TARGET.parent.mkdir(parents=True, exist_ok=True)
        ETS_TARGET.write_text(render_ets(version), encoding='utf-8')
        print(f'[OK] 已更新契约版本 {version}（0x{version:08x}）：{RUST_CONST_RS.name} + {ETS_TARGET.relative_to(ROOT)}')
        return 0

    failures = []
    rust_value = read_rust_constant(RUST_CONST_RS.read_text(encoding='utf-8'))
    if rust_value != version:
        failures.append(
            f'Rust 常量 {rust_value if rust_value is None else hex(rust_value)} != 契约哈希 0x{version:08x}'
            f'（跑 `python3 tools/gen-contract-version.py --update`）'
        )
    ets_value = read_ets_constant()
    if ets_value is None:
        if require_ets:
            failures.append(f'ArkTS 常量缺失：{ETS_TARGET.relative_to(ROOT)}')
        else:
            print(f'NOTE: ArkTS 常量缺失（{ETS_TARGET.relative_to(ROOT)}）→ 跑 `--update` 生成')
    elif ets_value != version:
        failures.append(
            f'ArkTS 常量 {hex(ets_value)} != 契约哈希 0x{version:08x}'
            f'（跑 `python3 tools/gen-contract-version.py --update`）'
        )

    if failures:
        for f in failures:
            print(f'FAIL: {f}')
        return 1
    print(f'[PASS] 契约版本 0x{version:08x} 与各吊床点一致（Rust + ArkTS）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
