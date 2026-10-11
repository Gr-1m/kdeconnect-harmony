// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 通知归一化 + 存储 单测（阶段4 方向C / A2 的 C1+C2）。
// **零 Kit 依赖纯逻辑** ⇒ 经 tools/arkts-logic-test.ps1 在宿主跑（无需设备）。
import { describe, it, expect } from '@ohos/hypium';
import { NotificationItem, NotificationBody, normalizeNotification } from '../../../main/ets/model/NotificationModels';
import { NotificationStore, MAX_PER_DEVICE } from '../../../main/ets/common/NotificationStore';

const DEV: string = 'aaaa1111111111111111111111111111';
const DEV2: string = 'bbbb2222222222222222222222222222';
const NOW: number = 1700000000000;

function item(id: string, deviceId: string, ticker: string): NotificationItem {
  const out: NotificationItem = {
    id: id, appName: 'app', ticker: ticker, isClearable: true,
    timeMs: NOW, deviceId: deviceId, receivedAtMs: NOW
  };
  return out;
}

export default function notificationTest(): void {
  describe('NotificationNormalizeTest', () => {

    it('TestNotificationNormalize_dropsWhenIdEmpty', 0, () => {
      const body: NotificationBody = { appName: 'a', ticker: 't' };
      expect(normalizeNotification(DEV, body, NOW) === undefined).assertTrue();
    });

    it('TestNotificationNormalize_dropsWhenDeviceIdEmpty', 0, () => {
      const body: NotificationBody = { id: 'n1', ticker: 't' };
      expect(normalizeNotification('', body, NOW) === undefined).assertTrue();
    });

    it('TestNotificationNormalize_mapsBasicFields', 0, () => {
      const body: NotificationBody = { id: 'n1', appName: 'Telegram', ticker: 'hi', isClearable: true };
      const n: NotificationItem | undefined = normalizeNotification(DEV, body, NOW);
      expect(n !== undefined).assertTrue();
      expect(n?.id).assertEqual('n1');
      expect(n?.appName).assertEqual('Telegram');
      expect(n?.ticker).assertEqual('hi');
      expect(n?.deviceId).assertEqual(DEV);
    });

    it('TestNotificationNormalize_missingTextFieldsBecomeEmpty', 0, () => {
      const body: NotificationBody = { id: 'n1' };
      const n: NotificationItem | undefined = normalizeNotification(DEV, body, NOW);
      expect(n?.appName).assertEqual('');
      expect(n?.ticker).assertEqual('');
    });

    it('TestNotificationNormalize_timeSecondsConvertedToMs', 0, () => {
      const body: NotificationBody = { id: 'n1', time: 1700000000 };
      const n: NotificationItem | undefined = normalizeNotification(DEV, body, NOW);
      expect(n?.timeMs).assertEqual(1700000000000);
    });

    it('TestNotificationNormalize_timeMsKeptAsIs', 0, () => {
      const body: NotificationBody = { id: 'n1', time: NOW };
      const n: NotificationItem | undefined = normalizeNotification(DEV, body, NOW);
      expect(n?.timeMs).assertEqual(NOW);
    });

    it('TestNotificationNormalize_timeIsoStringParsed', 0, () => {
      const body: NotificationBody = { id: 'n1', time: '2023-11-14T22:13:20.000Z' };
      const n: NotificationItem | undefined = normalizeNotification(DEV, body, NOW);
      expect(n?.timeMs).assertEqual(1700000000000);
    });

    it('TestNotificationNormalize_timeUnparsableFallsBackToNow', 0, () => {
      const bad: NotificationBody = { id: 'n1', time: 'not-a-date' };
      expect(normalizeNotification(DEV, bad, NOW)?.timeMs).assertEqual(NOW);
      const zero: NotificationBody = { id: 'n2', time: 0 };
      expect(normalizeNotification(DEV, zero, NOW)?.timeMs).assertEqual(NOW);
    });

    it('TestNotificationNormalize_isClearableDefaultsTrueWhenAbsent', 0, () => {
      const body: NotificationBody = { id: 'n1' };
      expect(normalizeNotification(DEV, body, NOW)?.isClearable).assertTrue();
    });

    it('TestNotificationNormalize_isClearableFalsePreserved', 0, () => {
      const body: NotificationBody = { id: 'n1', isClearable: false };
      expect(normalizeNotification(DEV, body, NOW)?.isClearable).assertFalse();
    });
  });

  describe('NotificationStoreTest', () => {

    it('TestNotificationStore_putPrependsNewestFirst', 0, () => {
      const s: NotificationStore = new NotificationStore();
      s.put(item('n1', DEV, 'first'));
      s.put(item('n2', DEV, 'second'));
      const list: NotificationItem[] = s.listOf(DEV);
      expect(list.length).assertEqual(2);
      expect(list[0].id).assertEqual('n2');
      expect(list[1].id).assertEqual('n1');
    });

    it('TestNotificationStore_putSameIdUpdatesInsteadOfDuplicating', 0, () => {
      const s: NotificationStore = new NotificationStore();
      s.put(item('n1', DEV, 'old'));
      s.put(item('n1', DEV, 'new'));
      const list: NotificationItem[] = s.listOf(DEV);
      expect(list.length).assertEqual(1);
      expect(list[0].ticker).assertEqual('new');
    });

    it('TestNotificationStore_devicesAreIsolated', 0, () => {
      const s: NotificationStore = new NotificationStore();
      s.put(item('n1', DEV, 'a'));
      s.put(item('n1', DEV2, 'b'));
      expect(s.countOf(DEV)).assertEqual(1);
      expect(s.countOf(DEV2)).assertEqual(1);
      expect(s.items.length).assertEqual(2);
    });

    it('TestNotificationStore_removeOnlyMatchingEntry', 0, () => {
      const s: NotificationStore = new NotificationStore();
      s.put(item('n1', DEV, 'a'));
      s.put(item('n2', DEV, 'b'));
      s.remove(DEV, 'n1');
      expect(s.countOf(DEV)).assertEqual(1);
      expect(s.listOf(DEV)[0].id).assertEqual('n2');
      s.remove(DEV, 'does-not-exist');
      expect(s.countOf(DEV)).assertEqual(1);
    });

    it('TestNotificationStore_clearDeviceLeavesOthersIntact', 0, () => {
      const s: NotificationStore = new NotificationStore();
      s.put(item('n1', DEV, 'a'));
      s.put(item('n2', DEV2, 'b'));
      s.clearDevice(DEV);
      expect(s.countOf(DEV)).assertEqual(0);
      expect(s.countOf(DEV2)).assertEqual(1);
    });

    it('TestNotificationStore_capsPerDeviceAtLimit', 0, () => {
      const s: NotificationStore = new NotificationStore();
      for (let i = 0; i < MAX_PER_DEVICE + 5; i++) {
        s.put(item(`n${i}`, DEV, `t${i}`));
      }
      expect(s.countOf(DEV)).assertEqual(MAX_PER_DEVICE);
      // 保留的是最新的（n(MAX+4) 在最前），最旧的被淘汰
      expect(s.listOf(DEV)[0].id).assertEqual(`n${MAX_PER_DEVICE + 4}`);
      expect(s.items.some((x: NotificationItem): boolean => x.id === 'n0')).assertFalse();
    });

    it('TestNotificationStore_capIsPerDeviceNotGlobal', 0, () => {
      const s: NotificationStore = new NotificationStore();
      for (let i = 0; i < MAX_PER_DEVICE; i++) {
        s.put(item(`n${i}`, DEV, `t${i}`));
      }
      s.put(item('other', DEV2, 'x'));
      expect(s.countOf(DEV)).assertEqual(MAX_PER_DEVICE);
      expect(s.countOf(DEV2)).assertEqual(1);
    });
  });
}
