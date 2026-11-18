// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// N2：对端通知 → 系统通知栏的**唯一 Kit 依赖层**（publish / cancel / 授权）。
// 设计见 devdocs/PLAN_NOTIFICATION_SYNC_20261118.md §3 N2；决策/文案在 NotificationPublishPlan（零 Kit）。
//
// 约束：
//   · 授权只请求**一次**（用户拒绝后不再反复弹，只记日志；app 内列表仍然可用）；
//   · 平台事实：发布本应用通知无需系统权限；**读取他人通知**才是系统接口（TX 方向不可用，见方案 §1）；
//   · 发布的 id 由 (deviceId, peerId) 稳定映射 ⇒ 同条更新不重复发新条；
//   · 断链 / 对端取消 / 本地关闭 都要能取消对应系统通知（按设备记录已发 id）。
import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NotificationItem } from '../model/NotificationModels';
import { publishBodyOf, publishGroupOf, publishKeyOf, publishTitleOf, shouldPublish } from './NotificationPublishPlan';
import { LogStore } from './LogStore';
import { hilog } from '@kit.PerformanceAnalysisKit';

export class PeerNotificationPublisher {
  /** 注入：日志（页面持有 LogStore） */
  logStore: LogStore | undefined = undefined;
  /** 注入：当前插件开关状态（receivenotifications） */
  pluginEnabled: () => boolean = () => true;

  private ctx: common.UIAbilityContext | undefined = undefined;
  private requested: boolean = false;
  private systemEnabled: boolean = false;
  private known: boolean = false;
  /** deviceId → 已发布的系统通知 id（断链/取消时按设备清） */
  private published: Map<string, number[]> = new Map<string, number[]>();

  setContext(ctx: common.UIAbilityContext | undefined): void {
    this.ctx = ctx;
  }

  /** 查询/申请一次通知授权（幂等；拒绝后不再弹） */
  async ensureEnabled(): Promise<boolean> {
    if (this.known) {
      return this.systemEnabled;
    }
    try {
      this.systemEnabled = await notificationManager.isNotificationEnabled();
    } catch (e) {
      this.systemEnabled = false;
    }
    if (!this.systemEnabled && this.ctx !== undefined && !this.requested) {
      this.requested = true;
      try {
        await notificationManager.requestEnableNotification(this.ctx);
        this.systemEnabled = await notificationManager.isNotificationEnabled();
      } catch (e) {
        const err = e as BusinessError;
        this.log(`peer notification: requestEnableNotification failed ${err.code} ${err.message}`);
        this.systemEnabled = false;
      }
    }
    this.known = true;
    // 真机取证：授权状态一行（只打一次）
    hilog.info(0x0000, 'KDC-Notif', 'system notifications enabled=%{public}s', `${this.systemEnabled}`);
    if (!this.systemEnabled) {
      this.log('peer notification: system notifications unavailable — app 内列表仍可用');
    }
    return this.systemEnabled;
  }

  /** 发一条系统通知（同 (deviceId,id) 覆盖） */
  publish(item: NotificationItem): void {
    this.ensureEnabled().then((ok: boolean): void => {
      if (!shouldPublish(this.pluginEnabled(), ok)) {
        return;
      }
      const id: number = publishKeyOf(item.deviceId, item.id);
      const request: notificationManager.NotificationRequest = {
        id: id,
        groupName: publishGroupOf(item.deviceId),
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: publishTitleOf(item),
            text: publishBodyOf(item)
          }
        }
      };
      notificationManager.publish(request).then((): void => {
        this.track(item.deviceId, id);
        hilog.info(0x0000, 'KDC-Notif', 'published id=%{public}d dev=%{public}s', id, item.deviceId);
      }).catch((e: BusinessError): void => {
        hilog.error(0x0000, 'KDC-Notif', 'publish failed %{public}d %{public}s', e.code, e.message);
        this.log(`peer notification publish failed ${e.code} ${e.message}`);
      });
    }).catch((e: BusinessError): void => {
      this.log(`peer notification ensureEnabled failed ${e.code} ${e.message}`);
    });
  }

  /** 取消一条（对端 isCancel / 本地关闭） */
  cancel(deviceId: string, peerId: string): void {
    const id: number = publishKeyOf(deviceId, peerId);
    this.cancelId(deviceId, id);
  }

  /** 取消某设备全部已发系统通知（断链 / 清空列表） */
  cancelDevice(deviceId: string): void {
    const ids: number[] | undefined = this.published.get(deviceId);
    if (ids === undefined) {
      return;
    }
    hilog.info(0x0000, 'KDC-Notif', 'cancelDevice dev=%{public}s count=%{public}d', deviceId, ids.length);
    for (const id of ids) {
      notificationManager.cancel(id).catch((e: BusinessError): void => {
        this.log(`peer notification cancel failed ${e.code} ${e.message}`);
      });
    }
    this.published.delete(deviceId);
  }

  private cancelId(deviceId: string, id: number): void {
    notificationManager.cancel(id).catch((e: BusinessError): void => {
      this.log(`peer notification cancel failed ${e.code} ${e.message}`);
    });
    const ids: number[] | undefined = this.published.get(deviceId);
    if (ids !== undefined) {
      this.published.set(deviceId, ids.filter((x: number): boolean => x !== id));
    }
  }

  private track(deviceId: string, id: number): void {
    const ids: number[] | undefined = this.published.get(deviceId);
    if (ids === undefined) {
      this.published.set(deviceId, [id]);
      return;
    }
    if (ids.indexOf(id) < 0) {
      ids.push(id);
      // 单设备上限与 NotificationStore 对齐（50）：只留最近的，其余取消
      while (ids.length > 50) {
        const old: number | undefined = ids.shift();
        if (old !== undefined) {
          notificationManager.cancel(old).catch((): void => {
          });
        }
      }
    }
  }

  private log(line: string): void {
    if (this.logStore !== undefined) {
      this.logStore.append(line);
    }
  }
}
