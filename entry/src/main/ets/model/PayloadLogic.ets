// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Payload 侧**纯决策函数**（P0-A2 下沉目标；对齐参考库 `kc-core` 的「纯逻辑无 IO/无 Kit」口径）：
//   · 只依赖 `PayloadModels`，**不得** import `@kit.*` / `libkdeconnect_napi.so` / `fileIo`；
//   · 需要 IO 的判定（沙箱副本是否存在）一律由**调用方注入布尔/回调**，故本模块可在宿主（bun）秒级回归；
//   · 这些函数正是近期三次真机回归的判定点（MSG240 弹窗四态、MSG241 过期误判、MSG229 批次计数），
//     详见 `devtools/../devdocs/PLAN_OMPARKTS_20261112.md` P0-A2。
import { PayloadTransfer, PayloadBatch, DetailActionMode } from './PayloadModels';

/** 批头派生计数（从 payloads 现场算，避免状态化计数器漂移） */
export interface BatchCounts {
  done: number;
  bytes: number;
}

/**
 * 文件名清洗（原 `PayloadHistory.safeFileName`）：去路径分隔符/控制字符/前导点，空名回落 `transfer_<tid>`，限长 128。
 * 安全相关：禁止路径穿越（`../`）、禁止隐藏文件（前导 `.`）。
 */
export function sanitizeFileName(raw: string, transferId: number): string {
  let name: string = raw;
  name = name.replace(new RegExp('/', 'g'), '_');
  name = name.replace(new RegExp('\\\\', 'g'), '_');
  name = name.replace(new RegExp('[\\u0000-\\u001F\\u007F]', 'g'), '_');
  while (name.startsWith('.')) {
    name = name.substring(1);
  }
  // 防御：折叠残留的 `..`。分隔符已替换，故此处不影响穿越防护；但保持「文件名里不出现 `..`」，
  // 与既有用例 `TestPayloadController_sanitizeFileName_stripsPathTraversal` 的约定一致。
  name = name.split('..').join('_');
  if (name.length === 0) {
    name = `transfer_${transferId}`;
  }
  if (name.length > 128) {
    name = name.substring(0, 128);
  }
  return name;
}

/** 紧凑时间（HH:MM）；无有效时间戳返回空串（历史聚合行「最近 …」用） */
export function compactTimeText(timeMs: number | undefined): string {
  if (timeMs === undefined || timeMs <= 0) {
    return '';
  }
  const d: Date = new Date(timeMs);
  const hh: string = d.getHours() < 10 ? `0${d.getHours()}` : `${d.getHours()}`;
  const mm: string = d.getMinutes() < 10 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
  return `${hh}:${mm}`;
}

/**
 * 详情弹窗按钮策略（MSG240 §4.2 + MSG243 四态）：
 *   settled 且副本存在 → `openSaveAs`（打开 + 另存为，**不给丢弃**，避免误删已存文件）
 *   settled 但副本已不在 → `none`（仅关闭）
 *   `finished && !settled` → `saveDiscard`（保存 + 丢弃；spool 可能只在 native ⇒ 不看 ArkTS 路径，MSG240 §4.3）
 *   `expired` / 非接收 / 非终态 → `none`
 * `fileExists`：沙箱副本是否存在，由调用方（控制器，具备 fileIo）注入。
 */
export function detailActionModeOf(p: PayloadTransfer, fileExists: boolean): DetailActionMode {
  if (p.direction !== 'receive' || p.state !== 'finished' || p.expired) {
    return 'none';
  }
  if (p.settled) {
    return fileExists ? 'openSaveAs' : 'none';
  }
  return 'saveDiscard';
}

/**
 * 行内是否可处置（行内按钮已按 MSG245 移除，本函数保留给「处置能力」语义与回归用例）：
 * 只否掉「已被启动迁移标记 expired / 已处置 / 非终态 / 非接收」——**不**用 ArkTS 路径判存活。
 */
export function canDisposeOf(p: PayloadTransfer): boolean {
  return !p.expired && p.direction === 'receive' && p.state === 'finished' && !p.settled;
}

/** 批头「已终态文件数 / 已收字节」：`lookup` 由调用方注入（控制器查 payloads） */
export function batchCountsOf(b: PayloadBatch,
  lookup: (transferId: number) => PayloadTransfer | undefined): BatchCounts {
  let done: number = 0;
  let bytes: number = 0;
  for (const tid of b.transferIds) {
    const p: PayloadTransfer | undefined = lookup(tid);
    if (p === undefined) {
      continue;
    }
    if (p.state === 'finished' || p.state === 'failed' || p.state === 'cancelled') {
      done++;
      bytes += p.bytesDone > 0 ? p.bytesDone : p.size;
    }
  }
  return { done: done, bytes: bytes };
}

/**
 * 启动期历史「文件已不在」迁移的单条判定（MSG236 §2② / MSG242 根因与自愈）：
 *   `mark`  = 待处置条目且副本/spool 都不存在 ⇒ 标 `expired`
 *   `clear` = 已标 `expired` 但副本其实存在 ⇒ 撤销（救回被误标的缓存）
 *   `none`  = 不动
 * 仅对「接收方向 + finished + !settled」生效；`fileExists` 由调用方注入。
 */
export function expiryActionFor(p: PayloadTransfer, fileExists: boolean): 'mark' | 'clear' | 'none' {
  if (p.direction !== 'receive' || p.state !== 'finished' || p.settled) {
    return 'none';
  }
  if (p.expired) {
    return fileExists ? 'clear' : 'none';
  }
  return fileExists ? 'none' : 'mark';
}
