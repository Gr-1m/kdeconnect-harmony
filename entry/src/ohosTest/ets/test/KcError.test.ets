// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// B-3 —— 桥层错误码表与分级处置回归（零 Kit 依赖 ⇒ 宿主 bun 与设备 hypium 双跑）。
// 契约漂移由 `tools/check-error-codes.py`（run.sh 门禁）逐项核对。
import { describe, it, expect } from '@ohos/hypium';
import {
  KC_ERRORS, kcErrorInfo, dispositionOf, nameOf, isLinkFatal, uiNoticeFor, formatKcError
} from '../../../main/ets/common/KcError';

export default function kcErrorTest(): void {
  describe('KcErrorTest', () => {
    it('TestKcError_mirrorCoversContractCodes', 0, () => {
      expect(KC_ERRORS.size).assertEqual(20);
      expect(nameOf(101)).assertEqual('NOT_READY');
      expect(nameOf(109)).assertEqual('CONTRACT_MISMATCH');
      expect(nameOf(201)).assertEqual('CERT_MISMATCH');
      expect(nameOf(501)).assertEqual('ENGINE_PANIC');
    });

    it('TestKcError_dispositionPerContract', 0, () => {
      expect(dispositionOf(109)).assertEqual('FatalLink');     // 契约不匹配
      expect(dispositionOf(104)).assertEqual('DropPacket');    // BAD_JSON
      expect(dispositionOf(401)).assertEqual('DropPacket');    // 4xx（payload/IO 域）
      expect(dispositionOf(501)).assertEqual('Infra');         // 5xx（桥/panic）
    });

    it('TestKcError_unknownCodeIsInfraNotThrow', 0, () => {
      // 不变式：未知码 ⇒ Infra + 只记日志，不崩、不打扰用户
      expect(dispositionOf(99999)).assertEqual('Infra');
      expect(nameOf(99999)).assertEqual('UNKNOWN');
      expect(uiNoticeFor(99999)).assertFalse();
      expect(isLinkFatal(99999)).assertFalse();
    });

    it('TestKcError_uiNoticeOnlyForFatalLink', 0, () => {
      expect(uiNoticeFor(101)).assertTrue();      // FatalLink ⇒ 用户可见
      expect(uiNoticeFor(104)).assertFalse();     // DropPacket ⇒ 仅日志
      expect(uiNoticeFor(501)).assertFalse();     // Infra ⇒ 仅日志
      expect(isLinkFatal(101)).assertTrue();
      expect(isLinkFatal(104)).assertFalse();
    });

    it('TestKcError_formatIsSearchable', 0, () => {
      expect(formatKcError(109, 'contract version mismatch'))
        .assertEqual('KC_E109: contract version mismatch');
      // 空 message ⇒ 回落错误名（仍有 KC_E 前缀，可检索）
      expect(formatKcError(104, '')).assertEqual('KC_E104: BAD_JSON');
    });

    it('TestKcError_kindMirrorsContract', 0, () => {
      const throwCodes: number = [101, 102, 103, 104, 105, 109].length;
      let counted: number = 0;
      KC_ERRORS.forEach((info): void => {
        if (info.kind === 'throw') {
          counted++;
        }
      });
      expect(counted).assertEqual(throwCodes);
    });
  });
}
