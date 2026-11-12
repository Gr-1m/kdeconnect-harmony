// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 文件传输领域控制器（阶段 3 / 批次 2 步骤 6b-1；CodeArts MSG62、设计见 devdocs/DESIGN_BATCH2_deveco.md）。
//
// 抽离自 Index.ets 的 payload 传输共 27 个方法（L1710–L2428，逐字保真，零语义变更）。
//
// 分层（与 PairSession / MprisController 同一套范式）：
//   · 本类持有领域状态：payloads（进行中/本轮）、history（跨重启）、弹窗开关、发送队列；
//   · 不碰 I/O 与平台能力：日志、提示、文件选择器、权限申请、历史持久化全部注入；
//   · native（keepPayload/discardPayload/cancelPayload/sendPayload）直接 import —— NAPI 不需要 Context；
//   · `@Observed` ⇒ 页面 @State 持实例、Dialog 以 @ObjectLink 读。
//
// 不变量（勿改）：
//   ① payload 终态是队列推进的唯一依据（别加 sleep）；
//   ② payloadSize>0 ∧ payloadTransferId==0 不建条目；
//   ③ safeFileName 单一来源（PayloadHistory.safeFileName）；
//   ④ 终态兜底（failInflightReceives）：控制连接断开 ⇒ 进行中的接收不可能再完成，立即落 failed。

import native from 'libkdeconnect_napi.so';
import { NetEvent } from 'libkdeconnect_napi.so';
import { PayloadTransfer, PayloadTransferInit, PayloadDirection, PayloadState, PayloadBatch, PayloadBatchState, DetailActionMode } from '../model/PayloadModels';
// P0-A2：纯决策下沉到 model/PayloadLogic（零 Kit/native 依赖 ⇒ 宿主 bun 秒级回归；判定点即近期三次真机回归处）
import {
  BatchCounts, sanitizeFileName as pureSanitizeFileName, compactTimeText as pureCompactTimeText,
  detailActionModeOf, canDisposeOf, batchCountsOf, expiryActionFor
} from '../model/PayloadLogic';
import { PayloadHistory } from '../common/PayloadHistory';
import { fileIo, picker, fileUri } from '@kit.CoreFileKit';
import { Context, abilityAccessCtrl, Permissions, common, wantConstant, Want } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

// B1：接收条目 watchdog（started 后 30s 无进展 ⇒ 落 failed，避免「接收中」僵尸常驻）
const RECV_WATCHDOG_MS: number = 30000;
// B3：已丢弃 transferId 的记忆上限（防止迟到事件重建条目）
const DISCARD_KEEP: number = 200;
// 权限申请超时（MSG234 §4.1）：超时即视为未授权 → 降级「应用内」，避免整条保存链挂住
const PERM_TIMEOUT_MS: number = 3500;
// 已计入批计数的 transferId 记忆上限（防长跑会话无限增长）

// MSG223 B：晚到预告的暂存结构
interface PayloadBatchHint {
  deviceId: string;
  expectedFiles: number;
  totalBytes: number;
  isUpdate: boolean;
}

// 多选发送的单个任务（文件已复制进沙箱，等队列轮到它）
export interface SendJob {
  cachePath: string;
  fileName: string;
}

@Observed
export class PayloadController {
  // ---------- 领域状态（原 Index 的 @State）----------
  payloads: PayloadTransfer[] = [];          // 进行中/本轮（进度行）
  history: PayloadTransfer[] = [];           // 原 @State receivedHistory（跨重启，经 PayloadHistory 持久化）
  detailOpen: boolean = false;               // 原 @State payloadDetailOpen
  detailId: number = 0;                      // 原 @State payloadDetailId

  // S2 接收批次（契约 v0.2 §3）：按批归并显示；开批/计数/结算规则见 onBatchHint 与 attachToReceiveBatch
  batches: PayloadBatch[] = [];
  private batchSeq: number = 0;
  // MSG223 B：晚到的 share.request 预告（此时无活跃批也无可认领的在传条目）⇒ 挂起，等下一个 started 认领，
  // 否则会开出一个永远 0/1 的空批
  private pendingHint: PayloadBatchHint | undefined = undefined;
  private batchTimers: Map<number, number> = new Map();
  // B1：接收 watchdog（tid → timer）
  private recvWatchdogs: Map<number, number> = new Map();
  // B3：已丢弃的 transferId —— handlePayloadTransfer/cancelPayload 见到即幂等返回，防「丢弃后复活」
  private discardedIds: number[] = [];
  // MSG229 §1.4：媒体权限弹窗「本次会话只申请一次」（避免每次收图都弹）
  private mediaPermAsked: boolean = false;

  // 多选发送串行队列（原 private 字段）
  sendQueue: SendJob[] = [];
  sendBusyId: number = -1;
  sendInflightJob: SendJob | undefined = undefined;
  sendTarget: string = '';
  sendOkCount: number = 0;
  sendTotal: number = 0;

  // ---------- 注入：平台能力（本类不碰 I/O / 不在场能力）----------
  log: (msg: string) => void = () => {};
  toast: (msg: string) => void = () => {};
  resText: (resId: number) => string = () => '';
  hostFilesDir: () => string = () => '';
  pickSaveTarget: (name: string) => Promise<string> = () => Promise.resolve('');
  pickDownloadTarget: (name: string) => Promise<string> = () => Promise.resolve('');
  requestWritePermission: (fileName: string) => Promise<boolean> = () => Promise.resolve(true);
  persistHistory: (history: PayloadTransfer[]) => Promise<void> = () => Promise.resolve();
  clearPersistedHistory: () => Promise<void> = () => Promise.resolve();
  connectedDeviceIds: () => string[] = () => [];
  // S2 §3.5：接收完成后是否自动保存（false → 落 spool 进「待处置」，由用户保存/丢弃）
  autoSaveEnabled: () => boolean = () => true;
  // B2：媒体库（photoAccessHelper）需要 Context
  hostContext: () => Context | undefined = () => undefined;
  // MSG223 A：**自动流程专用**权限查询（只查不弹）。自动保存绝不能 await 权限弹窗
  // —— 真机实测 png 分支因 requestPermissionsFromUser 挂住 ⇒ 后续日志全无、批次不收敛。
  checkWritePermission: (fileName: string) => boolean = (_fileName: string) => false;

  // ========== 状态转换（原 L1710–L1728）==========

  toDirection(v: string): PayloadDirection {
    return v === 'send' ? 'send' : 'receive';
  }

  toState(v: string): PayloadState {
    if (v === 'started') {
      return 'started';
    }
    if (v === 'progress') {
      return 'progress';
    }
    if (v === 'finished') {
      return 'finished';
    }
    if (v === 'cancelled') {
      return 'cancelled';
    }
    return 'failed';
  }

  // ========== 终态兜底（原 L1735–L1768）==========

