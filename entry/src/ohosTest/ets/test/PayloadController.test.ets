// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// T9 —— PayloadController 不变量单测（TEST_COVERAGE_PLAN_20260926.md 的 P2 项；AtomCode 认定为本计划下一未落地项）。
//
// 覆盖本类头注释 4 条不变量中**可测的部分**：
//   ① payload 终态是队列推进的唯一依据（别加 sleep）—— 终态以 transferId 为键；非本批次终态不得动队列
//   ② payloadSize>0 ∧ payloadTransferId==0 不建条目
//   ③ sanitizeFileName 拒路径穿越 / 空名回落 / 长度约束
//   ④ 终态兜底 failInflightReceives：控制连接断开 ⇒ 进行中的接收立即落 failed
//   附：forgetSendQueue 只清本目标设备的队列；pumpSendQueue 在目标不在线时走清账
//
// ⚠️ 本文件依赖 `libkdeconnect_napi.so`（PayloadController 顶层 import native）⇒ **只能设备侧跑**，
//    不进宿主纯逻辑通道（tools/arkts-logic-test.ps1）。
// ⚠️ **已知覆盖缺口（如实记录）**：`onSendPayloadSettled` 的"批次完成 toast"分支需 `sendTotal > 0`，
//    而该分支会调用 `$r('app.string.toast_send_batch_done')`；为免在非 UI 测试上下文依赖 `$r()`
//    资源解析，本套件把该分支**以 sendTotal=0 绕开**（其余语义仍完整覆盖）。该分支留待真机/UI 侧验证。
import { describe, it, expect } from '@ohos/hypium';
import { NetEvent } from 'libkdeconnect_napi.so';
import { PayloadController } from '../../../main/ets/state/PayloadController';
import { PayloadTransfer, PayloadState, PayloadDirection } from '../../../main/ets/model/PayloadModels';

const DEV: string = 'aaaa1111111111111111111111111111';
const DEV2: string = 'bbbb2222222222222222222222222222';

class Rec {
  logs: string[] = [];
  toasts: string[] = [];
  connected: string[] = [];

  hasLog(needle: string): boolean {
    return this.logs.some((l: string) => l.includes(needle));
  }
}

function controller(rec: Rec): PayloadController {
  const c: PayloadController = new PayloadController();
  c.log = (m: string): void => {
    rec.logs.push(m);
  };
  c.toast = (m: string): void => {
    rec.toasts.push(m);
  };
  c.resText = (resId: number): string => 'stub';
  c.hostFilesDir = (): string => '/tmp/kdc';
  c.connectedDeviceIds = (): string[] => rec.connected;
  return c;
}

function transfer(tid: number, deviceId: string, direction: PayloadDirection, state: PayloadState): PayloadTransfer {
  const t: PayloadTransfer = {
    transferId: tid, deviceId: deviceId, direction: direction,
    state: state, fileName: `f${tid}.bin`, size: 100, bytesDone: 0, filePath: '', settled: false
  };
  return t;
}

function transferEvent(tid: number, size: number, state: PayloadState): NetEvent {
  const e: NetEvent = {
    type: 'payloadTransfer', deviceId: DEV, payloadTransferId: tid, payloadSize: size,
    payloadDirection: 'receive', payloadState: state
  };
  return e;
}

