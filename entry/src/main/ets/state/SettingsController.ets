// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 设置领域控制器（阶段 3 批次 3 步骤 7a；设计见 devdocs/PROJECT_ROADMAP.md）。
//
// 抽离方式：自 Index.ets 的设置相关 @State 字段 + 4 个方法原样搬出。
//   · 状态全在 `SettingsController`（@Observed）⇒ 页面 @State 持实例，SettingsTab 用 @Prop 读；
//   · 用户动作经注入回调走页面既有实现（Context/native 不在本模块内直接碰）；
//   · `SettingEntry` interface 也随本模块迁出（Index 不再定义）。

import { THEME_FOLLOW_SYSTEM, LANG_SYSTEM, colorModeOf, languageOf } from '../common/AppSettings';
// P1-3：插件默认开关（契约 `defaultEnabled` 的镜像 + 用户覆盖）；纯逻辑在 common/PluginDefaults（宿主可回归）
import {
  pluginKeys, pluginDefaultEnabled, parsePluginOverrides, serializePluginOverrides, resolvePluginEnabled,
  resolvePacketEnabled
} from '../common/PluginDefaults';

export interface SettingEntry {
  key: string;
  value: string;
}

export const DEFAULT_DEVICE_NAME: string = 'kdeconnect-harmony';

@Observed
export class SettingsController {
  themeMode: number = THEME_FOLLOW_SYSTEM;
  // S2 契约 §3.5：接收文件自动保存开关（默认开＝保持既有行为）；关＝落 spool 等用户处置
  autoSaveFiles: boolean = true;
  language: string = LANG_SYSTEM;
  deviceName: string = DEFAULT_DEVICE_NAME;
  // P1-3：用户对插件默认开关的覆盖（空 = 全部用契约默认值）
  pluginOverrides: Map<string, boolean> = new Map<string, boolean>();

  log: (m: string) => void = () => {};
  persistEntries: (entries: SettingEntry[]) => Promise<void> = () => Promise.resolve();
  applyColorMode: (mode: number) => void = () => {};
  applyLang: (lang: string) => void = () => {};
  restartNative: () => void = () => {};

  // ==================== P1-3：插件默认开关（MSG264 §1 Q2 裁决）====================

  /** 契约里的插件键（设置页按此顺序列开关） */
  pluginSwitchKeys(): string[] {
    return pluginKeys();
  }

  /** 最终判定：用户覆盖优先，否则契约 `defaultEnabled`（未知键 ⇒ true） */
  isPluginEnabled(pluginKey: string): boolean {
    return resolvePluginEnabled(pluginKey, this.pluginOverrides);
  }

  /** 发出门禁（按 packet type；多所有者键任一开即放行） */
  isPacketEnabled(packetType: string): boolean {
    return resolvePacketEnabled(packetType, this.pluginOverrides);
  }

  /** 契约默认值（设置页展示「默认」提示用） */
  pluginDefault(pluginKey: string): boolean {
    return pluginDefaultEnabled(pluginKey);
  }

  /** 用户改开关：写覆盖 + 持久化（单键 JSON；只存与契约默认不同的项） */
  setPluginEnabled(pluginKey: string, on: boolean): void {
    if (!pluginKeys().includes(pluginKey)) {
      this.log(`plugin toggle ignored (unknown key): ${pluginKey}`);
      return;
    }
    // V1 只观察字段赋值（Map 原地 set 不触发重渲染）⇒ 复制后整体赋值
    const next: Map<string, boolean> = new Map<string, boolean>(this.pluginOverrides);
    next.set(pluginKey, on);
    this.pluginOverrides = next;
    this.log(`plugin ${pluginKey}: ${on ? 'on' : 'off'}`);
    const entries: SettingEntry[] = [{
      key: 'pluginEnabled',
      value: serializePluginOverrides(this.pluginOverrides)
    }];
    this.persistEntries(entries);
  }

  /** 启动加载（Preferences 单键 JSON）；坏数据一律忽略 ⇒ 回落到契约默认 */
  loadPluginOverrides(raw: string): void {
    this.pluginOverrides = parsePluginOverrides(raw);
    this.log(`plugin overrides loaded: ${this.pluginOverrides.size}`);
  }

  applyTheme(mode: number, persist: boolean): void {
    this.themeMode = mode;
    this.applyColorMode(mode);
    if (persist) {
      const entries: SettingEntry[] = [{ key: 'themeMode', value: `${mode}` }];
      this.persistEntries(entries);
    }
  }

  setAutoSaveFiles(on: boolean): void {
    this.autoSaveFiles = on;
    this.log(`auto-save files: ${on ? 'on' : 'off'}`);
    const entries: SettingEntry[] = [{ key: 'autoSaveFiles', value: on ? '1' : '0' }];
    this.persistEntries(entries);
  }

  applyLanguage(lang: string, persist: boolean): void {
    this.language = lang;
    this.applyLang(lang);
    if (persist) {
      const entries: SettingEntry[] = [{ key: 'language', value: lang }];
      this.persistEntries(entries);
    }
  }

  renameDevice(name: string): void {
    if (name.length === 0 || name === this.deviceName) {
      return;
    }
    this.deviceName = name;
    const entries: SettingEntry[] = [{ key: 'deviceName', value: name }];
    this.persistEntries(entries);
    this.log(`rename device -> ${name} (restart native)`);
    this.restartNative();
  }
}