  failInflightReceives(deviceId: string, reason: string): void {
    if (deviceId.length === 0) {
      return;
    }
    let changed: boolean = false;
    const next: PayloadTransfer[] = this.payloads.map((p: PayloadTransfer): PayloadTransfer => {
      const active: boolean = p.state === 'started' || p.state === 'progress';
      if (p.direction !== 'receive' || !active) {
        return p;
      }
      if (deviceId.length > 0 && p.deviceId !== deviceId) {
        return p;
      }
      changed = true;
      const failed: PayloadTransfer = PayloadTransfer.of({
        transferId: p.transferId,
        deviceId: p.deviceId,
        direction: p.direction,
        state: 'failed',
        fileName: p.fileName,
        size: p.size,
        bytesDone: p.bytesDone,
        filePath: p.filePath,
        settled: p.settled,
        sandboxOnly: p.sandboxOnly === true
      });
      return failed;
    });
    if (changed) {
      this.payloads = next;
      console.info(`KDC payload inflight -> failed (${reason}) dev=${deviceId.substring(0, 8)}`);
    }
    // S2：连接关闭 → 该设备的活跃批次结算为「未完成」
    this.settleBatchesForDevice(deviceId, 'incomplete',
      `device disconnected (${reason})`);
    if (this.pendingHint !== undefined && this.pendingHint.deviceId === deviceId) {
      this.pendingHint = undefined;
    }
  }

  // ==================== S2 接收批次（契约 v0.2 §3）====================

  /** 插件预告入口（Index 经 eventBus 'share.batch' 调用）：numberOfFiles/totalPayloadSize */
  onBatchHint(deviceId: string, numberOfFiles: number, totalPayloadSize: number, isUpdate: boolean): void {
    if (deviceId.length === 0 || numberOfFiles <= 0) {
      return;
    }
    const idx: number = this.activeReceiveBatchIndex(deviceId);
    if (idx < 0) {
      // MSG223 B：没有活跃批时，只有在**确有在传条目**的情况下才开批；
      // 否则（预告晚于传输结束）挂起，等下一个 started 认领 —— 避免产生永远 0/1 的空批
      if (!this.hasActiveReceive(deviceId)) {
        this.pendingHint = { deviceId: deviceId, expectedFiles: numberOfFiles, totalBytes: totalPayloadSize, isUpdate: isUpdate };
        return;
      }
      this.openBatch(deviceId, numberOfFiles, totalPayloadSize, isUpdate);
      this.log(`batch opened by ${isUpdate ? 'update' : 'request'}: ${numberOfFiles} files / ${totalPayloadSize} B`);
      return;
    }
    // 已有活跃批：刷新分母（对端可能修正总计）
    this.batches = this.batches.map((b: PayloadBatch, i: number): PayloadBatch => {
      if (i !== idx) {
        return b;
      }
      const next: PayloadBatch = this.copyBatch(b);
      next.expectedFiles = numberOfFiles;
      next.totalBytes = totalPayloadSize;
      next.declaredByUpdate = next.declaredByUpdate || isUpdate;
      return next;
    });
  }

  private copyBatch(b: PayloadBatch): PayloadBatch {
    const next: PayloadBatch = {
      batchId: b.batchId,
      deviceId: b.deviceId,
      direction: b.direction,
      expectedFiles: b.expectedFiles,
      totalBytes: b.totalBytes,
      transferIds: b.transferIds.slice(0),
      state: b.state,
      declaredByUpdate: b.declaredByUpdate,
      collapsed: b.collapsed,
      lastFileAtMs: b.lastFileAtMs
    };
    return next;
  }

  private hasActiveReceive(deviceId: string): boolean {
    for (const p of this.payloads) {
      if (p.direction === 'receive' && p.deviceId === deviceId
        && (p.state === 'started' || p.state === 'progress')) {
        return true;
      }
    }
    return false;
  }

  private activeReceiveBatchIndex(deviceId: string): number {
    for (let i = 0; i < this.batches.length; i++) {
      const b: PayloadBatch = this.batches[i];
      if (b.deviceId === deviceId && b.direction === 'receive' && b.state === 'active') {
        return i;
      }
    }
    return -1;
  }

  private openBatch(deviceId: string, expected: number, total: number, declared: boolean): void {
    this.batchSeq++;
    const b: PayloadBatch = {
      batchId: this.batchSeq,
      deviceId: deviceId,
      direction: 'receive',
      expectedFiles: expected,
      totalBytes: total,
      transferIds: [],
      state: 'active',
      declaredByUpdate: declared,
      collapsed: false,
      lastFileAtMs: Date.now()
    };
    this.batches = [b].concat(this.batches);
    this.armBatchIdleTimer(b.batchId);
  }

  /** 30s 无新文件 → 结算「未完成」（契约 §3 批次边界） */
  private armBatchIdleTimer(batchId: number): void {
    this.clearBatchTimer(batchId);
    const t: number = setTimeout((): void => {
      this.batchTimers.delete(batchId);
      this.settleBatch(batchId, 'incomplete', 'no new file for 30s');
    }, 30000);
    this.batchTimers.set(batchId, t);
  }

  private clearBatchTimer(batchId: number): void {
    const t: number | undefined = this.batchTimers.get(batchId);
    if (t !== undefined) {
      clearTimeout(t);
      this.batchTimers.delete(batchId);
    }
  }

  private settleBatch(batchId: number, state: PayloadBatchState, why: string): void {
    let hit: boolean = false;
    this.batches = this.batches.map((b: PayloadBatch): PayloadBatch => {
      if (b.batchId !== batchId || b.state !== 'active') {
        return b;
      }
      hit = true;
      const next: PayloadBatch = this.copyBatch(b);
      next.state = state;
      return next;
    });
    if (hit) {
      this.clearBatchTimer(batchId);
      this.log(`batch #${batchId} settled ${state} (${why})`);
      // B1：批结算后不得残留「接收中」僵尸行
      this.failActiveTransfersOfBatch(batchId, why);
      // MSG223 B/229：零产出批直接从列表移除（判据改为派生计数），杜绝 "0/1 · 0% · 接收中" 长期残留
      const b: PayloadBatch | undefined = this.batchById(batchId);
      if (b !== undefined && this.batchCounts(b).done === 0) {
        this.batches = this.batches.filter((x: PayloadBatch) => x.batchId !== batchId);
      }
    }
  }

  private settleBatchesForDevice(deviceId: string, state: PayloadBatchState, why: string): void {
    for (const b of this.batches) {
      if (b.deviceId === deviceId && b.state === 'active') {
        this.settleBatch(b.batchId, state, why);
      }
    }
  }

  /** 接收条目挂批：无活跃批则开批；未声明批超 5s 退化窗口则结算旧批后开新批 */
  private attachToReceiveBatch(item: PayloadTransfer, isNewEntry: boolean, state: PayloadState): void {
    const now: number = Date.now();
    // ① 该 transferId 已归过批（含已结算批）：只更新计数，绝不新建（否则同一文件会出现在两个批里）
    const owner: PayloadBatch | undefined = this.batchOfTransfer(item.transferId);
    if (owner !== undefined) {
      this.updateBatchCounters(owner.batchId, item, state, now);
      return;
    }
    let idx: number = this.activeReceiveBatchIndex(item.deviceId);
    if (idx >= 0 && isNewEntry && !this.batches[idx].declaredByUpdate
      && now - this.batches[idx].lastFileAtMs > 5000) {
      this.settleBatch(this.batches[idx].batchId, 'done', '5s degrade window closed');
      idx = -1;
    }
    if (idx < 0) {
      const hint: PayloadBatchHint | undefined = this.pendingHint;
      if (hint !== undefined && hint.deviceId === item.deviceId) {
        this.pendingHint = undefined;
        this.openBatch(item.deviceId, hint.expectedFiles, hint.totalBytes, hint.isUpdate);
      } else {
        this.openBatch(item.deviceId, 0, 0, false);
      }
      idx = 0;
    }
    const batchId: number = this.batches[idx].batchId;
    this.updateBatchCounters(batchId, item, state, now);
  }

