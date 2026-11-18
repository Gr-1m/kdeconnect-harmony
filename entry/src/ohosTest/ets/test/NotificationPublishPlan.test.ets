// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// N2 单测：对端通知 → 系统通知栏的**纯决策/格式化**（零 Kit ⇒ 宿主 bun 与设备 hypium 双跑）。
import { describe, it, expect } from '@ohos/hypium';
import { NotificationItem } from '../../../main/ets/model/NotificationModels';
import {
  publishBodyOf,
  publishGroupOf,
  publishKeyOf,
  publishTitleOf,
  shouldPublish
} from '../../../main/ets/common/NotificationPublishPlan';

const DEV: string = 'aaaa1111111111111111111111111111';
const DEV2: string = 'bbbb2222222222222222222222222222';

function item(appName: string, title: string, text: string, ticker: string): NotificationItem {
  const out: NotificationItem = {
    id: 'n1', appName: appName, title: title, text: text, ticker: ticker,
    isClearable: true, actions: [], timeMs: 1700000000000, deviceId: DEV,
    receivedAtMs: 1700000000000
  };
  return out;
}

export default function notificationPublishPlanTest(): void {
  describe('NotificationPublishPlanTest', () => {

    it('TestPublishPlan_keyIsStablePositiveAndScoped', 0, () => {
      const a: number = publishKeyOf(DEV, 'n1');
      expect(a).assertEqual(publishKeyOf(DEV, 'n1'));       // 稳定
      expect(a > 0).assertTrue();                           // 正整数（避开负 id 与 0）
      expect(a !== publishKeyOf(DEV, 'n2')).assertTrue();    // 不同 peerId
      expect(a !== publishKeyOf(DEV2, 'n1')).assertTrue();   // 不同设备
    });

    it('TestPublishPlan_groupIsPerDevice', 0, () => {
      expect(publishGroupOf(DEV)).assertEqual(`kdc:${DEV}`);
      expect(publishGroupOf(DEV) !== publishGroupOf(DEV2)).assertTrue();
    });

    it('TestPublishPlan_titlePrefersAppNameWithFallback', 0, () => {
      expect(publishTitleOf(item('Telegram', '', '', ''))).assertEqual('Telegram');
      expect(publishTitleOf(item('', '', '', ''))).assertEqual('KDE Connect');
    });

    it('TestPublishPlan_bodyFallbackOrder', 0, () => {
      expect(publishBodyOf(item('a', 'T', 'body', 'T body'))).assertEqual('body');   // text 优先
      expect(publishBodyOf(item('a', 'T', '', 'T body'))).assertEqual('T');          // 次 title
      expect(publishBodyOf(item('a', '', '', 'T body'))).assertEqual('T body');      // 再 ticker
      expect(publishBodyOf(item('a', '', '', ''))).assertEqual('（无内容）');         // 占位
    });

    it('TestPublishPlan_shouldPublishNeedsBothSwitches', 0, () => {
      expect(shouldPublish(true, true)).assertTrue();
      expect(shouldPublish(true, false)).assertFalse();   // 系统未授权
      expect(shouldPublish(false, true)).assertFalse();   // 插件关
      expect(shouldPublish(false, false)).assertFalse();
    });
  });
}
