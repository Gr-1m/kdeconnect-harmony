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

export interface SettingEntry {
  key: string;
  value: string;
}

export const DEFAULT_DEVICE_NAME: string = 'kdeconnect-harmony';

@Observed
export class SettingsController {
  themeMode: number = THEME_FOLLOW_SYSTEM;
  language: string = LANG_SYSTEM;
  deviceName: string = DEFAULT_DEVICE_NAME;

  log: (m: string) => void = () => {};
  persistEntries: (entries: SettingEntry[]) => Promise<void> = () => Promise.resolve();
  applyColorMode: (mode: number) => void = () => {};
  applyLang: (lang: string) => void = () => {};
  restartNative: () => void = () => {};

  applyTheme(mode: number, persist: boolean): void {
    this.themeMode = mode;
    this.applyColorMode(mode);
    if (persist) {
      const entries: SettingEntry[] = [{ key: 'themeMode', value: `${mode}` }];
      this.persistEntries(entries);
    }
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