  /** 把一次 payload 事件计入批（新增 transferId / 终态计数）；完成判定只看**已终态**文件数 */
  private updateBatchCounters(batchId: number, item: PayloadTransfer, state: PayloadState, now: number): void {
    this.batches = this.batches.map((b: PayloadBatch): PayloadBatch => {
      if (b.batchId !== batchId) {
        return b;
      }
      const next: PayloadBatch = this.copyBatch(b);
      if (!next.transferIds.includes(item.transferId)) {
        next.transferIds = next.transferIds.concat([item.transferId]);
      }
      next.lastFileAtMs = now;
      // 计数不再维护状态：批头/完成判定一律用 batchCounts(b) 从 payloads 现场派生
      return next;
    });
    const b2: PayloadBatch | undefined = this.batchById(batchId);
    if (b2 === undefined) {
      return;
    }
    if (b2.state === 'active') {
      this.armBatchIdleTimer(batchId);
      // 完成判定：**所有声明文件都已终态**才算完成（先前用「已见文件数」会在最后一个文件刚 started 时就结算，
      // 于是它的 finished 事件找不到活跃批、另开一个批 —— 2026-11-08 实机复现）
      const counts: BatchCounts = this.batchCounts(b2);
      if (b2.expectedFiles > 0 && counts.done >= b2.expectedFiles) {
        this.settleBatch(batchId, 'done', `${counts.done}/${b2.expectedFiles} files terminal`);
      }
    }
  }

  batchById(batchId: number): PayloadBatch | undefined {
    for (const b of this.batches) {
      if (b.batchId === batchId) {
        return b;
      }
    }
    return undefined;
  }

  batchOfTransfer(transferId: number): PayloadBatch | undefined {
    for (const b of this.batches) {
      if (b.transferIds.includes(transferId)) {
        return b;
      }
    }
    return undefined;
  }

  toggleBatch(batchId: number): void {
    this.batches = this.batches.map((b: PayloadBatch): PayloadBatch => {
      if (b.batchId !== batchId) {
        return b;
      }
      const next: PayloadBatch = this.copyBatch(b);
      next.collapsed = !next.collapsed;
      return next;
    });
  }

  /** 该批的「已终态文件数 / 已收字节」——从 payloads 现场派生（计数器漂移会显示成 0/N，2026-11-11 实测） */
  historyOf(transferId: number): PayloadTransfer | undefined {
    for (const h of this.history) {
      if (h.transferId === transferId) {
        return h;
      }
    }
    return undefined;
  }

  /** 紧凑时间（HH:MM）——历史聚合行显示「最近 …」用 */
  compactTimeTextOf(p: PayloadTransfer): string {
    return pureCompactTimeText(p.timeMs);
  }

  payloadOf(transferId: number): PayloadTransfer | undefined {
    for (const p of this.payloads) {
      if (p.transferId === transferId) {
        return p;
      }
    }
    return undefined;
  }

  batchCounts(b: PayloadBatch): BatchCounts {
    return batchCountsOf(b, (tid: number): PayloadTransfer | undefined => this.payloadOf(tid));
  }

  /** 批头文案："3/5 文件 · 45% 占总字节"（分母未知时用已见文件数） */
  batchSummary(b: PayloadBatch): string {
    // 分母取「声明数」与「实见数」的较大者：对端可能把批量拆成多条单文件 share（每条声明 1），
    // 这时按实见数显示，避免出现 "2/1 文件" 这种自相矛盾的数字
    const seen: number = b.transferIds.length;
    const total: number = Math.max(b.expectedFiles, seen);
    const counts: BatchCounts = this.batchCounts(b);
    const unit: string = this.resText($r('app.string.files_batch_unit').id);
    let text: string = `${counts.done}/${total} ${unit}`;
    if (b.totalBytes > 0) {
      const pct: number = Math.min(100, Math.floor(counts.bytes * 100 / b.totalBytes));
      text = `${text} · ${pct}% ${this.resText($r('app.string.files_batch_of_total').id)}`;
    }
    return text;
  }

  /** 批状态后缀：未完成 / 空串 */
  batchStateText(b: PayloadBatch): string {
    return b.state === 'incomplete' ? this.resText($r('app.string.files_batch_incomplete').id) : '';
  }

  // ========== payload 事件处理（原 L1770–L1824）==========

