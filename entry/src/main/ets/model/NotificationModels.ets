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
  /** 标题（桌面端 sendnotifications 提供；缺则用 ticker） */
  title?: string;
  /** 正文 */
  text?: string;
  ticker?: string;
  /** true = 对端已关闭该通知（取消同步，N1） */
  isCancel?: boolean;
  isClearable?: boolean;
  /** 动作列表（本期只读展示，桌面端不支持回传） */
  actions?: string[];
  /** 可回复通知的 UUID（本期不使用，桌面 sendnotifications 不支持 reply 回传） */
  requestReplyId?: string;
  /** 双兼容：number（秒或毫秒）或 ISO8601 字符串 */
  time?: number | string;
}

export interface NotificationItem {
  /** 对端通知标识；同 id 再次到达 = 更新同一条 */
  id: string;
  appName: string;
  /** 标题（缺省空串） */
  title: string;
  /** 正文（缺省空串） */
  text: string;
  /** 主文本（标题/摘要，对端已合成） */
  ticker: string;
  isClearable: boolean;
  /** 动作列表（只读展示） */
  actions: string[];
  /** 可回复 UUID（本期不使用） */
  requestReplyId?: string;
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

/** 解析结果（N1）：条目 / 取消 / 丢弃三分，**丢弃必须给原因**（不静默） */
export interface NotificationParse {
  kind: 'item' | 'cancel' | 'drop';
  item?: NotificationItem;
  cancelId?: string;
  reason?: string;
}

/** 动作列表清洗：非字符串忽略（前向兼容），最多保留 8 条 */
function normalizeActions(raw: string[] | undefined): string[] {
  if (raw === undefined || !Array.isArray(raw)) {
    return [];
  }
  const out: string[] = [];
  for (const a of raw) {
    if (typeof a === 'string' && a.length > 0 && out.length < 8) {
      out.push(a);
    }
  }
  return out;
}

/**
 * 对端 body → 解析结果（N1 起的主入口）：
 *   · `isCancel:true` ⇒ `cancel`（带 id；无 id ⇒ drop，防脏取消）；
 *   · 正常 ⇒ `item`（title/text 缺省空串，actions 清洗，未知字段忽略）；
 *   · 空 id / 空 deviceId ⇒ `drop` + reason。
 */
export function parseNotification(deviceId: string, body: NotificationBody, nowMs: number): NotificationParse {
  const id: string = body.id ?? '';
  if (deviceId.length === 0) {
    return { kind: 'drop', reason: 'empty deviceId' };
  }
  if (id.length === 0) {
    return { kind: 'drop', reason: 'empty id' };
  }
  if (body.isCancel === true) {
    return { kind: 'cancel', cancelId: id };
  }
  const item: NotificationItem = {
    id: id,
    appName: body.appName ?? '',
    title: body.title ?? '',
    text: body.text ?? body.ticker ?? '',
    ticker: body.ticker ?? '',
    isClearable: body.isClearable !== false,
    actions: normalizeActions(body.actions),
    requestReplyId: body.requestReplyId,
    timeMs: normalizeTime(body.time, nowMs),
    deviceId: deviceId,
    receivedAtMs: nowMs
  };
  return { kind: 'item', item: item };
}

/** 兼容入口：仅返回条目（取消/丢弃 → undefined） */
export function normalizeNotification(deviceId: string, body: NotificationBody, nowMs: number): NotificationItem | undefined {
  const parsed: NotificationParse = parseNotification(deviceId, body, nowMs);
  return parsed.kind === 'item' ? parsed.item : undefined;
}
