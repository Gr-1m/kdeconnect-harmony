// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 通知数据模型 + 归一化（阶段4 方向C / A2 的 C1；设计见
// devdocs/DESIGN_STAGE4_NOTIFICATION_deveco.md §2）。
//
// 本文件为**零 Kit 依赖纯逻辑** ⇒ 可被 tools/arkts-logic-test.ps1 在宿主直接跑（无需设备）。
//
// 归一化不变量：
//   ① `id` 或 `deviceId` 为空 ⇒ 丢弃（防脏条目污染列表）；
//   ② `time` **双兼容**（number 秒/毫秒 或 ISO8601 字符串），无法解析时回落 `receivedAtMs`
//      —— 对齐 docs/kdeconnect-oh/09 §互作坑「数值字段解析一律双兼容」；
//   ③ `isClearable` 非布尔 ⇒ 视为 `true`（保守：允许本地关闭）；
//   ④ **未知字段一律忽略**（前向兼容，schema 增字段不破解析）。

/** 对端 `kdeconnect.notification` body 中我们读取的字段（其余忽略） */
export interface NotificationBody {
  id?: string;
  appName?: string;
  ticker?: string;
  isClearable?: boolean;
  /** 双兼容：number（秒或毫秒）或 ISO8601 字符串 */
  time?: number | string;
}

export interface NotificationItem {
  /** 对端通知标识；同 id 再次到达 = 更新同一条 */
  id: string;
  appName: string;
  /** 主文本（标题/摘要，对端已合成） */
  ticker: string;
  isClearable: boolean;
  /** 规整为 epoch ms */
  timeMs: number;
  /** 来自哪台设备（多设备区分） */
  deviceId: string;
  /** 本侧收到时刻（排序兜底） */
  receivedAtMs: number;
}

// 秒 / 毫秒判定上界：1e12 ms ≈ 2001 年，1e12 s ≈ 公元 33658 年 ⇒ 小于它视为秒
const MS_THRESHOLD: number = 1000000000000;

function normalizeTime(raw: number | string | undefined, nowMs: number): number {
  if (raw === undefined) {
    return nowMs;
  }
  if (typeof raw === 'number') {
    if (!(raw > 0)) {
      return nowMs;
    }
    return raw < MS_THRESHOLD ? raw * 1000 : raw;
  }
  const parsed: number = Date.parse(raw);
  return isNaN(parsed) ? nowMs : parsed;
}

/** 对端 body → 我方条目；不可用时返回 undefined（调用方丢弃） */
export function normalizeNotification(deviceId: string, body: NotificationBody, nowMs: number): NotificationItem | undefined {
  const id: string = body.id ?? '';
  if (id.length === 0 || deviceId.length === 0) {
    return undefined;
  }
  const item: NotificationItem = {
    id: id,
    appName: body.appName ?? '',
    ticker: body.ticker ?? '',
    isClearable: body.isClearable !== false,
    timeMs: normalizeTime(body.time, nowMs),
    deviceId: deviceId,
    receivedAtMs: nowMs
  };
  return item;
}