  handlePayloadTransfer(event: NetEvent): void {
    const tid: number = event.payloadTransferId ?? 0;
    const size: number = event.payloadSize ?? 0;
    // B3：已丢弃的传输一律忽略（native 在 discardPayload 后仍会派发终态事件）
    if (tid > 0 && this.discardedIds.includes(tid)) {
      return;
    }
    if (tid <= 0) {
      if (size > 0) {
        this.log(`payload declared but not started: size=${size} dev=${(event.deviceId ?? '').substring(0, 8)} (no entry created)`);
      }
      return;
    }
    const state: PayloadState = this.toState(event.payloadState ?? 'failed');
    const idx: number = this.payloads.findIndex((p: PayloadTransfer) => p.transferId === tid);
    const prev: PayloadTransfer | undefined = idx >= 0 ? this.payloads[idx] : undefined;
    // 【MSG217 现象 A 的根因防御】native 的 payloadTransferId 在应用重启后会从头计数，而本进程
    // `payloads` 里可能残留同 tid 的旧条目（旧实现还会把 history 播种进来）。
    // 「started」语义上必然是**新传输** ⇒ 一律清空处置标记，绝不继承旧条目/历史的 settled/sandboxOnly。
    const isNewTransfer: boolean = prev === undefined || state === 'started';
    // B3：沿用旧条目名做兜底（仅非新传输；新传输用事件名，避免拿到撞号旧名）
    let resolvedName: string = event.payloadFileName ?? '';
    if (resolvedName.length === 0 && !isNewTransfer && prev !== undefined) {
      resolvedName = prev.fileName;
    }
    const init: PayloadTransferInit = {
      transferId: tid,
      deviceId: event.deviceId ?? (prev !== undefined && !isNewTransfer ? prev.deviceId : ''),
      direction: this.toDirection(event.payloadDirection
        ?? (prev !== undefined && !isNewTransfer ? prev.direction : 'receive')),
      state: state,
      fileName: resolvedName,
      size: event.payloadSize ?? (prev !== undefined && !isNewTransfer ? prev.size : 0),
      bytesDone: event.payloadBytesDone ?? 0,
      // 事件给的路径可能是**空串**（native opt('')→undefined 之前的历史行为差异）⇒ 只有非空才采信
      filePath: (event.payloadFilePath !== undefined && event.payloadFilePath.length > 0)
        ? event.payloadFilePath
        : (prev !== undefined && !isNewTransfer ? prev.filePath : ''),
      settled: isNewTransfer ? false : (prev !== undefined ? prev.settled : false),
      // 非新传输沿用处置标记（迟到的终态事件不得把 sandboxOnly/timeMs 抹掉）
      sandboxOnly: isNewTransfer ? false : (prev !== undefined ? prev.sandboxOnly === true : false),
      timeMs: isNewTransfer ? undefined : (prev !== undefined ? prev.timeMs : undefined),
      errorCode: event.errorCode
    };
    // MSG229 §2：非新传输**原地写**同一个实例（数组引用不变）⇒ 行组件 @ObjectLink 自行重渲染，
    // 进度不再被 ForEach 的稳定 key 吞掉；新传输才换实例（uid 变化 ⇒ key 变化 ⇒ 行重建）。
    // P0-A3 排序保护：**终态是稳定的** —— 迟到/重复的非终态事件（progress）或另一个终态事件，
    // 都不得把已决定的终态改回去（native 正常不会乱序，但事件回调是 async 且我们不 await；
    // 参见参考库 docs1111/02 §12-6 R5「onEvent 分支内 await 会重排」）。bytesDone 取最大，避免进度回退。
    if (prev !== undefined && !isNewTransfer) {
      const prevTerminal: boolean = prev.state === 'finished' || prev.state === 'failed' || prev.state === 'cancelled';
      if (prevTerminal && state !== prev.state) {
        this.log(`late event ignored: #${tid} prev=${prev.state} incoming=${state}`);
        init.state = prev.state;
      }
      if (init.bytesDone < prev.bytesDone) {
        init.bytesDone = prev.bytesDone;
      }
    }
    let item: PayloadTransfer;
    if (isNewTransfer || prev === undefined) {
      item = PayloadTransfer.of(init);
      // 同 tid 的旧条目（上一会话残留）被本条顶替，避免 UI 里新旧混在同一条
      this.payloads = [item].concat(this.payloads.filter((p: PayloadTransfer) => p.transferId !== tid));
    } else {
      prev.apply(init);
      item = prev;
    }
    // B1：接收 watchdog —— started/progress 期间挂表，终态摘表
    if (item.direction === 'receive') {
      if (state === 'started' || state === 'progress') {
        this.armReceiveWatchdog(tid);
      } else {
        this.clearReceiveWatchdog(tid);
      }
    }
    if (state === 'finished' || state === 'failed' || state === 'cancelled') {
      this.onSendPayloadSettled(tid, state, event.errorCode !== undefined ? event.errorCode : 0);
      item.timeMs = Date.now();
      this.putReceivedHistory(item);
    }
    // S2：接收方向挂到批次（新建批 / 计数 / 结算），发送方向不参与批次
    if (item.direction === 'receive' && item.deviceId.length > 0) {
      this.attachToReceiveBatch(item, idx < 0, state);
      const b: PayloadBatch | undefined = this.batchOfTransfer(tid);
    }
    // MSG220 §2：**不再**把 filePath 非空作为前置条件 —— 自动保存走 keepPayload(tid, dest)（native 自己搬 spool），
    // 路径为空不代表拿不到文件；旧条件会让整段自动保存被静默跳过（真机 #5/#6 实证）
    if (state === 'finished' && item.direction === 'receive' && !item.settled) {
      if (this.autoSaveEnabled()) {
        this.log(`auto-save received #${tid} ${item.fileName}`);
        this.savePayload(item).then((): void => {
        }).catch((e: Error): void => {
          this.log('auto-save failed: ' + e.message);
        });
      } else {
        // 开关关闭（S2 §3.5）：不动 spool，条目留在「待处置」，用户可保存/丢弃
        this.log(`auto-save off: #${tid} ${item.fileName} pending user action (spool)`);
        this.toast(`${this.resText($r('app.string.files_pending_user').id)}: ${item.fileName}`);
      }
    }
  }

  // ==================== B1 接收 watchdog / 僵尸条目 ====================

  private armReceiveWatchdog(tid: number): void {
    this.clearReceiveWatchdog(tid);
    const t: number = setTimeout((): void => {
      this.recvWatchdogs.delete(tid);
      this.failActiveTransfer(tid, 1, 'no progress/terminal within 30s');
    }, RECV_WATCHDOG_MS);
    this.recvWatchdogs.set(tid, t);
  }

  private clearReceiveWatchdog(tid: number): void {
    const t: number | undefined = this.recvWatchdogs.get(tid);
    if (t !== undefined) {
      clearTimeout(t);
      this.recvWatchdogs.delete(tid);
    }
  }

  /** 把仍处于 started/progress 的条目落 failed（B1 传输级/批级兜底共用） */
  private failActiveTransfer(tid: number, code: number, why: string): void {
    let hit: boolean = false;
    this.payloads = this.payloads.map((p: PayloadTransfer): PayloadTransfer => {
      if (p.transferId !== tid || (p.state !== 'started' && p.state !== 'progress')) {
        return p;
      }
      hit = true;
      const failed: PayloadTransfer = PayloadTransfer.of({
        transferId: p.transferId,
        deviceId: p.deviceId,
        direction: p.direction,
        state: 'failed',
        fileName: p.fileName,
        size: p.size,
        bytesDone: p.bytesDone,
        filePath: p.filePath,
        settled: p.settled,
        sandboxOnly: p.sandboxOnly === true,
        errorCode: code,
        timeMs: Date.now()
      });
      return failed;
    });
    if (hit) {
      this.clearReceiveWatchdog(tid);
      // 计入批计数：让批头显示 "1/1 · 0%" 且该行以「失败」保留（否则批恒 0 产出 → 整条被丢弃）
      const owner: PayloadBatch | undefined = this.batchOfTransfer(tid);
      if (owner !== undefined) {
        this.batches = this.batches.map((b: PayloadBatch): PayloadBatch => {
          if (b.batchId !== owner.batchId) {
            return b;
          }
          const next: PayloadBatch = this.copyBatch(b);
          return next;
        });
      }
      this.log(`payload #${tid} -> failed (${why})`);
    }
  }

  /** B1 批级兜底：批结算时把其中仍活动的 transferIds 一并落 failed，禁止 0/1·0%「接收中」常驻 */
  private failActiveTransfersOfBatch(batchId: number, why: string): void {
    const b: PayloadBatch | undefined = this.batchById(batchId);
    if (b === undefined) {
      return;
    }
    for (const tid of b.transferIds) {
      this.failActiveTransfer(tid, 1, `batch settled (${why})`);
    }
  }

  // ==================== B2 保存：相册 / 应用内 ====================

  private isImageName(name: string): boolean {
    const lower: string = name.toLowerCase();
    const exts: string[] = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.heif', '.avif'];
    for (const e of exts) {
      if (lower.endsWith(e)) {
        return true;
      }
    }
    return false;
  }

  private isVideoName(name: string): boolean {
    const lower: string = name.toLowerCase();
    const exts: string[] = ['.mp4', '.mov', '.mkv', '.webm', '.3gp', '.avi', '.m4v'];
    for (const e of exts) {
      if (lower.endsWith(e)) {
        return true;
      }
    }
    return false;
  }

