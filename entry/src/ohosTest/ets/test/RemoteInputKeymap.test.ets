// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// RemoteInputKeymap 单测（阶段4 方向B / B1b；设计 §1.3）。
// 跨端契约 = 下标语义（KDE `SpecialKeysMap`）：0 无效、1..32 有效。
import { describe, it, expect } from '@ohos/hypium';
import {
  isValidSpecialKey, specialKeyName, specialKeyCodes,
  SPECIAL_KEY_INVALID, SPECIAL_KEY_MAX
} from '../../../main/ets/plugins/RemoteInputKeymap';

export default function remoteInputKeymapTest(): void {
  describe('RemoteInputKeymapTest', () => {

    it('TestRemoteInputKeymap_zeroIsInvalid', 0, () => {
      expect(SPECIAL_KEY_INVALID).assertEqual(0);
      expect(isValidSpecialKey(0)).assertFalse();
      expect(specialKeyName(0)).assertEqual('');
    });

    it('TestRemoteInputKeymap_rangeBoundaries', 0, () => {
      expect(SPECIAL_KEY_MAX).assertEqual(32);
      expect(isValidSpecialKey(1)).assertTrue();
      expect(isValidSpecialKey(32)).assertTrue();
      expect(isValidSpecialKey(33)).assertFalse();
      expect(isValidSpecialKey(-1)).assertFalse();
    });

    it('TestRemoteInputKeymap_rejectsNonInteger', 0, () => {
      expect(isValidSpecialKey(1.5)).assertFalse();
      expect(isValidSpecialKey(4.0001)).assertFalse();
    });

    it('TestRemoteInputKeymap_knownIndices', 0, () => {
      // 原文（AtomCode MSG134 §三.4）
      expect(specialKeyName(1)).assertEqual('BackSpace');
      expect(specialKeyName(2)).assertEqual('Tab');
      expect(specialKeyName(4)).assertEqual('Left');
      expect(specialKeyName(7)).assertEqual('Down');
      expect(specialKeyName(8)).assertEqual('PageUp');
      expect(specialKeyName(10)).assertEqual('Home');
      expect(specialKeyName(12)).assertEqual('Return');
      expect(specialKeyName(13)).assertEqual('Delete');
      expect(specialKeyName(14)).assertEqual('Escape');
      expect(specialKeyName(17)).assertEqual('Ctrl');
      expect(specialKeyName(20)).assertEqual('Super');
      expect(specialKeyName(21)).assertEqual('F1');
      expect(specialKeyName(32)).assertEqual('F12');
    });

    it('TestRemoteInputKeymap_outOfRangeHasNoName', 0, () => {
      expect(specialKeyName(33)).assertEqual('');
      expect(specialKeyName(-2)).assertEqual('');
    });

    it('TestRemoteInputKeymap_allValidIndicesHaveNames', 0, () => {
      for (let i = 1; i <= SPECIAL_KEY_MAX; i++) {
        expect(specialKeyName(i).length > 0).assertTrue();
      }
    });

    it('TestRemoteInputKeymap_codesListCovers1To32', 0, () => {
      const codes: number[] = specialKeyCodes();
      expect(codes.length).assertEqual(32);
      expect(codes[0]).assertEqual(1);
      expect(codes[31]).assertEqual(32);
    });
  });
}
