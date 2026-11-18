// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// N2：对端通知 → 系统通知栏的**纯决策/格式化逻辑**（零 Kit 依赖 ⇒ 宿主可回归）。
// 设计见 devdocs/PLAN_NOTIFICATION_SYNC_20261118.md §3 N2。
//
// 不做的事：不碰 notificationManager、不持 Context（那层在 PeerNotificationPublisher）。

import { NotificationItem } from '../model/NotificationModels';

const FNV_OFFSET: number = 0x811C9DC5;
const FNV_PRIME: number = 0x01000193;

function fnv1a32(text: string): number {
  let h: number = FNV_OFFSET;
  for (let i = 0; i < text.length; i++) {
    h = (h ^ text.charCodeAt(i)) >>> 0;
    h = Math.imul(h, FNV_PRIME) >>> 0;
  }
  return h >>> 0;
}

/**
 * 系统通知 id：由 (deviceId, 对端 id) 稳定映射到 **正整数**（同条更新而不重复发新条）。
 * `& 0x7fffffff` 避开负 id；`| 1` 保证非 0（0 在部分实现里语义特殊）。
 */
export function publishKeyOf(deviceId: string, peerId: string): number {
  const key: number = fnv1a32(`${deviceId}:${peerId}`) & 0x7fffffff;
  return key === 0 ? 1 : key;
}

/** 分组名：按设备聚合（同一设备的对端通知归一组） */
export function publishGroupOf(deviceId: string): string {
  return `kdc:${deviceId}`;
}

/** 标题：优先对端 appName，缺失回落到应用名 */
export function publishTitleOf(item: NotificationItem): string {
  return item.appName.length > 0 ? item.appName : 'KDE Connect';
}

/** 正文：text → title → ticker（全空给占位，避免空白通知） */
export function publishBodyOf(item: NotificationItem): string {
  if (item.text.length > 0) {
    return item.text;
  }
  if (item.title.length > 0) {
    return item.title;
  }
  return item.ticker.length > 0 ? item.ticker : '（无内容）';
}

/**
 * 是否发系统通知：插件开关开 **且** 系统通知授权可用。
 * 未授权时不反复请求（由 Publisher 记一次），此处只做判定。
 */
export function shouldPublish(pluginEnabled: boolean, systemEnabled: boolean): boolean {
  return pluginEnabled && systemEnabled;
}
