// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 【生成文件，勿手改】由 `tools/gen-contract-version.py` 依据 `contract/kcbridge.d.ts` 生成（B-4 / CCR-3 §2.3）。
// 算法（须与 native `contract.rs` 一致）：读契约原始字节 → `\r\n`→`\n` 归一化 → FNV-1a 32 位。
// 契约任何改动 ⇒ 本常量必须重生成（`run.sh` 内有 `--check` 门禁；CI 另比对 native 返回值）。

/** 契约哈希（`contract/kcbridge.d.ts`）；改动即评审点 */
export const EXPECTED_CONTRACT_VERSION: number = 2557471863;

/**
 * 启动校验判定（纯函数，便于宿主单测）：native 返回的契约版本与本常量一致才允许 `start()`。
 * 不匹配 ⇒ 调用方必须**拒绝启动**并记录（E109 语义），不得静默继续（CCR-3 §2.3）。
 */
export function contractVersionOk(actual: number): boolean {
  return actual === EXPECTED_CONTRACT_VERSION;
}