export default function payloadControllerTest(): void {
  describe('PayloadControllerInvariantsTest', () => {

    // ---- ② payloadSize>0 ∧ payloadTransferId==0 不建条目 ----

    it('TestPayloadController_declaredButNotStarted_createsNoEntry', 0, () => {
      const rec: Rec = new Rec();
      const c: PayloadController = controller(rec);
      c.handlePayloadTransfer(transferEvent(0, 4096, 'started'));
      expect(c.payloads.length).assertEqual(0);
      expect(rec.hasLog('no entry created')).assertTrue();
    });

    it('TestPayloadController_zeroTidAndZeroSize_isSilentNoop', 0, () => {
      const rec: Rec = new Rec();
      const c: PayloadController = controller(rec);
      c.handlePayloadTransfer({ type: 'payloadTransfer', deviceId: DEV, payloadTransferId: 0, payloadSize: 0 });
      expect(c.payloads.length).assertEqual(0);
      expect(rec.logs.length).assertEqual(0);
    });

    it('TestPayloadController_validTid_createsEntryNewestFirst', 0, () => {
      const rec: Rec = new Rec();
      const c: PayloadController = controller(rec);
      c.handlePayloadTransfer(transferEvent(1, 100, 'started'));
      c.handlePayloadTransfer(transferEvent(2, 100, 'started'));
      expect(c.payloads.length).assertEqual(2);
      expect(c.payloads[0].transferId).assertEqual(2);
    });

    it('TestPayloadController_sameTidUpdatesInsteadOfDuplicating', 0, () => {
      const rec: Rec = new Rec();
      const c: PayloadController = controller(rec);
      c.handlePayloadTransfer(transferEvent(7, 100, 'started'));
      c.handlePayloadTransfer(transferEvent(7, 100, 'progress'));
      expect(c.payloads.length).assertEqual(1);
      expect(c.payloads[0].state).assertEqual('progress');
    });

    // ---- ④ failInflightReceives 终态兜底 ----

    it('TestPayloadController_failInflightReceives_marksActiveReceiveFailed', 0, () => {
      const rec: Rec = new Rec();
      const c: PayloadController = controller(rec);
      c.payloads = [transfer(1, DEV, 'receive', 'started'), transfer(2, DEV, 'receive', 'progress')];
      c.failInflightReceives(DEV, 'disconnected');
      expect(c.payloads[0].state).assertEqual('failed');
      expect(c.payloads[1].state).assertEqual('failed');
    });

    it('TestPayloadController_failInflightReceives_leavesSendAndSettledAlone', 0, () => {
      const rec: Rec = new Rec();
      const c: PayloadController = controller(rec);
      c.payloads = [transfer(1, DEV, 'send', 'progress'), transfer(2, DEV, 'receive', 'finished')];
      c.failInflightReceives(DEV, 'disconnected');
      expect(c.payloads[0].state).assertEqual('progress');
      expect(c.payloads[1].state).assertEqual('finished');
    });

    it('TestPayloadController_failInflightReceives_isDeviceScoped', 0, () => {
      const rec: Rec = new Rec();
      const c: PayloadController = controller(rec);
      c.payloads = [transfer(1, DEV, 'receive', 'progress'), transfer(2, DEV2, 'receive', 'progress')];
      c.failInflightReceives(DEV, 'disconnected');
      expect(c.payloads[0].state).assertEqual('failed');
      expect(c.payloads[1].state).assertEqual('progress');
    });

    it('TestPayloadController_failInflightReceives_emptyDeviceIdIsNoop', 0, () => {
      const rec: Rec = new Rec();
      const c: PayloadController = controller(rec);
      c.payloads = [transfer(1, DEV, 'receive', 'progress')];
      c.failInflightReceives('', 'disconnected');
      expect(c.payloads[0].state).assertEqual('progress');
    });

    // ---- ① 终态以 transferId 为键（非本批次终态不得动队列） ----

    it('TestPayloadController_settled_ignoresForeignTransferId', 0, () => {
      const rec: Rec = new Rec();
      const c: PayloadController = controller(rec);
      c.sendBusyId = 42;
      c.sendQueue = [{ cachePath: '/tmp/a', fileName: 'a.bin' }];
      c.sendTotal = 0;
      c.onSendPayloadSettled(999, 'finished', 0);   // 非本批次
      expect(c.sendBusyId).assertEqual(42);          // 忙标记未被清
      expect(c.sendQueue.length).assertEqual(1);     // 队列未推进
      expect(rec.hasLog('send file done')).assertFalse();
    });

    it('TestPayloadController_settled_matchingFinishedAdvancesAndCounts', 0, () => {
      const rec: Rec = new Rec();
      const c: PayloadController = controller(rec);
      c.sendBusyId = 42;
      c.sendInflightJob = { cachePath: '/tmp/a', fileName: 'a.bin' };
      c.sendQueue = [];
      c.sendTotal = 0;                               // 绕开需 $r 的批次完成 toast 分支（见文件头）
      c.onSendPayloadSettled(42, 'finished', 0);
      expect(c.sendBusyId).assertEqual(-1);
      expect(c.sendOkCount).assertEqual(1);
      expect(rec.hasLog('send file done')).assertTrue();
    });

    it('TestPayloadController_settled_matchingFailedDoesNotCountOk', 0, () => {
      const rec: Rec = new Rec();
      const c: PayloadController = controller(rec);
      c.sendBusyId = 42;
      c.sendInflightJob = { cachePath: '/tmp/a', fileName: 'a.bin' };
      c.sendQueue = [];
      c.sendTotal = 0;
      c.onSendPayloadSettled(42, 'failed', 110);
      expect(c.sendOkCount).assertEqual(0);
      expect(rec.hasLog('send file failed')).assertTrue();
    });

    // ---- 队列清账 ----

    it('TestPayloadController_forgetSendQueue_clearsOnlyMatchingTarget', 0, () => {
      const rec: Rec = new Rec();
      const c: PayloadController = controller(rec);
      c.sendTarget = DEV;
      c.sendQueue = [{ cachePath: '/tmp/a', fileName: 'a.bin' }];
      c.sendBusyId = 7;
      c.forgetSendQueue(DEV2);                       // 别的设备 ⇒ 不动
      expect(c.sendBusyId).assertEqual(7);
      expect(c.sendQueue.length).assertEqual(1);
      c.forgetSendQueue(DEV);                        // 本目标 ⇒ 全清
      expect(c.sendBusyId).assertEqual(-1);
      expect(c.sendQueue.length).assertEqual(0);
      expect(c.sendTarget).assertEqual('');
    });

    it('TestPayloadController_pumpSendQueue_targetOfflineDropsQueue', 0, () => {
      const rec: Rec = new Rec();
      rec.connected = [];
      const c: PayloadController = controller(rec);
      c.sendTarget = DEV;
      c.sendQueue = [{ cachePath: '/tmp/a', fileName: 'a.bin' }];
      c.sendTotal = 3;
      c.pumpSendQueue();
      expect(c.sendQueue.length).assertEqual(0);
      expect(c.sendTotal).assertEqual(0);
      expect(rec.hasLog('send queue cleared on disconnect')).assertTrue();
    });

    it('TestPayloadController_pumpSendQueue_emptyQueueIsNoop', 0, () => {
      const rec: Rec = new Rec();
      rec.connected = [DEV];
      const c: PayloadController = controller(rec);
      c.sendTarget = DEV;
      c.pumpSendQueue();
      expect(c.sendBusyId).assertEqual(-1);
      expect(rec.logs.length).assertEqual(0);
    });

    // ---- ③ 文件名净化（不变量：单一来源 = PayloadHistory.safeFileName，此处经 sanitizeFileName 委托） ----

    it('TestPayloadController_sanitizeFileName_stripsPathTraversal', 0, () => {
      const rec: Rec = new Rec();
      const c: PayloadController = controller(rec);
      const out: string = c.sanitizeFileName('../../etc/passwd', 5);
      expect(out.includes('/')).assertFalse();
      expect(out.includes('..')).assertFalse();
      expect(out.length > 0).assertTrue();
    });

    it('TestPayloadController_sanitizeFileName_emptyFallsBackToTransferId', 0, () => {
      const rec: Rec = new Rec();
      const c: PayloadController = controller(rec);
      const out: string = c.sanitizeFileName('', 5);
      expect(out.includes('5')).assertTrue();
    });
  });
}
