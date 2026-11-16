// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// B-4 —— `contractVersion` 启动校验的**判定部分**回归（零 Kit 依赖 ⇒ 宿主 bun 与设备 hypium 双跑）。
// 生成与契约哈希的一致性由 `tools/gen-contract-version.py --check`（run.sh 门禁）与 CI 的
// 「ArkTS 常量 == d.ts 哈希 == native 返回值」三向比对共同保证（CCR-3 §2.3）。
import { describe, it, expect } from '@ohos/hypium';
import { EXPECTED_CONTRACT_VERSION, contractVersionOk } from '../../../main/ets/common/ContractVersion';

export default function contractVersionTest(): void {
  describe('ContractVersionTest', () => {
    it('TestContractVersion_constantIsGeneratedNonZero', 0, () => {
      // FNV-1a 32 位对非空文件必然非零；生成文件缺失/未生成时为 0
      expect(EXPECTED_CONTRACT_VERSION > 0).assertTrue();
      expect(Number.isInteger(EXPECTED_CONTRACT_VERSION)).assertTrue();
    });

    it('TestContractVersion_matchingActualAccepts', 0, () => {
      expect(contractVersionOk(EXPECTED_CONTRACT_VERSION)).assertTrue();
    });

    it('TestContractVersion_mismatchRejects', 0, () => {
      // 不匹配必须拒绝（调用方据此**拒绝 start**，E109 语义；不得静默继续）
      expect(contractVersionOk(EXPECTED_CONTRACT_VERSION + 1)).assertFalse();
      expect(contractVersionOk(EXPECTED_CONTRACT_VERSION - 1)).assertFalse();
      expect(contractVersionOk(0)).assertFalse();
    });
  });
}