  /** 免交互写相册（B2：媒体文件唯一可免手势落到用户可见位置的路径） */
  private async saveToAlbum(srcPath: string, name: string): Promise<boolean> {
    const ctx: Context | undefined = this.hostContext();
    if (ctx === undefined || srcPath.length === 0) {
      return false;
    }
    const video: boolean = this.isVideoName(name);
    if (!video && !this.isImageName(name)) {
      return false;
    }
    let srcFd: fileIo.File | undefined = undefined;
    let dstFd: fileIo.File | undefined = undefined;
    try {
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
      const dot: number = name.lastIndexOf('.');
      const ext: string = dot >= 0 ? name.substring(dot + 1) : 'jpg';
      const photoType: photoAccessHelper.PhotoType =
        video ? photoAccessHelper.PhotoType.VIDEO : photoAccessHelper.PhotoType.IMAGE;
      const uri: string = await helper.createAsset(photoType, ext);
      srcFd = fileIo.openSync(srcPath, fileIo.OpenMode.READ_ONLY);
      dstFd = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.copyFileSync(srcFd.fd, dstFd.fd);
      this.log(`saved to album -> ${uri}`);
      return true;
    } catch (e) {
      this.log('album save failed: ' + (e instanceof Error ? e.message : 'unknown'));
      return false;
    } finally {
      if (srcFd !== undefined) {
        try {
          fileIo.closeSync(srcFd);
        } catch (e2) {
        }
      }
      if (dstFd !== undefined) {
        try {
          fileIo.closeSync(dstFd);
        } catch (e3) {
        }
      }
    }
  }

  /** B2：用户手势触发的「导出」（沙箱 → 用户选的位置） */
  async exportPayload(p: PayloadTransfer): Promise<void> {
    const name: string = this.sanitizeFileName(p.fileName, p.transferId);
    const src: string = `${this.hostFilesDir()}/${name}`;
    const exported: string = await this.exportToDownloads(p, name, src);
    if (exported.length > 0) {
      this.markPayloadSettled(p.transferId, false);
      this.toast(`${this.resText($r('app.string.files_saved').id)}: ${name}`);
      return;
    }
    this.toast(this.resText($r('app.string.files_save_failed').id));
  }

  // ========== 文件名清洗（原 L1845–L1847）==========

  sanitizeFileName(raw: string, transferId: number): string {
    return pureSanitizeFileName(raw, transferId);
  }

  // ========== 已接收文件列表（原 L1851–L1864）==========

  receivedFiles(): PayloadTransfer[] {
    const merged: PayloadTransfer[] = [];
    for (const p of this.payloads) {
      if (p.direction === 'receive') {
        merged.push(p);
      }
    }
    for (const h of this.history) {
      if (!merged.some((m: PayloadTransfer) => m.transferId === h.transferId)) {
        merged.push(h);
      }
    }
    return merged.sort((a: PayloadTransfer, b: PayloadTransfer) => b.transferId - a.transferId);
  }

  // ========== 历史持久化（原 L1867–L1893）==========

  putReceivedHistory(item: PayloadTransfer): void {
    const exists: boolean = this.history.some((h: PayloadTransfer) => h.transferId === item.transferId);
    this.history = exists
      ? this.history.map((h: PayloadTransfer) => h.transferId === item.transferId ? item : h)
      : [item].concat(this.history);
    this.persistHistory(this.history);
  }

  clearReceivedHistory(): void {
    this.history = [];
    this.payloads = this.payloads.filter((p: PayloadTransfer) =>
      p.direction !== 'receive' || p.state === 'started' || p.state === 'progress');
    // 清历史时一并清批次（否则批头会引用已被移除的 transferId）
    for (const b of this.batches) {
      this.clearBatchTimer(b.batchId);
    }
    this.batches = [];
    for (const t of this.discardedIds) {
      this.clearReceiveWatchdog(t);
    }
    this.recvWatchdogs.forEach((v: number, k: number): void => {
      clearTimeout(v);
    });
    this.recvWatchdogs.clear();
    this.clearPersistedHistory();
    this.log('received file history cleared');
    this.toast(this.resText($r('app.string.toast_history_cleared').id));
  }

  // ========== 格式化与文案（原 L1895–L1923）==========

  fmtBytes(bytes: number): string {
    if (bytes <= 0) {
      return '0 B';
    }
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  payloadStateText(p: PayloadTransfer): string {
    const send: boolean = p.direction === 'send';
    if (p.state === 'started' || p.state === 'progress') {
      return this.resText(send ? $r('app.string.files_sending').id : $r('app.string.files_receiving').id);
    }
    if (p.state === 'finished') {
      if (send) {
        return this.resText($r('app.string.files_sent').id);
      }
      if (p.expired) {
        // MSG236 ②：启动校正标记过 —— 文件已不在，显示「已结束」而不是「已完成」
        return this.resText($r('app.string.files_ended').id);
      }
      if (!p.settled) {
        return this.resText($r('app.string.files_finished').id);
      }
      // B2：仅落沙箱 → 「已保存到应用内」（不同于真正导出到用户可见位置的「已保存」）
      return this.resText(p.sandboxOnly === true
        ? $r('app.string.files_saved_in_app').id
        : $r('app.string.files_saved').id);
    }
    if (p.state === 'cancelled') {
      // code 6 = 用户主动取消（契约 §5）
      return this.resText($r('app.string.files_cancelled').id);
    }
    if (p.errorCode === 7) {
      // 对端超时未取件（spool 自动回收）
      return this.resText($r('app.string.files_peer_unfetched').id);
    }
    return this.resText($r('app.string.files_failed').id);
  }

  // ========== 标记已处置（原 L1925–L1940）==========

  markPayloadSettled(transferId: number, sandboxOnly: boolean = false): void {
    // B2：保留 timeMs / errorCode（此前重建对象时被丢弃）
    this.payloads = this.payloads.map((p: PayloadTransfer): PayloadTransfer => {
      if (p.transferId !== transferId) {
        return p;
      }
      const next: PayloadTransfer = PayloadTransfer.of({
        transferId: p.transferId,
        deviceId: p.deviceId,
        direction: p.direction,
        state: p.state,
        fileName: p.fileName,
        size: p.size,
        bytesDone: p.bytesDone,
        filePath: p.filePath,
        settled: true,
        sandboxOnly: sandboxOnly,
        timeMs: p.timeMs,
        errorCode: p.errorCode
      });
      return next;
    });
    let touched: boolean = false;
    this.history = this.history.map((h: PayloadTransfer): PayloadTransfer => {
      if (h.transferId !== transferId) {
        return h;
      }
      touched = true;
      const next: PayloadTransfer = PayloadTransfer.of({
        transferId: h.transferId,
        deviceId: h.deviceId,
        direction: h.direction,
        state: h.state,
        fileName: h.fileName,
        size: h.size,
        bytesDone: h.bytesDone,
        filePath: h.filePath,
        settled: true,
        sandboxOnly: sandboxOnly,
        timeMs: h.timeMs,
        errorCode: h.errorCode
      });
      return next;
    });
    if (touched) {
      this.persistHistory(this.history);
    }
  }

  // ========== 详情弹窗辅助（原 L1945–L1976）==========

  timeTextOf(p: PayloadTransfer): string {
    const t: number = p.timeMs ?? 0;
    if (t <= 0) {
      return '—';
    }
    try {
      return new Date(t).toLocaleString();
    } catch (e) {
      return '—';
    }
  }

  /** 申请写权限（媒体自动保存用）：3.5s 超时或任何异常一律视为未授权，**绝不挂住**调用链 */
  private async requestWritePermissionTimeout(name: string): Promise<boolean> {
    let timer: number = -1;
    const timeout: Promise<boolean> = new Promise<boolean>((resolve: (v: boolean) => void): void => {
      timer = setTimeout((): void => {
        console.info(`KDC perm timeout after ${PERM_TIMEOUT_MS}ms name=${name}`);
        resolve(false);
      }, PERM_TIMEOUT_MS);
    });
    try {
      const r: boolean = await Promise.race([this.requestWritePermission(name), timeout]);
      console.info(`KDC perm race settled granted=${r} name=${name}`);
      return r;
    } catch (e) {
      console.info(`KDC perm race error name=${name} ${e instanceof Error ? e.message : 'unknown'}`);
      return false;
    } finally {
      if (timer >= 0) {
        clearTimeout(timer);
      }
    }
  }

  /**
   * MSG229 §3.3 / MSG230：该条目是否还有可处置的文件（spool 或沙箱副本存在）。
   * 用于「无 spool 不显示 保存/另存为/丢弃，文案改『已结束』」，杜绝点了必然失败的按钮。
   */
  canDispose(p: PayloadTransfer): boolean {
    return canDisposeOf(p);
  }

  /** 详情弹窗按钮策略（MSG240 §4.2 + MSG243 四态） */
  detailActionMode(p: PayloadTransfer): DetailActionMode {
    // 判定在 model/PayloadLogic（纯函数）；本类只注入「沙箱副本是否存在」这一 IO 事实
    return detailActionModeOf(p, this.fileExistsFor(p));
  }

  /** MSG243：只读调起系统查看器打开条目文件（沙箱副本优先）。失败/无查看器 ⇒ toast，绝不修改/删除 */
  async openPayload(p: PayloadTransfer): Promise<void> {
    const name: string = this.sanitizeFileName(p.fileName, p.transferId);
    const path: string = `${this.hostFilesDir()}/${name}`;
    let exists: boolean = false;
    try {
      exists = fileIo.accessSync(path);
    } catch (e) {
      exists = false;
    }
    const ctx: Context | undefined = this.hostContext();
    if (!exists || ctx === undefined) {
      this.log(`open skipped: exists=${exists} ctxReady=${ctx !== undefined}`);
      this.toast(this.resText($r('app.string.files_open_failed').id));
      return;
    }
    try {
      const uri: string = fileUri.getUriFromPath(path);
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: uri,
        type: this.mimeOf(name),
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
      };
      await (ctx as common.UIAbilityContext).startAbility(want);
      this.log(`open -> ${uri}`);
    } catch (e) {
      this.log('open failed: ' + (e instanceof Error ? e.message : 'unknown'));
      this.toast(this.resText($r('app.string.files_open_failed').id));
    }
  }

