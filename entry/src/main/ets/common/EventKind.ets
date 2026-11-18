// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// B-1 —— 冻结契约 `EventKind`（18 项，CCR-3a 后 0–17）→ 内部 `NetEvent` 的单映射表 + 解码（**零 Kit 依赖** ⇒ 宿主 bun 与设备 hypium 双跑）。
//
// 单一事实源：`contract/kcbridge.d.ts` 的 `EventKind`；本文件是 ArkTS 镜像，由 `tools/check-event-kinds.py` 逐项核对（run.sh 门禁）。
//
// 契约口径（CCR-3 §2.2 / MSG276 §3 / MSG277 §2）：
//   · `Log(14)`          → **LogStore**（不是内部事件；不得静默丢弃）；
//   · `Error(17)`        → 内部 `error`（`errorCode`/`errorMessage`，按 `KcError` 分级处置 = B-3）；
//   · 无内部事件的 kind  → **显式丢弃 + 日志**（`EngineStarted(0)`/`EngineInitFailed(1)`/`EngineStopped(2)`/
//                          `DeviceUpdated(5)`/`Unpaired(6)`/`PairResult(8)`/`TransferOffer(11)`：native `kind_of` 当前不产出，
//                          出现即说明契约层新增了语义 ⇒ 必须记录而不是静默吞掉）；
//   · 未知 kind          → 丢弃 + 日志；
//   · 坏 JSON / kind 与 `type` 不一致 → 丢弃 + 日志（防契约漂移被静默吞下）。
import { NetEvent } from './EventShapes';

/** 冻结契约的 18 项 kind 名单（含当前无内部事件的项；用于诊断文案） */
export const EVENT_KIND_NAMES: Map<number, string> = new Map<number, string>([
  [0, 'EngineStarted'],
  [1, 'EngineInitFailed'],
  [2, 'EngineStopped'],
  [3, 'DeviceVisible'],
  [4, 'DeviceGone'],
  [5, 'DeviceUpdated'],
  [6, 'Unpaired'],
  [7, 'PairRequest'],
  [8, 'PairResult'],
  [9, 'Packet'],
  [10, 'TransferStarted'],
  [11, 'TransferOffer'],
  [12, 'TransferProgress'],
  [13, 'TransferDone'],
  [14, 'Log'],
  [15, 'Connected'],
  [16, 'Disconnected'],
  [17, 'Error']
]);

/**
 * kind → 期望的内部 `NetEvent.type`（与 native `core/src/events.rs::kind_of` 的产出集合一致）。
 * `TransferStarted/Progress/Done(10/12/13)` 折叠为同一内部类型（状态在 `payloadState` 里）。
 */
export const EVENT_KIND_TO_TYPE: Map<number, string> = new Map<number, string>([
  [3, 'deviceDiscovered'],
  [4, 'deviceLost'],
  [7, 'pairingRequest'],
  [9, 'packetReceived'],
  [10, 'payloadTransfer'],
  [12, 'payloadTransfer'],
  [13, 'payloadTransfer'],
  [15, 'connected'],
  [16, 'disconnected'],
  [17, 'error']
]);

/** LogStore 出口（由页面注入；缺省只写宿主 console） */
let logSink: (msg: string) => void = (msg: string): void => {
  console.warn(msg);
};

export function setEventLogSink(fn: (msg: string) => void): void {
  logSink = fn;
}

/** 被丢弃的事件计数（诊断用：真机可查「契约漂移是否在吞事件」） */
export const droppedEvents: Map<string, number> = new Map<string, number>();

function noteDrop(kind: number, why: string): void {
  const name: string = EVENT_KIND_NAMES.get(kind) ?? `unknown(${kind})`;
  const key: string = `${kind}:${why}`;
  droppedEvents.set(key, (droppedEvents.get(key) ?? 0) + 1);
  logSink(`native event dropped: kind=${kind} (${name}) ${why}`);
}

/**
 * kind + JSON → 内部 `NetEvent`。
 * 返回 `undefined` = 已按契约处置（Log 入日志 / 显式丢弃 + 日志），调用方不得再转发。
 */
export function decodeEvent(kind: number, json: string): NetEvent | undefined {
  if (kind === 14) {
    // Log(14)：入 LogStore（CCR-3 §2.2）
    logSink(`native log: ${json}`);
    return undefined;
  }
  const expected: string | undefined = EVENT_KIND_TO_TYPE.get(kind);
  if (expected === undefined) {
    noteDrop(kind, 'no internal event mapped (explicit drop per CCR-3 §2.2)');
    return undefined;
  }
  let parsed: NetEvent;
  try {
    parsed = JSON.parse(json) as NetEvent;
  } catch (e) {
    noteDrop(kind, 'bad json');
    return undefined;
  }
  if (parsed.type !== expected) {
    // kind 与 type 不一致 ⇒ 契约漂移，宁可丢弃 + 记录，也不把错形状喂给控制器
    noteDrop(kind, `type mismatch: got ${parsed.type}, expected ${expected}`);
    return undefined;
  }
  return parsed;
}
