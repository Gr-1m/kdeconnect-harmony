// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
// payload 传输状态模型（AP-2，契约见 libkdeconnect_napi/Index.d.ts v2）
export type PayloadDirection = 'send' | 'receive';

export type PayloadState = 'started' | 'progress' | 'finished' | 'failed' | 'cancelled';

export interface PayloadTransfer {
  transferId: number;
  deviceId: string;
  direction: PayloadDirection;
  state: PayloadState;
  fileName: string;
  size: number; // payloadSize；0=无 payload；-1=流式
  bytesDone: number;
  filePath: string; // receive: spool 落盘路径（finished 后交 keepPayload/discardPayload 处置）
  settled: boolean; // 已保存 / 已丢弃（UI 标记，避免重复操作）
  // 结束时间（ms，2026-09-17 加）：文件详情弹窗要展示"什么时间传过来的"；仅终态写入并持久化
  timeMs?: number;
  // 终态错误码（S2 契约 v0.2 §5）：0 成功 / 1 端口超时 / 2 TLS / 3 中断 / 4 本端读失败 /
  // 5 落盘失败 / 6 用户取消 / 7 对端超时未取件。native 未归类时为 undefined（按通用文案呈现）。
  errorCode?: number;
}

// 接收批次（S2 契约 v0.2 §3）：多文件传输按批归并显示（"3/5 文件 · 45% 总字节"）。
// 归并规则：有 share.request.update → 按 numberOfFiles 计数、不设固定超时；
//           无 update → 5s 退化窗口（超过即结算旧批）；任一情况：连接关闭或 30s 无新文件 → 结算「未完成」。
export type PayloadBatchState = 'active' | 'done' | 'incomplete';

export interface PayloadBatch {
  batchId: number;
  deviceId: string;
  direction: PayloadDirection;
  /** 对端声明的文件数；0 = 未声明（5s 退化归并） */
  expectedFiles: number;
  /** 对端声明的总字节；0 = 未声明 */
  totalBytes: number;
  transferIds: number[];
  /** 已进入终态的文件数 / 字节数（用于 "3/5 · 45%"） */
  doneFiles: number;
  doneBytes: number;
  state: PayloadBatchState;
  /** true = 由 share.request.update 开批（计数归并）；false = 5s 退化 */
  declaredByUpdate: boolean;
  /** UI 折叠态（点批头切换） */
  collapsed: boolean;
  lastFileAtMs: number;
}
