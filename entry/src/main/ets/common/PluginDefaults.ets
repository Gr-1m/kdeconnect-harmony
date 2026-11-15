// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 插件「默认开关」表 + 解析规则（P1-3；MSG264 §1 Q2 裁决：`defaultEnabled` = **UI 默认开关**，
// 在 ArkTS 侧实现，**不做能力广告过滤**——能力集仍由 native 按 `contract/capabilities.v1.json` 生成）。
//
// 本模块**零 Kit 依赖** ⇒ 宿主（bun）秒级回归；契约漂移由 `tools/check-plugin-defaults.py` 守卫
// （解析 `contract/capabilities.v1.json` 与本表逐项对比，接入 run.sh）。
//
// 语义：
//   · 默认值以 `contract/capabilities.v1.json` 的 `defaultEnabled` 为准（CCR-4：battery / connectivityreport = true；sftp = false）；
//   · 用户在设置里改过 ⇒ 以**用户覆盖**为准（持久化在 Preferences 的 `pluginEnabled` 单键 JSON）；
//   · 未知 key（新增插件但契约未登记）⇒ 视为**开**（不误伤），并在契约检查里暴露。

/** 契约 `defaultEnabled` 的 ArkTS 侧镜像（14 个插件；改动必须同步 `contract/capabilities.v1.json`） */
export const PLUGIN_DEFAULT_ENABLED: Map<string, boolean> = new Map<string, boolean>([
  ['ping', true],
  ['mousepad', true],
  ['presenter', true],
  ['mpris', true],
  ['systemvolume', true],
  ['runcommand', true],
  ['share', true],
  ['findmyphone', true],
  ['findremotedevice', true],
  ['clipboard', true],
  ['receivenotifications', true],
  // CCR-4（用户 2026-11-15 裁决）：battery/connectivityreport 保持默认开（桌面端电量/网络指示依赖）；
  // sftp 默认关（未实现，不广告能力）
  ['battery', true],
  ['connectivityreport', true],
  ['sftp', false]
]);

/**
 * packet type → 拥有它的**契约键**（多所有者用数组：如 `kdeconnect.mousepad.request` 同时属 mousepad/presenter）。
 * 用途：门禁按 **packet** 判定（本工程插件实例与契约键不是一一对应：`remoteinput` 一个实例服务 mousepad+presenter）。
 * 由 `tools/check-plugin-defaults.py` 与契约逐项核对（防漂移）。
 */
export const PACKET_OWNERS: Map<string, string[]> = new Map<string, string[]>([
  ['kdeconnect.battery', ['battery']],
  ['kdeconnect.clipboard', ['clipboard']],
  ['kdeconnect.clipboard.connect', ['clipboard']],
  ['kdeconnect.connectivity_report', ['connectivityreport']],
  ['kdeconnect.findmyphone.request', ['findmyphone', 'findremotedevice']],
  ['kdeconnect.mousepad.keyboardstate', ['mousepad']],
  ['kdeconnect.mousepad.request', ['mousepad', 'presenter']],
  ['kdeconnect.mpris', ['mpris']],
  ['kdeconnect.mpris.request', ['mpris']],
  ['kdeconnect.notification', ['receivenotifications']],
  ['kdeconnect.notification.request', ['receivenotifications']],
  ['kdeconnect.ping', ['ping']],
  ['kdeconnect.presenter', ['presenter']],
  ['kdeconnect.runcommand', ['runcommand']],
  ['kdeconnect.runcommand.request', ['runcommand']],
  ['kdeconnect.sftp', ['sftp']],
  ['kdeconnect.sftp.request', ['sftp']],
  ['kdeconnect.share.request', ['share']],
  ['kdeconnect.share.request.update', ['share']],
  ['kdeconnect.systemvolume', ['systemvolume']],
  ['kdeconnect.systemvolume.request', ['systemvolume']]
]);

/** packet 是否放行：任一所有者键为开即放行；未知 packet ⇒ 放行（不误伤新包） */
export function resolvePacketEnabled(packetType: string, overrides: Map<string, boolean>): boolean {
  const keys: string[] | undefined = PACKET_OWNERS.get(packetType);
  if (keys === undefined || keys.length === 0) {
    return true;
  }
  for (const k of keys) {
    if (resolvePluginEnabled(k, overrides)) {
      return true;
    }
  }
  return false;
}

/** 契约里的插件顺序（设置页按此顺序列开关） */
export function pluginKeys(): string[] {
  const out: string[] = [];
  PLUGIN_DEFAULT_ENABLED.forEach((v: boolean, k: string): void => {
    out.push(k);
  });
  return out;
}

/** 契约默认值；未知 key ⇒ true（不误伤新插件） */
export function pluginDefaultEnabled(key: string): boolean {
  const v: boolean | undefined = PLUGIN_DEFAULT_ENABLED.get(key);
  return v === undefined ? true : v;
}

/** 解析用户覆盖：入参为持久化 JSON（`{"battery":true}`）；坏数据一律忽略（不抛、不误改） */
export function parsePluginOverrides(raw: string): Map<string, boolean> {
  const out: Map<string, boolean> = new Map<string, boolean>();
  if (raw.length === 0) {
    return out;
  }
  try {
    const obj: Record<string, boolean> = JSON.parse(raw) as Record<string, boolean>;
    for (const key of Object.keys(obj)) {
      if (PLUGIN_DEFAULT_ENABLED.has(key) && typeof obj[key] === 'boolean') {
        out.set(key, obj[key]);
      }
    }
  } catch (e) {
    // 坏 JSON ⇒ 视为无覆盖（默认值生效）
  }
  return out;
}

/** 序列化用户覆盖（只写与契约默认不同的项，保持存储最小且可读） */
export function serializePluginOverrides(overrides: Map<string, boolean>): string {
  const obj: Record<string, boolean> = {};
  overrides.forEach((v: boolean, k: string): void => {
    if (pluginDefaultEnabled(k) !== v) {
      obj[k] = v;
    }
  });
  return JSON.stringify(obj);
}

/** 最终判定：用户覆盖优先，否则契约默认 */
export function resolvePluginEnabled(key: string, overrides: Map<string, boolean>): boolean {
  const o: boolean | undefined = overrides.get(key);
  return o === undefined ? pluginDefaultEnabled(key) : o;
}
