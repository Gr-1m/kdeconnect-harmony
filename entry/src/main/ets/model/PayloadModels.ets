// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
// payload 传输状态模型（AP-2，契约见 libkdeconnect_napi/Index.d.ts v2）
export type PayloadDirection = 'send' | 'receive';

export type PayloadState = 'started' | 'progress' | 'finished' | 'failed' | 'cancelled';

// 文件详情弹窗的按钮策略（MSG240 §4.2 / MSG243）：
//  settled 且文件在 → 'openSaveAs'（打开 + 另存为，**不给丢弃**）；settled 但文件不在 → 'none'；
//  finished&&!settled → 'saveDiscard'（保存 + 丢弃）；expired / 非接收 → 'none'（仅关闭）
export type DetailActionMode = 'openSaveAs' | 'saveDiscard' | 'none';

// 构造/更新用的入参形态（纯字段，便于对象字面量传参）
export interface PayloadTransferInit {
  transferId: number;
  deviceId: string;
  direction: PayloadDirection;
  state: PayloadState;
  fileName: string;
  size: number; // payloadSize；0=无 payload；-1=流式
  bytesDone: number;
  filePath: string; // receive: spool 落盘路径（finished 后交 keepPayload/discardPayload 处置）
  settled: boolean; // 已保存 / 已丢弃（UI 标记，避免重复操作）
  // B2（2026-11-09）：true = 只落在**应用沙箱**（非媒体文件无免交互公共目录 API）⇒ UI 显示「已保存到应用内」并给「导出」入口
  sandboxOnly?: boolean;
  // MSG236 ②：启动校正后的「不可处置」历史（spool/沙箱副本已不存在）——UI 显示「已结束」且不给按钮
  expired?: boolean;
  // 结束时间（ms，2026-09-17 加）：文件详情弹窗要展示"什么时间传过来的"；仅终态写入并持久化
  timeMs?: number;
  // 终态错误码（S2 契约 v0.2 §5）：0 成功 / 1 端口超时 / 2 TLS / 3 中断 / 4 本端读失败 /
  // 5 落盘失败 / 6 用户取消 / 7 对端超时未取件。native 未归类时为 undefined（按通用文案呈现）。
  errorCode?: number;
}

/**
 * 传输条目（UI 数据源）。
 * **@Observed + 原地写字段**：行组件用 `@ObjectLink transfer` 绑定 ⇒ 进度等字段变化即刻重渲染该行。
 * （V1 里「稳定 ForEach key + 标量 @Prop」会让子组件冻结在首帧，是 MSG229 §2「进度不动/仍显示接收中」的根因，
 * 见 devdocs/ARKTS_GUIDE.md §4.9。）
 * `uid`：实例代号（不持久化）。控制器在同一 tid 上换新实例（如 started 顶替旧条目）时 key 变化 ⇒ 行重建，
 * 避免 ForEach 复用旧子组件仍绑到旧实例。
 */
@Observed
export class PayloadTransfer {
  private static seq: number = 0;

  uid: number = 0;
  transferId: number = 0;
  deviceId: string = '';
  direction: PayloadDirection = 'receive';
  state: PayloadState = 'failed';
  fileName: string = '';
  size: number = 0;
  bytesDone: number = 0;
  filePath: string = '';
  settled: boolean = false;
  sandboxOnly: boolean = false;
  expired: boolean = false;
  timeMs: number | undefined = undefined;
  errorCode: number | undefined = undefined;

  static of(init: PayloadTransferInit): PayloadTransfer {
    const t: PayloadTransfer = new PayloadTransfer();
    PayloadTransfer.seq++;
    t.uid = PayloadTransfer.seq;
    t.apply(init);
    return t;
  }

  /** 原地写入全部业务字段（保持实例身份 ⇒ @ObjectLink 行感知变化） */
  apply(init: PayloadTransferInit): void {
    this.transferId = init.transferId;
    this.deviceId = init.deviceId;
    this.direction = init.direction;
    this.state = init.state;
    this.fileName = init.fileName;
    this.size = init.size;
    this.bytesDone = init.bytesDone;
    this.filePath = init.filePath;
    this.settled = init.settled;
    this.sandboxOnly = init.sandboxOnly === true;
    this.expired = init.expired === true;
    this.timeMs = init.timeMs;
    this.errorCode = init.errorCode;
  }
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
  state: PayloadBatchState;
  /** true = 由 share.request.update 开批（计数归并）；false = 5s 退化 */
  declaredByUpdate: boolean;
  /** UI 折叠态（点批头切换） */
  collapsed: boolean;
  lastFileAtMs: number;
}
