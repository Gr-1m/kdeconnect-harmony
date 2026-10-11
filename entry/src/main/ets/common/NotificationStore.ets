// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 通知存储（阶段4 方向C / A2 的 C2；设计见 devdocs/DESIGN_STAGE4_NOTIFICATION_deveco.md §3）。
//
// **零 Kit 依赖纯逻辑**（@Observed 仅装饰器，宿主通道有 no-op 替身）⇒ 可无设备验证。
//
// 设计（对齐本工程"单一数据源 + 整体替换"范式，同 SystemVolumePlugin 的教训）：
//   · 唯一状态 = `items`（全量、按设备由 UI 过滤）；**不做 Map 原地改**（@Observed 观测不到 Map 变更）；
//   · 每次写入都**整体替换数组** ⇒ 触发刷新；
//   · 每设备上限 **50 条**（FIFO 淘汰最旧），防长会话内存无界；
//   · **不持久化**（会话内；重启即空）—— 对齐桌面版行为与设计 §3。
import { NotificationItem } from '../model/NotificationModels';

export const MAX_PER_DEVICE: number = 50;

@Observed
export class NotificationStore {
  /** 全量条目（最新在前） */
  items: NotificationItem[] = [];

  /** 新到/更新：同 (deviceId,id) 覆盖并置顶；随后按设备裁剪到上限 */
  put(item: NotificationItem): void {
    const rest: NotificationItem[] = this.items.filter(
      (x: NotificationItem) => !(x.deviceId === item.deviceId && x.id === item.id));
    this.items = this.trimDevice([item].concat(rest), item.deviceId);
  }

  /** 本地关闭一条（本期唯一"关闭"语义：纯本地，不发包） */
  remove(deviceId: string, id: string): void {
    const next: NotificationItem[] = this.items.filter(
      (x: NotificationItem) => !(x.deviceId === deviceId && x.id === id));
    if (next.length !== this.items.length) {
      this.items = next;
    }
  }

  /** 某设备断链/解除配对时清空其通知 */
  clearDevice(deviceId: string): void {
    const next: NotificationItem[] = this.items.filter((x: NotificationItem) => x.deviceId !== deviceId);
    if (next.length !== this.items.length) {
      this.items = next;
    }
  }

  /** 某设备的条目（列表已按最新在前） */
  listOf(deviceId: string): NotificationItem[] {
    return this.items.filter((x: NotificationItem) => x.deviceId === deviceId);
  }

  countOf(deviceId: string): number {
    return this.listOf(deviceId).length;
  }

  // 只保留该设备最新的 MAX_PER_DEVICE 条（其余设备原样）
  private trimDevice(all: NotificationItem[], deviceId: string): NotificationItem[] {
    const kept: NotificationItem[] = [];
    let keptForDevice: number = 0;
    for (const x of all) {
      if (x.deviceId !== deviceId) {
        kept.push(x);
        continue;
      }
      if (keptForDevice < MAX_PER_DEVICE) {
        kept.push(x);
        keptForDevice++;
      }
    }
    return kept;
  }
}
