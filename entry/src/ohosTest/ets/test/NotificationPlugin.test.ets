// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 【A2 / C3 草稿 —— 项目外草稿】目标路径：entry/src/ohosTest/ets/test/NotificationPlugin.test.ets
//
// 手法同 RemoteInputPlugin.test.ets：经 `PluginBase.bind()` 注入**捕获式 uiFn**，
// 直接断言上抛的**类型化事件字段**（而非字符串）⇒ 字段名/类型被写错会立刻失败。
import { describe, it, expect } from '@ohos/hypium';
import { NotificationPlugin } from '../../../main/ets/plugins/NotificationPlugin';
import { PluginEvent } from '../../../main/ets/plugins/PluginEvent';
import { NotificationBody, NotificationItem } from '../../../main/ets/model/NotificationModels';

const DEVICE: string = 'aaaa1111111111111111111111111111';
const PACKET: string = 'kdeconnect.notification';

class Cap {
  events: PluginEvent[] = [];
  logs: string[] = [];

  lastNotification(): NotificationItem | undefined {
    return this.events[this.events.length - 1].notification;
  }
}

function bound(cap: Cap): NotificationPlugin {
  const p: NotificationPlugin = new NotificationPlugin();
  p.bind(DEVICE, (deviceId: string, json: string): boolean => true,
    (m: string): void => {
      cap.logs.push(m);
    },
    (deviceId: string, ev: PluginEvent): void => {
      cap.events.push(ev);
    });
  return p;
}

function body(id: string, app: string, ticker: string): NotificationBody {
  const b: NotificationBody = { id: id, appName: app, ticker: ticker, isClearable: true };
  return b;
}

export default function notificationPluginTest(): void {
  describe('NotificationPluginTest', () => {

    it('TestNotificationPlugin_emitsTypedNotificationEvent', 0, () => {
      const cap: Cap = new Cap();
      const handled: boolean = bound(cap).onPacketReceived(PACKET, body('n1', 'Telegram', 'hello'));
      expect(handled).assertTrue();
      expect(cap.events.length).assertEqual(1);
      expect(cap.events[0].kind).assertEqual('notification');
      expect(cap.lastNotification()?.id).assertEqual('n1');
      expect(cap.lastNotification()?.appName).assertEqual('Telegram');
      expect(cap.lastNotification()?.ticker).assertEqual('hello');
    });

    it('TestNotificationPlugin_usesBoundDeviceId', 0, () => {
      const cap: Cap = new Cap();
      bound(cap).onPacketReceived(PACKET, body('n1', 'a', 't'));
      expect(cap.lastNotification()?.deviceId).assertEqual(DEVICE);
    });

    it('TestNotificationPlugin_missingIdDropsWithoutEvent', 0, () => {
      const cap: Cap = new Cap();
      const empty: NotificationBody = {};
      const handled: boolean = bound(cap).onPacketReceived(PACKET, empty);
      // 仍算"已处理"（不让上层记 unhandled），但不上抛事件
      expect(handled).assertTrue();
      expect(cap.events.length).assertEqual(0);
    });

    it('TestNotificationPlugin_otherPacketTypeNotHandled', 0, () => {
      const cap: Cap = new Cap();
      expect(bound(cap).onPacketReceived('kdeconnect.ping', body('n1', 'a', 't'))).assertFalse();
      expect(cap.events.length).assertEqual(0);
    });

    it('TestNotificationPlugin_timeSecondsNormalizedToMs', 0, () => {
      const cap: Cap = new Cap();
      const b: NotificationBody = { id: 'n1', time: 1700000000 };
      bound(cap).onPacketReceived(PACKET, b);
      expect(cap.lastNotification()?.timeMs).assertEqual(1700000000000);
    });

    it('TestNotificationPlugin_isClearableFalsePreserved', 0, () => {
      const cap: Cap = new Cap();
      const b: NotificationBody = { id: 'n1', isClearable: false };
      bound(cap).onPacketReceived(PACKET, b);
      expect(cap.lastNotification()?.isClearable).assertFalse();
    });

    it('TestNotificationPlugin_receivedAtIsFilled', 0, () => {
      const cap: Cap = new Cap();
      bound(cap).onPacketReceived(PACKET, body('n1', 'a', 't'));
      expect(cap.lastNotification()?.receivedAtMs !== undefined).assertTrue();
    });
  });
}
