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
import { PayloadTransfer, PayloadDirection, PayloadState } from '../model/PayloadModels';
import { PayloadHistory } from '../common/PayloadHistory';
import { fileIo, picker } from '@kit.CoreFileKit';
import { Context, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';

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
  dialogOpen: boolean = false;               // 原 @State receivedDialogOpen
  detailOpen: boolean = false;               // 原 @State payloadDetailOpen
  detailId: number = 0;                      // 原 @State payloadDetailId

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
      const failed: PayloadTransfer = {
        transferId: p.transferId,
        deviceId: p.deviceId,
        direction: p.direction,
        state: 'failed',
        fileName: p.fileName,
        size: p.size,
        bytesDone: p.bytesDone,
        filePath: p.filePath,
        settled: p.settled
      };
      return failed;
    });
    if (changed) {
      this.payloads = next;
      console.info(`KDC payload inflight -> failed (${reason}) dev=${deviceId.substring(0, 8)}`);
    }
  }

  // ========== payload 事件处理（原 L1770–L1824）==========

  handlePayloadTransfer(event: NetEvent): void {
    const tid: number = event.payloadTransferId ?? 0;
    const size: number = event.payloadSize ?? 0;
    if (tid <= 0) {
      if (size > 0) {
        console.info(`KDC payload declared but not started: size=${size} dev=${(event.deviceId ?? '').substring(0, 8)} (no entry created)`);
      }
      return;
    }
    const state: PayloadState = this.toState(event.payloadState ?? 'failed');
    const idx: number = this.payloads.findIndex((p: PayloadTransfer) => p.transferId === tid);
    const settled: boolean = idx >= 0 ? this.payloads[idx].settled : false;
    const item: PayloadTransfer = {
      transferId: tid,
      deviceId: event.deviceId ?? '',
      direction: this.toDirection(event.payloadDirection ?? 'receive'),
      state: state,
      fileName: event.payloadFileName ?? (idx >= 0 ? this.payloads[idx].fileName : ''),
      size: event.payloadSize ?? (idx >= 0 ? this.payloads[idx].size : 0),
      bytesDone: event.payloadBytesDone ?? 0,
      filePath: event.payloadFilePath ?? (idx >= 0 ? this.payloads[idx].filePath : ''),
      settled: settled
    };
    if (idx >= 0) {
      this.payloads = this.payloads.map((p: PayloadTransfer) => p.transferId === tid ? item : p);
    } else {
      this.payloads = [item].concat(this.payloads);
    }
    if (state !== 'progress') {
      this.log(`payload ${state} ${item.direction} #${tid} ${item.fileName}`);
    }
    if (state === 'finished' || state === 'failed' || state === 'cancelled') {
      this.onSendPayloadSettled(tid, state, event.errorCode !== undefined ? event.errorCode : 0);
      item.timeMs = Date.now();
      this.putReceivedHistory(item);
    }
    if (state === 'finished' && item.direction === 'receive' && !item.settled && item.filePath.length > 0) {
      this.log(`auto-save received #${tid} ${item.fileName}`);
      this.savePayload(item).then((): void => {
      }).catch((e: Error): void => {
        this.log('auto-save failed: ' + e.message);
      });
    }
  }

  // ========== 文件名清洗（原 L1845–L1847）==========

  sanitizeFileName(raw: string, transferId: number): string {
    return PayloadHistory.safeFileName(raw, transferId);
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
      return this.resText(p.settled ? $r('app.string.files_saved').id : $r('app.string.files_finished').id);
    }
    return this.resText(p.state === 'failed' ? $r('app.string.files_failed').id : $r('app.string.files_cancelled').id);
  }

  // ========== 标记已处置（原 L1925–L1940）==========

  markPayloadSettled(transferId: number): void {
    this.payloads = this.payloads.map((p: PayloadTransfer) => {
      const next: PayloadTransfer = {
        transferId: p.transferId,
        deviceId: p.deviceId,
        direction: p.direction,
        state: p.state,
        fileName: p.fileName,
        size: p.size,
        bytesDone: p.bytesDone,
        filePath: p.filePath,
        settled: true
      };
      return p.transferId === transferId ? next : p;
    });
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

  payloadDetail(): PayloadTransfer {
    for (const p of this.payloads) {
      if (p.transferId === this.detailId) {
        return p;
      }
    }
    const placeholder: PayloadTransfer = {
      transferId: this.detailId,
      deviceId: '',
      direction: 'receive',
      state: 'failed',
      fileName: '',
      size: 0,
      bytesDone: 0,
      filePath: '',
      settled: true
    };
    return placeholder;
  }

  // ========== 另存为（原 L1998–L2050）==========

  async saveAsPayload(p: PayloadTransfer): Promise<void> {
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
    let srcFd: fileIo.File | undefined = undefined;
    let dstFd: fileIo.File | undefined = undefined;
    try {
      srcFd = fileIo.openSync(src, fileIo.OpenMode.READ_ONLY);
      dstFd = fileIo.openSync(destUri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.copyFileSync(srcFd.fd, dstFd.fd);
      this.log(`save as -> ${destUri}`);
      this.toast(`${this.resText($r('app.string.files_auto_saved').id)}: ${name}`);
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
    const dir: string = this.hostFilesDir();
    if (dir === '') {
      this.log('save failed: no host context');
      this.toast(this.resText($r('app.string.files_save_failed').id));
      return;
    }
    const name: string = this.sanitizeFileName(p.fileName, p.transferId);
    const dest: string = `${dir}/${name}`;
    const granted: boolean = await this.requestWritePermission(name);
    if (!granted) {
      this.log(`save aborted: write permission denied for ${name}`);
      this.toast(this.resText($r('app.string.files_need_permission').id));
      return;
    }
    let sandboxOk: boolean = false;
    try {
      sandboxOk = native.keepPayload(p.transferId, dest);
      this.log(sandboxOk ? `saved(sandbox) -> ${dest}` : 'keepPayload failed');
    } catch (e) {
      this.log('keepPayload error: ' + (e instanceof Error ? e.message : 'unknown'));
    }
    const exported: string = await this.exportToDownloads(p, name, dest);
    if (exported.length > 0) {
      this.log(`exported to public dir -> ${exported}`);
      this.markPayloadSettled(p.transferId);
      this.toast(`${this.resText($r('app.string.files_auto_saved').id)}: ${name}`);
      return;
    }
    if (sandboxOk) {
      this.markPayloadSettled(p.transferId);
      this.toast(`${this.resText($r('app.string.files_auto_saved').id)}: ${name}`);
      return;
    }
    this.toast(this.resText($r('app.string.files_save_failed').id));
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
    console.info(`KDC discard start #${p.transferId} name=${p.fileName} before=${this.payloads.length}/${this.history.length}`);
    try {
      const ok: boolean = native.discardPayload(p.transferId);
      this.log(ok ? `discarded #${p.transferId}` : 'discardPayload failed');
    } catch (e) {
      this.log('discardPayload error: ' + (e instanceof Error ? e.message : 'unknown'));
    }
    const name: string = this.sanitizeFileName(p.fileName, p.transferId);
    const sandboxCopy: string = `${this.hostFilesDir()}/${name}`;
    try {
      if (fileIo.accessSync(sandboxCopy)) {
        fileIo.unlinkSync(sandboxCopy);
        this.log(`unlink sandbox copy -> ${sandboxCopy}`);
      }
    } catch (e2) {
      this.log('unlink sandbox copy failed: ' + (e2 instanceof Error ? e2.message : 'unknown'));
    }
    this.payloads = this.payloads.filter((x: PayloadTransfer) => x.transferId !== p.transferId);
    this.history = this.history.filter((h: PayloadTransfer) => h.transferId !== p.transferId);
    console.info(`KDC discard done #${p.transferId} after=${this.payloads.length}/${this.history.length}`);
    this.persistHistory(this.history);
  }

  cancelPayload(p: PayloadTransfer): void {
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
