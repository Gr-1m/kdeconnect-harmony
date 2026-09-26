// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 插件事件处理器（阶段 3 批次 3 步骤 7b；设计见 devdocs/PROJECT_ROADMAP.md）。
//
// 抽离方式：自 Index.ets 的 4 个插件事件处理方法原样搬出。
//   · 不持状态（batteryItems/runCommands 仍是页面 @State，经注入回调读写）；
//   · 用户可见副作用（toast/log）经注入回调走页面既有实现。

import { PluginEvent, BatteryPayload, RunOutputPayload } from '../plugins/PluginEvent';
import { RunCommandEntry } from '../plugins/RunCommandPlugin';
import { BatteryItem } from '../model/DeviceModels';

export class PluginEventHandlers {
  log: (m: string) => void = () => {};
  toast: (m: string) => void = () => {};
  resText: (resId: number) => string = () => '';
  commandsOf: (deviceId: string) => RunCommandEntry[] = () => [];
  setRunCommandState: (deviceId: string, commands: RunCommandEntry[]) => void = () => {};
  setBatteryItems: (items: BatteryItem[]) => void = () => {};
  getBatteryItems: () => BatteryItem[] = () => [];

  onRunCommandList(deviceId: string, ev: PluginEvent): void {
    const data: string = ev.text ?? '';
    this.setRunCommandState(deviceId, this.commandsOf(deviceId));
    this.log(`run command list <- ${deviceId} (${data})`);
  }

  onRunCommandOutput(deviceId: string, ev: PluginEvent): void {
    const ro: RunOutputPayload | undefined = ev.runOutput;
    if (ro === undefined) {
      return;
    }
    const ok: boolean = ro.success;
    const code: number = ro.exitCode;
    const text: string = ro.text;
    const head: string = this.resText(ok
      ? $r('app.string.toast_run_cmd_ok').id : $r('app.string.toast_run_cmd_failed').id);
    this.toast(text.length > 0 ? `${head} (exit=${code}): ${text}` : `${head} (exit=${code})`);
    this.log(`run command output <- ${deviceId}: success=${ok} exit=${code}`);
  }

  onClipboardRequest(deviceId: string, ev: PluginEvent): void {
    this.toast(this.resText($r('app.string.toast_clipboard_requested').id));
    this.log(`clipboard requested by ${deviceId}`);
  }

  onBattery(deviceId: string, ev: PluginEvent): void {
    const bp: BatteryPayload | undefined = ev.battery;
    if (bp === undefined) {
      return;
    }
    const charge: number = bp.charge;
    const charging: boolean = bp.charging;
    const text: string = `${charge}%${charging ? ' ⚡' : ''}`;
    const items: BatteryItem[] = this.getBatteryItems();
    const exists: boolean = items.some((b: BatteryItem) => b.deviceId === deviceId);
    const item: BatteryItem = { deviceId: deviceId, text: text };
    if (exists) {
      this.setBatteryItems(items.map((b: BatteryItem) => b.deviceId === deviceId ? item : b));
    } else {
      this.setBatteryItems(items.concat([item]));
    }
    this.log(`battery ${text} <- ${deviceId}`);
  }
}
