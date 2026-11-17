// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// B-4/B-2 端到端回归（**设备侧专用**：`KcBridge` 直连 native，宿主通道跑不了）：
//   ① native `contractVersion()` 必须等于生成常量（三向比对的「ArkTS 常量 == native 返回值」这一半）；
//   ② 5 个配对原语在无链路/非法入参下**返回布尔且不抛**（接线正确性的最小证据）。
import { describe, it, expect } from '@ohos/hypium';
import { KcBridge } from '../../../main/ets/net/KcBridge';
import { EXPECTED_CONTRACT_VERSION } from '../../../main/ets/common/ContractVersion';

const BOGUS: string = 'zzzz1111111111111111111111111111';

export default function kcBridgeContractTest(): void {
  describe('KcBridgeContractTest', () => {
    it('TestKcBridge_contractVersionMatchesGeneratedConstant', 0, () => {
      const actual: number = KcBridge.contractVersion();
      expect(actual).assertEqual(EXPECTED_CONTRACT_VERSION);
    });

    it('TestKcBridge_pairPrimitivesReturnBoolean', 0, () => {
      // 无对端链路 ⇒ 发送不成功（false），但**不得抛异常**；空 deviceId 必须被拒
      expect(KcBridge.requestPair('')).assertFalse();
      expect(KcBridge.acceptPair('')).assertFalse();
      expect(KcBridge.rejectPair('')).assertFalse();
      expect(KcBridge.unpair('')).assertFalse();
      expect(typeof KcBridge.requestPair(BOGUS)).assertEqual('boolean');
      expect(typeof KcBridge.acceptPair(BOGUS)).assertEqual('boolean');
      expect(typeof KcBridge.rejectPair(BOGUS)).assertEqual('boolean');
      expect(typeof KcBridge.unpair(BOGUS)).assertEqual('boolean');
    });

    it('TestKcBridge_setDeviceNameRejectsEmpty', 0, () => {
      // 空名必须被拒（native：trim 后为空 ⇒ false）；非空名无链路时仍应返回布尔
      expect(KcBridge.setDeviceName('')).assertFalse();
      expect(typeof KcBridge.setDeviceName('kdc-test-name')).assertEqual('boolean');
    });
  });
}