  /** 简易 MIME 推断（仅用于调起查看器） */
  private mimeOf(name: string): string {
    const lower: string = name.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.bmp')) {
      return 'image/bmp';
    }
    if (lower.endsWith('.heic')) {
      return 'image/heif';
    }
    if (lower.endsWith('.mp4')) {
      return 'video/mp4';
    }
    if (lower.endsWith('.mkv')) {
      return 'video/x-matroska';
    }
    if (lower.endsWith('.webm')) {
      return 'video/webm';
    }
    if (lower.endsWith('.mp3')) {
      return 'audio/mpeg';
    }
    if (lower.endsWith('.wav')) {
      return 'audio/x-wav';
    }
    if (lower.endsWith('.flac')) {
      return 'audio/flac';
    }
    if (lower.endsWith('.pdf')) {
      return 'application/pdf';
    }
    if (lower.endsWith('.txt')) {
      return 'text/plain';
    }
    return 'application/octet-stream';
  }

  /** spool 或沙箱副本是否存在（canDispose / 启动校正共用） */
  private fileExistsFor(p: PayloadTransfer): boolean {
    const name: string = this.sanitizeFileName(p.fileName, p.transferId);
    const candidates: string[] = [`${this.hostFilesDir()}/${name}`];
    if (p.filePath.length > 0) {
      candidates.push(p.filePath);
    }
    for (const path of candidates) {
      try {
        if (fileIo.accessSync(path)) {
          return true;
        }
      } catch (e) {
      }
    }
    return false;
  }

  /**
   * MSG236 ②：启动加载历史后做**一次性迁移** —— 把「已收完但未处置」而 spool/沙箱副本都已不存在的条目
   * 标记 `expired=true`（UI 显示「已结束（文件已不在）」且不给保存/丢弃/另存为）。
   * 返回是否发生变化；变化由调用方 `persistHistory` 写回（升级后旧缓存自动被修正）。
   */
  refreshHistoryExpiry(): boolean {
    // MSG241 修正：接线前的 `hostFilesDir` 是默认 ''（可用性由页面注入）⇒ 任何 accessSync 都是假阴性。
    // 必须先在页面装配完成后调用；未就绪时**宁可不标记**（不写回），避免把可保存的条目误判成「已结束」。
    if (this.hostFilesDir().length === 0) {
      console.info('KDC history expiry skipped: hostFilesDir not ready');
      return false;
    }
    let changed: boolean = false;
    for (const h of this.history) {
      // 单条判定在 model/PayloadLogic.expiryActionFor（mark/clear/none）；本类只注入「文件是否存在」
      const act: string = expiryActionFor(h, this.fileExistsFor(h));
      if (act === 'mark') {
        h.expired = true;
        changed = true;
      } else if (act === 'clear') {
        // 自愈：此前被误标（接线前 hostFilesDir='' 的假阴性）而文件实际还在 ⇒ 撤销标记
        h.expired = false;
        changed = true;
      }
    }
    return changed;
  }

  payloadDetail(): PayloadTransfer {
    // MSG230：历史条目只存在于 history（此前只查 payloads ⇒ 详情显示 #tid/大小 0、另存为拿空文件名必失败）
    for (const p of this.payloads) {
      if (p.transferId === this.detailId) {
        return p;
      }
    }
    for (const h of this.history) {
      if (h.transferId === this.detailId) {
        return h;
      }
    }
    const placeholder: PayloadTransfer = PayloadTransfer.of({
      transferId: this.detailId,
      deviceId: '',
      direction: 'receive',
      state: 'failed',
      fileName: '',
      size: 0,
      bytesDone: 0,
      filePath: '',
      settled: true
    });
    return placeholder;
  }

  // ========== 另存为（原 L1998–L2050）==========

  async saveAsPayload(p: PayloadTransfer): Promise<void> {
    if (p.fileName.length === 0) {
      this.log(`save as aborted: empty file name (#${p.transferId})`);
      this.toast(this.resText($r('app.string.files_source_gone').id));
      return;
    }
    const name: string = this.sanitizeFileName(p.fileName, p.transferId);
    let destUri: string = '';
    try {
      destUri = await this.pickSaveTarget(name);
    } catch (e) {
      this.log('save as: picker failed: ' + (e instanceof Error ? e.message : 'unknown'));
      return;
    }
    if (destUri.length === 0) {
      return;
    }
    const sandboxCopy: string = `${this.hostFilesDir()}/${name}`;
    let src: string = sandboxCopy;
    if (p.filePath.length > 0 && !fileIo.accessSync(sandboxCopy)) {
      src = p.filePath;
    }
    try {
      if (!fileIo.accessSync(src)) {
        this.log(`save as aborted: source missing -> ${src}`);
        this.toast(this.resText($r('app.string.files_source_gone').id));
        return;
      }
    } catch (e) {
    }
    let srcFd: fileIo.File | undefined = undefined;
    let dstFd: fileIo.File | undefined = undefined;
    try {
      srcFd = fileIo.openSync(src, fileIo.OpenMode.READ_ONLY);
      dstFd = fileIo.openSync(destUri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.copyFileSync(srcFd.fd, dstFd.fd);
      this.log(`save as -> ${destUri}`);
      // F1（MSG216）：手动「另存为」成功后必须标记 settled，否则条目一直留在「待处置」且行显示「已完成」
      this.markPayloadSettled(p.transferId, false);
      this.toast(`${this.resText($r('app.string.files_saved').id)}: ${name}`);
      this.detailOpen = false;
    } catch (e) {
      this.log('save as: copy failed: ' + (e instanceof Error ? e.message : 'unknown'));
      this.toast(this.resText($r('app.string.files_save_failed').id));
    } finally {
      if (srcFd !== undefined) {
        try {
          fileIo.closeSync(srcFd);
        } catch (e2) {
        }
      }
      if (dstFd !== undefined) {
        try {
          fileIo.closeSync(dstFd);
        } catch (e3) {
        }
      }
    }
  }

  // ========== 保存到沙箱 + 导出（原 L2052–L2090）==========

  async savePayload(p: PayloadTransfer): Promise<void> {
    // P0-A3 竞态保护①（入口）：已被「丢弃」的条目不再保存（避免丢弃后又落盘/又 settle）
    if (this.discardedIds.includes(p.transferId)) {
      this.log(`save aborted: #${p.transferId} already discarded`);
      return;
    }
    const dir: string = this.hostFilesDir();
    if (dir === '') {
      this.log('save failed: no host context');
      this.toast(this.resText($r('app.string.files_save_failed').id));
      return;
    }
    const name: string = this.sanitizeFileName(p.fileName, p.transferId);
    const dest: string = `${dir}/${name}`;
    // MSG223 A：**不弹窗、不阻塞** —— 只查授权状态（自动流程里弹窗会把整条保存链挂住）
    const permName: string = this.writePermissionFor(name);
    let granted: boolean = permName.length === 0 || this.checkWritePermission(name);
    const isMedia: boolean = this.isImageName(name) || this.isVideoName(name);
    // MSG229 §1：媒体未授权时**主动申请一次**（弹窗）——用户允许后即可入相册；
    // 本次会话只弹一次（mediaPermAsked），避免每次收图都打断；拒绝则降级「应用内」+ toast。
    if (isMedia && !granted && !this.mediaPermAsked) {
      this.mediaPermAsked = true;
      // MSG234 §4.1：申请**必须带超时**——弹窗被忽略/系统不弹时旧实现会永久 await，整条保存链挂住
      granted = await this.requestWritePermissionTimeout(name);
      this.log(`media permission requested once: granted=${granted}`);
    }
    let sandboxOk: boolean = false;
    try {
      sandboxOk = native.keepPayload(p.transferId, dest);
      this.log(sandboxOk ? `saved(sandbox) -> ${dest}` : 'keepPayload failed');
    } catch (e) {
      this.log('keepPayload error: ' + (e instanceof Error ? e.message : 'unknown'));
    }
    if (!sandboxOk) {
      this.toast(this.resText($r('app.string.files_save_failed').id));
      return;
    }
    // P0-A3 竞态保护②（await 之后）：权限弹窗/keepPayload 期间用户点了「丢弃」⇒ 丢弃语义优先：
    // 删掉刚落下的沙箱副本、不改状态、不 toast「已保存」。
    if (this.discardedIds.includes(p.transferId)) {
      this.log(`save aborted: #${p.transferId} discarded during save -> cleanup ${dest}`);
      try {
        fileIo.unlinkSync(dest);
      } catch (e) {
        this.log('cleanup after discard failed: ' + (e instanceof Error ? e.message : 'unknown'));
      }
      return;
    }
    // ① 图片/视频：免交互入相册（用户可见）——成功才是真「已保存」；**需已授权**
    //（未授权时上面已按 MSG229 主动申请过一次；仍拒绝则走 ② 降级「应用内」）
    if ((this.isImageName(name) || this.isVideoName(name)) && granted) {
      const inAlbum: boolean = await this.saveToAlbum(dest, name);
      if (inAlbum) {
        this.markPayloadSettled(p.transferId, false);
        this.toast(`${this.resText($r('app.string.files_saved').id)}: ${name}`);
        return;
      }
      this.log('album path unavailable -> fall back to in-app');
    } else if (
      (this.isImageName(name) || this.isVideoName(name)) && !granted) {
      // 未授权：不弹窗打断自动流程；落应用内并提示（用户可在需要时手动授权后再导出）
      this.log(`album skipped: ${permName} not granted -> in-app`);
      this.toast(this.resText($r('app.string.files_album_need_permission').id));
    }
    // ② 其它文件：只落应用沙箱（普通应用无免交互公共目录 API）⇒ 【不得谎报「已保存」】
    //    文案「已保存到应用内」+ 行内「导出」入口（用户手势走 picker）
    this.markPayloadSettled(p.transferId, true);
    this.toast(`${this.resText($r('app.string.files_saved_in_app').id)}: ${name}`);
  }

  // ========== 导出到公共下载目录（原 L2094–L2155）==========

  async exportToDownloads(p: PayloadTransfer, name: string, srcPath: string): Promise<string> {
    let src: string = srcPath;
    if (src.length === 0) {
      src = p.filePath;
    }
    if (src.length === 0) {
      return '';
    }
    if (!fileIo.accessSync(src)) {
      this.log(`export skipped: source missing (already discarded?) -> ${src}`);
      return '';
    }
    let destUri: string = '';
    try {
      destUri = await this.pickDownloadTarget(name);
    } catch (e) {
      this.log('export: save picker(DOWNLOAD) failed: ' + (e instanceof Error ? e.message : 'unknown'));
      return '';
    }
    if (destUri.length === 0) {
      return '';
    }
    let srcFd: fileIo.File | undefined = undefined;
    let dstFd: fileIo.File | undefined = undefined;
    try {
      srcFd = fileIo.openSync(src, fileIo.OpenMode.READ_ONLY);
      dstFd = fileIo.openSync(destUri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.copyFileSync(srcFd.fd, dstFd.fd);
      fileIo.closeSync(srcFd);
      srcFd = undefined;
      fileIo.closeSync(dstFd);
      dstFd = undefined;
      this.markPayloadSettled(p.transferId);
      return destUri;
    } catch (e) {
      this.log('export: copy failed: ' + (e instanceof Error ? e.message : 'unknown'));
      return '';
    } finally {
      if (srcFd !== undefined) {
        try {
          fileIo.closeSync(srcFd);
        } catch (e3) {
        }
      }
      if (dstFd !== undefined) {
        try {
          fileIo.closeSync(dstFd);
        } catch (e4) {
        }
      }
    }
  }

  // ========== 权限映射（原 L2158–L2199）==========

  writePermissionFor(fileName: string): string {
    const lower: string = fileName.toLowerCase();
    const imageVideo: string[] = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.mp4', '.mov', '.mkv', '.webm', '.3gp'];
    const audio: string[] = ['.mp3', '.wav', '.flac', '.aac', '.m4a', '.ogg', '.opus', '.amr'];
    for (const ext of imageVideo) {
      if (lower.endsWith(ext)) {
        return 'ohos.permission.WRITE_IMAGEVIDEO';
      }
    }
    for (const ext of audio) {
      if (lower.endsWith(ext)) {
        return 'ohos.permission.WRITE_AUDIO';
      }
    }
    return '';
  }

  // ========== 丢弃 / 取消（原 L2201–L2239）==========

  discardPayload(p: PayloadTransfer): void {
    // MSG232 §2.2：旧行（已被移除/已被丢弃）的残留命中 ⇒ 明确 no-op 反馈，避免「点了没反应」
    const gone: boolean = p.fileName.length === 0
      || (this.payloadOf(p.transferId) === undefined && this.historyOf(p.transferId) === undefined);
    if (gone) {
      console.info(`KDC discard skipped #${p.transferId} (stale row, no longer in lists)`);
      this.toast(this.resText($r('app.string.files_source_gone').id));
      return;
    }
    console.info(`KDC discard start #${p.transferId} name=${p.fileName} before=${this.payloads.length}/${this.history.length}`);
    // B3：先记入 discardedIds —— 之后 native 派发的迟到终态事件会被 handlePayloadTransfer 幂等忽略
    if (!this.discardedIds.includes(p.transferId)) {
      this.discardedIds.push(p.transferId);
      if (this.discardedIds.length > DISCARD_KEEP) {
        this.discardedIds = this.discardedIds.slice(this.discardedIds.length - DISCARD_KEEP);
      }
    }
    this.clearReceiveWatchdog(p.transferId);
    // 2026-11-09 用户实测：对「已 keep / 已终态」的条目 native.discardPayload() 返回 false（spool 已不在 native），
    // 旧实现把这当成失败并打 'discardPayload failed' —— 那是**无可丢弃**，不是错误。这里分开表达。
    try {
      const ok: boolean = native.discardPayload(p.transferId);
      this.log(ok ? `discarded #${p.transferId}`
        : `discard: native had nothing to drop (#${p.transferId}, already kept/terminal)`);
    } catch (e) {
      this.log('discardPayload error: ' + (e instanceof Error ? e.message : 'unknown'));
    }
    const name: string = this.sanitizeFileName(p.fileName, p.transferId);
    const sandboxCopy: string = `${this.hostFilesDir()}/${name}`;
    // 删本地副本：沙箱副本 + （未 keep 时）native spool 路径，两处都试，避免残留占盘
    const candidates: string[] = [sandboxCopy];
    if (p.filePath.length > 0) {
      candidates.push(p.filePath);
    }
    for (const path of candidates) {
      try {
        if (fileIo.accessSync(path)) {
          fileIo.unlinkSync(path);
          this.log(`unlink -> ${path}`);
        }
      } catch (e2) {
        this.log('unlink failed: ' + (e2 instanceof Error ? e2.message : 'unknown'));
      }
    }
    this.payloads = this.payloads.filter((x: PayloadTransfer) => x.transferId !== p.transferId);
    this.history = this.history.filter((h: PayloadTransfer) => h.transferId !== p.transferId);
    console.info(`KDC discard done #${p.transferId} after=${this.payloads.length}/${this.history.length}`);
    this.persistHistory(this.history);
  }

  cancelPayload(p: PayloadTransfer): void {
    if (this.discardedIds.includes(p.transferId)) {
      this.log(`cancel skipped: #${p.transferId} already discarded`);
      return;
    }
    try {
      native.cancelPayload(p.transferId);
      this.log(`payload cancel requested #${p.transferId}`);
    } catch (e) {
      this.log('cancelPayload error: ' + (e instanceof Error ? e.message : 'unknown'));
    }
  }

  // ========== 发送队列（原 L2350–L2428）==========

  enqueueSendJobs(jobs: SendJob[], targetId: string): void {
    this.sendTarget = targetId;
    this.sendTotal += jobs.length;
    for (const j of jobs) {
      this.sendQueue.push(j);
    }
    this.log(`send file batch queued: ${jobs.length} (queue=${this.sendQueue.length})`);
    this.pumpSendQueue();
  }

  pumpSendQueue(): void {
    if (this.sendBusyId >= 0 || this.sendQueue.length === 0) {
      return;
    }
    if (!this.connectedDeviceIds().some((id: string) => id === this.sendTarget)) {
      this.forgetSendQueue(this.sendTarget);
      return;
    }
    const job: SendJob = this.sendQueue[0];
    try {
      const body: SendShareBody = { filename: job.fileName };
      const tid: number = native.sendPayload(this.sendTarget, 'kdeconnect.share.request',
        JSON.stringify(body), job.cachePath);
      if (tid > 0) {
        this.sendBusyId = tid;
        this.sendInflightJob = job;
        this.log(`send file #${tid}: ${job.fileName} (queued=${this.sendQueue.length})`);
        return;
      }
      this.log(`send file: sendPayload returned 0 (${job.fileName})`);
    } catch (e) {
      this.log(`sendPayload error (${job.fileName}): ` + (e instanceof Error ? e.message : 'unknown'));
    }
    this.sendQueue.shift();
    this.pumpSendQueue();
  }

  forgetSendQueue(deviceId: string): void {
    if (deviceId.length === 0 || this.sendTarget !== deviceId) {
      return;
    }
    const dropped: number = this.sendQueue.length + (this.sendBusyId >= 0 ? 1 : 0);
    this.sendQueue = [];
    this.sendBusyId = -1;
    this.sendInflightJob = undefined;
    this.sendTarget = '';
    this.sendOkCount = 0;
    this.sendTotal = 0;
    this.log(`send queue cleared on disconnect (dropped=${dropped})`);
  }

  onSendPayloadSettled(transferId: number, state: PayloadState, code: number): void {
    if (transferId !== this.sendBusyId) {
      return;
    }
    const job: SendJob | undefined = this.sendInflightJob;
    this.sendBusyId = -1;
    this.sendInflightJob = undefined;
    if (this.sendQueue.length > 0) {
      this.sendQueue.shift();
    }
    if (state === 'finished') {
      this.sendOkCount++;
      this.log(`send file done: ${job !== undefined ? job.fileName : '?'} (${this.sendOkCount}/${this.sendTotal})`);
    } else {
      this.log(`send file failed: ${job !== undefined ? job.fileName : '?'} state=${state} code=${code}`);
    }
    this.pumpSendQueue();
    if (this.sendBusyId < 0 && this.sendQueue.length === 0 && this.sendTotal > 0) {
      const head: string = this.resText($r('app.string.toast_send_batch_done').id);
      this.toast(`${head} (${this.sendOkCount}/${this.sendTotal})`);
      this.log(`send file batch done: ${this.sendOkCount}/${this.sendTotal}`);
      this.sendOkCount = 0;
      this.sendTotal = 0;
    }
  }
}

// 发送文件时的 share.request body
interface SendShareBody {
  filename: string;
}
