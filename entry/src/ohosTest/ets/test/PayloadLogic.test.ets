// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// P0-A2 —— `model/PayloadLogic.ets` 纯决策函数回归（**零 Kit 依赖，宿主 bun 与设备 hypium 双跑**）。
//
// 用例来源：近期三次真机回归的判定点 —— MSG240 弹窗四态 / MSG241 expiried 误判 / MSG229 批次计数残留。
// 约定：命名 `Test<对象>_<场景>`；断言只依赖入参（IO 通过注入的布尔/回调模拟）。
import { describe, it, expect } from '@ohos/hypium';
import {
  sanitizeFileName, compactTimeText, detailActionModeOf, canDisposeOf, batchCountsOf, expiryActionFor, BatchCounts
} from '../../../main/ets/model/PayloadLogic';
import { PayloadTransfer, PayloadBatch, PayloadBatchState } from '../../../main/ets/model/PayloadModels';

const DEV: string = 'aaaa1111111111111111111111111111';

function transfer(direction: string, state: string, settled: boolean, expired: boolean, tid: number = 1): PayloadTransfer {
  const t: PayloadTransfer = PayloadTransfer.of({
    transferId: tid,
    deviceId: DEV,
    direction: direction === 'send' ? 'send' : 'receive',
    state: state === 'progress' ? 'progress' : (state === 'started' ? 'started'
      : (state === 'finished' ? 'finished' : (state === 'cancelled' ? 'cancelled' : 'failed'))),
    fileName: 'a.bin',
    size: 100,
    bytesDone: 100,
    filePath: '',
    settled: settled,
    expired: expired
  });
  return t;
}

function batch(ids: number[], expected: number, state: string = 'active'): PayloadBatch {
  const b: PayloadBatch = {
    batchId: 7,
    deviceId: DEV,
    direction: 'receive',
    state: (state === 'done' ? 'done' : (state === 'incomplete' ? 'incomplete' : 'active')) as PayloadBatchState,
    transferIds: ids,
    expectedFiles: expected,
    totalBytes: 0,
    declaredByUpdate: false,
    lastFileAtMs: 0,
    collapsed: false
  };
  return b;
}

