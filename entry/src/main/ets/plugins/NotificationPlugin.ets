// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 【A2 / C3 草稿 —— 项目外草稿，待 Omp 提交 C1+C2 后落入仓库】
// 目标路径：entry/src/main/ets/plugins/NotificationPlugin.ets（**整体替换现 24 行桩**）
//
// 通知同步插件（kdeconnect.notification / .request）——阶段4 方向C。
// 设计：devdocs/DESIGN_STAGE4_NOTIFICATION_deveco.md §5。
//
// 分层：本插件**只解析 + 上抛类型化事件**，不持 UI 状态、不碰存储
//   （存储由页面持有的 NotificationStore 负责，与 systemvolume.sinks 同构）。
// 字段名取自任务书既定清单（id/appName/ticker/isClearable/time）；**未知字段忽略**（前向兼容）。
import { PluginBase } from './PluginBase';
import { NotificationBody, NotificationItem, NotificationParse, parseNotification } from '../model/NotificationModels';
import { PluginEvent } from './PluginEvent';

const PACKET_NOTIFICATION: string = 'kdeconnect.notification';

export class NotificationPlugin extends PluginBase {
  constructor() {
    super();
    this.displayName = 'Notification';
    this.description = 'Sync notifications with the peer';
    // caps 不动（既有 PluginRegistry.test.ets 有锁定）
    this.supportedPacketTypes = ['kdeconnect.notification'];
    this.outgoingPacketTypes = ['kdeconnect.notification.request'];
  }

  onPacketReceived(packetType: string, body: Object): boolean {
    if (packetType !== PACKET_NOTIFICATION) {
      return false;
    }
    const b: NotificationBody = body as NotificationBody;
    const parsed: NotificationParse = parseNotification(this.deviceId, b, Date.now());
    if (parsed.kind === 'drop') {
      // 空 id / 空 deviceId ⇒ 丢弃（记原因，不静默）；已"处理"该包（返回 true），不让上层记 unhandled
      this.log(`notification dropped: ${parsed.reason ?? 'unknown'}`);
      return true;
    }
    if (parsed.kind === 'cancel') {
      // N1 取消同步：对端关闭通知 ⇒ 本侧移除同 (deviceId,id)
      const cancelEv: PluginEvent = {
        kind: 'notificationCancel',
        notificationCancel: { deviceId: this.deviceId, id: parsed.cancelId ?? '' }
      };
      this.notifyEvent(cancelEv);
      this.log(`notification cancelled: ${parsed.cancelId ?? ''}`);
      return true;
    }
    const item: NotificationItem | undefined = parsed.item;
    if (item === undefined) {
      this.log('notification dropped: item missing');
      return true;
    }
    const ev: PluginEvent = { kind: 'notification', notification: item };
    this.notifyEvent(ev);
    this.log(`notification [${item.appName}] ${item.title.length > 0 ? item.title : item.text}`);
    return true;
  }
}
