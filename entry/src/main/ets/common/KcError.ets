// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 桥层错误码表 + 分级处置（B-3；CCR-3 生效后落地；**零 Kit 依赖** ⇒ 宿主 bun 与设备 hypium 双跑）。
//
// 单一事实源是 `contract/errors.v1.json`（20 码：101–109 / 2xx / 3xx / 4xx / 5xx）；
// 本文件是它的 ArkTS 镜像，由 `tools/check-error-codes.py` 逐项核对（接在 run.sh 门禁里，防漂移）。
//
// disposition 语义（CCR-3 §2.2 / errors.v1.json）：
//   * `FatalLink`  —— 链路级致命：**用户可见**（toast/通知）+ 日志；链路按断开处理；
//   * `DropPacket` —— 丢弃该包后继续：只记日志（不打扰用户）；
//   * `Infra`      —— 基础设施/内部问题：只记日志；**未知码一律按 Infra**（不崩、不静默）。
// 错误文本格式固定为 `KC_E<code>: <message>`（可检索；CCR-3 §2）。

export type KcKind = 'throw' | 'event';
export type KcDisposition = 'FatalLink' | 'DropPacket' | 'Infra';

export interface KcErrorInfo {
  code: number;
  name: string;
  kind: KcKind;
  disposition: KcDisposition;
}

/** `contract/errors.v1.json` 的镜像（20 码） */
export const KC_ERRORS: Map<number, KcErrorInfo> = new Map<number, KcErrorInfo>([
  [101, { code: 101, name: 'NOT_READY', kind: 'throw', disposition: 'FatalLink' }],
  [102, { code: 102, name: 'NOT_STARTED', kind: 'throw', disposition: 'FatalLink' }],
  [103, { code: 103, name: 'ALREADY_STARTED', kind: 'throw', disposition: 'FatalLink' }],
  [104, { code: 104, name: 'BAD_JSON', kind: 'throw', disposition: 'DropPacket' }],
  [105, { code: 105, name: 'BAD_PARAM', kind: 'throw', disposition: 'DropPacket' }],
  [109, { code: 109, name: 'CONTRACT_MISMATCH', kind: 'throw', disposition: 'FatalLink' }],
  [201, { code: 201, name: 'CERT_MISMATCH', kind: 'event', disposition: 'FatalLink' }],
  [202, { code: 202, name: 'PROTOCOL_VIOLATION', kind: 'event', disposition: 'FatalLink' }],
  [203, { code: 203, name: 'LINE_TOO_LONG', kind: 'event', disposition: 'FatalLink' }],
  [204, { code: 204, name: 'IDENTITY_INVALID', kind: 'event', disposition: 'FatalLink' }],
  [205, { code: 205, name: 'CLOCK_SKEW', kind: 'event', disposition: 'DropPacket' }],
  [301, { code: 301, name: 'PEER_NOT_CONNECTED', kind: 'event', disposition: 'DropPacket' }],
  [302, { code: 302, name: 'OFFER_TIMEOUT', kind: 'event', disposition: 'DropPacket' }],
  [303, { code: 303, name: 'TRANSFER_CANCELLED', kind: 'event', disposition: 'DropPacket' }],
  [401, { code: 401, name: 'PAYLOAD_TIMEOUT', kind: 'event', disposition: 'DropPacket' }],
  [402, { code: 402, name: 'FILE_IO', kind: 'event', disposition: 'Infra' }],
  [403, { code: 403, name: 'SEND_FAILED', kind: 'event', disposition: 'DropPacket' }],
  [501, { code: 501, name: 'ENGINE_PANIC', kind: 'event', disposition: 'Infra' }],
  [502, { code: 502, name: 'IDENTITY_INVALID_ON_START', kind: 'event', disposition: 'Infra' }],
  [503, { code: 503, name: 'INIT_FAILED', kind: 'event', disposition: 'Infra' }]
]);

/** 码表查询：未知码 ⇒ undefined（调用方按 `dispositionOf` 的兜底处理） */
export function kcErrorInfo(code: number): KcErrorInfo | undefined {
  return KC_ERRORS.get(code);
}

/** 分级：未知码 ⇒ `Infra`（不崩、只记日志） */
export function dispositionOf(code: number): KcDisposition {
  const info: KcErrorInfo | undefined = KC_ERRORS.get(code);
  return info === undefined ? 'Infra' : info.disposition;
}

/** 错误名（日志/诊断用）；未知码 ⇒ `UNKNOWN` */
export function nameOf(code: number): string {
  const info: KcErrorInfo | undefined = KC_ERRORS.get(code);
  return info === undefined ? 'UNKNOWN' : info.name;
}

/** 链路是否致命（调用方据此考虑断链/清理） */
export function isLinkFatal(code: number): boolean {
  return dispositionOf(code) === 'FatalLink';
}

/** 是否需要**用户可见**提示（只有 FatalLink 打扰用户；DropPacket/Infra 只记日志） */
export function uiNoticeFor(code: number): boolean {
  return dispositionOf(code) === 'FatalLink';
}

/** 统一文本：`KC_E<code>: <message>`（空 message 只留前缀） */
export function formatKcError(code: number, message: string): string {
  const msg: string = message.length > 0 ? message : nameOf(code);
  return `KC_E${code}: ${msg}`;
}