export default function payloadLogicTest(): void {
  describe('PayloadLogic', () => {
    // ---------- 详情弹窗四态（MSG240 §4.2 / MSG243） ----------
    it('Test_detailActionMode_pendingSaveDiscard', 0, () => {
      // 待处置：**不看** ArkTS 路径（spool 可能只在 native）⇒ 仍是「保存/丢弃」
      expect(detailActionModeOf(transfer('receive', 'finished', false, false), false)).assertEqual('saveDiscard');
      expect(detailActionModeOf(transfer('receive', 'finished', false, false), true)).assertEqual('saveDiscard');
    });
    it('Test_detailActionMode_settledWithCopyOpenSaveAs', 0, () => {
      expect(detailActionModeOf(transfer('receive', 'finished', true, false), true)).assertEqual('openSaveAs');
    });
    it('Test_detailActionMode_settledNoCopyOnlyClose', 0, () => {
      expect(detailActionModeOf(transfer('receive', 'finished', true, false), false)).assertEqual('none');
    });
    it('Test_detailActionMode_expiredOnlyClose', 0, () => {
      expect(detailActionModeOf(transfer('receive', 'finished', false, true), true)).assertEqual('none');
    });
    it('Test_detailActionMode_sendOnlyClose', 0, () => {
      expect(detailActionModeOf(transfer('send', 'finished', true, false), true)).assertEqual('none');
      expect(detailActionModeOf(transfer('send', 'finished', false, false), true)).assertEqual('none');
    });
    it('Test_detailActionMode_notTerminalOnlyClose', 0, () => {
      expect(detailActionModeOf(transfer('receive', 'progress', false, false), true)).assertEqual('none');
      expect(detailActionModeOf(transfer('receive', 'failed', false, false), true)).assertEqual('none');
    });

    // ---------- 可处置判定 ----------
    it('Test_canDispose_pendingTrueOthersFalse', 0, () => {
      expect(canDisposeOf(transfer('receive', 'finished', false, false))).assertTrue();
      expect(canDisposeOf(transfer('receive', 'finished', true, false))).assertFalse();
      expect(canDisposeOf(transfer('receive', 'finished', false, true))).assertFalse();
      expect(canDisposeOf(transfer('send', 'finished', false, false))).assertFalse();
      expect(canDisposeOf(transfer('receive', 'started', false, false))).assertFalse();
    });

    // ---------- 批次派生计数（MSG229/242：不再依赖状态化计数器） ----------
    it('Test_batchCounts_countsOnlyTerminalMembers', 0, () => {
      const p1: PayloadTransfer = transfer('receive', 'finished', true, false, 1);
      const p2: PayloadTransfer = transfer('receive', 'progress', false, false, 2);
      const c: BatchCounts = batchCountsOf(batch([1, 2], 2), (tid: number): PayloadTransfer | undefined => {
        return tid === 1 ? p1 : (tid === 2 ? p2 : undefined);
      });
      expect(c.done).assertEqual(1);
      expect(c.bytes).assertEqual(100);
    });
    it('Test_batchCounts_failedCountsAsDone', 0, () => {
      const pf: PayloadTransfer = transfer('receive', 'failed', false, false, 3);
      const c: BatchCounts = batchCountsOf(batch([3], 1), (tid: number): PayloadTransfer | undefined => tid === 3 ? pf : undefined);
      expect(c.done).assertEqual(1);
    });
    it('Test_batchCounts_missingMemberSkipped', 0, () => {
      const c: BatchCounts = batchCountsOf(batch([9, 10], 2), (): PayloadTransfer | undefined => undefined);
      expect(c.done).assertEqual(0);
      expect(c.bytes).assertEqual(0);
    });
    it('Test_batchCounts_bytesUseSizeWhenBytesDoneZero', 0, () => {
      const p: PayloadTransfer = PayloadTransfer.of({
        transferId: 4, deviceId: DEV, direction: 'receive', state: 'finished', fileName: 'x.bin',
        size: 4096, bytesDone: 0, filePath: '', settled: true
      });
      const c: BatchCounts = batchCountsOf(batch([4], 1), (tid: number): PayloadTransfer | undefined => tid === 4 ? p : undefined);
      expect(c.bytes).assertEqual(4096);
    });

    // ---------- 启动迁移判定（MSG236/242：误判 + 自愈） ----------
    it('Test_expiryActionFor_pendingNoFileMarks', 0, () => {
      expect(expiryActionFor(transfer('receive', 'finished', false, false), false)).assertEqual('mark');
    });
    it('Test_expiryActionFor_pendingWithFileStays', 0, () => {
      expect(expiryActionFor(transfer('receive', 'finished', false, false), true)).assertEqual('none');
    });
    it('Test_expiryActionFor_expiredWithFileSelfHeals', 0, () => {
      expect(expiryActionFor(transfer('receive', 'finished', false, true), true)).assertEqual('clear');
    });
    it('Test_expiryActionFor_expiredNoFileStays', 0, () => {
      expect(expiryActionFor(transfer('receive', 'finished', false, true), false)).assertEqual('none');
    });
    it('Test_expiryActionFor_settledAndSendUntouched', 0, () => {
      expect(expiryActionFor(transfer('receive', 'finished', true, false), false)).assertEqual('none');
      expect(expiryActionFor(transfer('send', 'finished', false, false), false)).assertEqual('none');
    });

    // ---------- 文件名清洗（安全：禁止路径穿越/隐藏文件） ----------
    it('Test_sanitizeFileName_stripsPathSeparators', 0, () => {
      const out: string = sanitizeFileName('../../etc/passwd', 5);
      expect(out.includes('/')).assertFalse();
      expect(out.includes('\\')).assertFalse();
      expect(out.includes('..')).assertFalse();
      expect(out.startsWith('.')).assertFalse();
      expect(out.length > 0).assertTrue();
      const win: string = sanitizeFileName('a\\b\\c.bin', 5);
      expect(win.includes('\\')).assertFalse();
      expect(win.includes('..')).assertFalse();
    });
    it('Test_sanitizeFileName_stripsControlAndLeadingDots', 0, () => {
      expect(sanitizeFileName('.hidden.bin', 5)).assertEqual('hidden.bin');
      expect(sanitizeFileName('a\u0000b.bin', 5)).assertEqual('a_b.bin');
    });
    it('Test_sanitizeFileName_collapsesInnerDotDot', 0, () => {
      // MSG259 采纳项②：中间 `..` 也必须折叠（不可穿越，但名字里不该保留 `..`）
      const out: string = sanitizeFileName('a..b.bin', 5);
      expect(out.includes('..')).assertFalse();
      expect(out).assertEqual('a_b.bin');
    });

    it('Test_sanitizeFileName_emptyFallsBackToTid', 0, () => {
      expect(sanitizeFileName('', 42)).assertEqual('transfer_42');
      expect(sanitizeFileName('...', 42)).assertEqual('transfer_42');
    });
    it('Test_sanitizeFileName_limitsLength128', 0, () => {
      const long: string = 'x'.repeat(200);
      expect(sanitizeFileName(long, 1).length).assertEqual(128);
    });

    // ---------- 追加：边界与其它终态 ----------
    it('Test_detailActionMode_cancelledOnlyClose', 0, () => {
      expect(detailActionModeOf(transfer('receive', 'cancelled', false, false), true)).assertEqual('none');
    });
    it('Test_canDispose_cancelledFalse', 0, () => {
      expect(canDisposeOf(transfer('receive', 'cancelled', false, false))).assertFalse();
    });
    it('Test_batchCounts_cancelledCountsAsDone', 0, () => {
      const pc: PayloadTransfer = transfer('receive', 'cancelled', false, false, 5);
      const c: BatchCounts = batchCountsOf(batch([5], 1), (tid: number): PayloadTransfer | undefined => tid === 5 ? pc : undefined);
      expect(c.done).assertEqual(1);
    });
    it('Test_sanitizeFileName_keepsExtensionAndUnicode', 0, () => {
      expect(sanitizeFileName('照片 2026.png', 7)).assertEqual('照片 2026.png');
      expect(sanitizeFileName('a/b.png', 7)).assertEqual('a_b.png');
    });
    it('Test_expiryActionFor_failedStateUntouched', 0, () => {
      expect(expiryActionFor(transfer('receive', 'failed', false, false), false)).assertEqual('none');
    });

    // ---------- 紧凑时间 ----------
    it('Test_compactTimeText_invalidIsEmpty', 0, () => {
      expect(compactTimeText(undefined)).assertEqual('');
      expect(compactTimeText(0)).assertEqual('');
    });
    it('Test_compactTimeText_formatsHHMM', 0, () => {
      const d: Date = new Date(2026, 10, 12, 9, 5, 0);
      const t: string = compactTimeText(d.getTime());
      expect(t.length).assertEqual(5);
      expect(t.substring(2, 3)).assertEqual(':');
      expect(t.substring(0, 2)).assertEqual('09');
      expect(t.substring(3, 5)).assertEqual('05');
    });
  });
}
