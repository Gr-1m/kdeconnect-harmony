// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 设备动作控制器（阶段 3 批次 4 步骤 8b；设计见 devdocs/PROJECT_ROADMAP.md）。
//
// 核心职责：卡片交互分发（onDeviceAction）+ 手动连接 + 设备动作执行。
//   · 不持状态（cardBusyKey/runCommands 等仍是页面 @State，经注入回调读写）；
//   · 用户可见副作用（toast/log）经注入回调走页面既有实现。

import { Context } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { DeviceItem } from '../model/DeviceModels';
import { PluginBase } from '../plugins/PluginBase';
import { ClipboardPlugin } from '../plugins/ClipboardPlugin';
import { PingPlugin } from '../plugins/PingPlugin';
import { RunCommandPlugin, RunCommandEntry } from '../plugins/RunCommandPlugin';
import { MprisPlugin } from '../plugins/MprisPlugin';
import { SendJob } from '../state/PayloadController';

const MAX_PICK_FILES: number = 9;

export class DeviceActionController {
  log: (m: string) => void = () => {};
  toast: (m: string) => void = () => {};
  resText: (resId: number) => string = () => '';
  actionGate: (key: string, windowMs: number) => boolean = () => true;
  pluginsFor: (deviceId: string) => PluginBase[] = () => [];
  commandsOf: (deviceId: string) => RunCommandEntry[] = () => [];
  switchTab: (index: number) => void = () => {};
  getSelectedDeviceId: () => string = () => '';
  getConnectedDevices: () => DeviceItem[] = () => [];
  getDeviceName: () => string = () => '';
  setCardBusy: (key: string) => void = () => {};
  clearCardBusy: (key: string) => void = () => {};
  setRunCommandState: (deviceId: string, commands: RunCommandEntry[], open: boolean) => void = () => {};
  openMprisDialog: (deviceId: string) => void = () => {};
  pairSessionStart: (deviceId: string, label: string, host: string, port: number) => void = () => {};
  getHostContext: () => Context | undefined = () => undefined;
  payloadEnqueueSend: (jobs: SendJob[], targetId: string) => void = () => {};
  setSelectedDeviceId: (id: string) => void = () => {};
  setDeviceSection: (section: number) => void = () => {};
  pruneActionGate: () => void = () => {};
  getMprisPluginOf: (deviceId: string) => MprisPlugin | undefined = () => undefined;

  onDeviceAction(key: string): void {
    if (key === 'send_file') {
      this.switchTab(1);
      return;
    }
    const id: string = this.getSelectedDeviceId();
    if (!this.actionGate(`act:${id}:${key}`, 300)) {
      this.log(`action ${key} throttled (rapid taps)`);
      return;
    }
    const list: PluginBase[] = this.pluginsFor(id);
    if (key === 'clipboard') {
      for (const p of list) {
        if (p instanceof ClipboardPlugin) {
          const ok: boolean = p.sendClipboard();
          this.toast(this.resText(ok
            ? $r('app.string.toast_clipboard_sent').id
            : $r('app.string.toast_clipboard_failed').id));
          return;
        }
      }
      this.toast(this.resText($r('app.string.toast_plugin_unavailable').id));
      return;
    }
    if (key === 'clipboard_request') {
      for (const p of list) {
        if (p instanceof ClipboardPlugin) {
          const ok: boolean = p.requestPeerClipboard();
          this.toast(this.resText(ok
            ? $r('app.string.toast_clipboard_request_sent').id
            : $r('app.string.toast_clipboard_failed').id));
          return;
        }
      }
      this.toast(this.resText($r('app.string.toast_plugin_unavailable').id));
      return;
    }
    if (key === 'find_device') {
      for (const p of list) {
        if (p instanceof PingPlugin) {
          const ok: boolean = p.sendPing(this.getDeviceName());
          this.toast(this.resText(ok
            ? $r('app.string.toast_find_device_sent').id
            : $r('app.string.toast_find_device_failed').id));
          return;
        }
      }
      this.toast(this.resText($r('app.string.toast_plugin_unavailable').id));
      return;
    }
    if (key === 'run_command') {
      this.setRunCommandState(id, this.commandsOf(id), true);
      this.log(`run command dialog: ${this.commandsOf(id).length} entries for ${id}`);
      this.clearCardBusy('run_command');
      return;
    }
    if (key === 'media') {
      if (!this.actionGate(`mpris-open:${id}`, 500)) {
        return;
      }
      const mp: MprisPlugin | undefined = this.getMprisPluginOf(id);
      if (mp === undefined) {
        this.toast(this.resText($r('app.string.toast_plugin_unavailable').id));
        this.log(`media panel unavailable for ${id} (MprisPlugin not loaded)`);
        return;
      }
      this.openMprisDialog(id);
      mp.requestPlayerList();
      mp.requestStatus();
      this.log(`media panel opened for ${id}`);
      this.clearCardBusy('media');
      return;
    }
    this.toastPlaceholder(key);
  }

  runCardAction(key: string): void {
    this.setCardBusy(key);
    this.onDeviceAction(key);
    if (key !== 'media' && key !== 'run_command') {
      this.clearCardBusy(key);
    }
  }

  manualConnect(host: string, port: number): void {
    if (host.trim().length === 0) {
      this.toast(this.resText($r('app.string.toast_manual_bad_host').id));
      this.log('manual connect rejected: empty host');
      return;
    }
    if (isNaN(port) || port < 1 || port > 65535) {
      this.toast(this.resText($r('app.string.toast_manual_bad_port').id));
      this.log(`manual connect rejected: invalid port ${port}`);
      return;
    }
    this.pairSessionStart('', `${host}:${port}`, host, port);
  }

  getRunCommandDeviceId: () => string = () => '';

  runCommand(key: string): void {
    const cmdDeviceId: string = this.getRunCommandDeviceId();
    const list: PluginBase[] = this.pluginsFor(cmdDeviceId);
    this.setRunCommandState('', [], false);
    for (const p of list) {
      if (p instanceof RunCommandPlugin) {
        const ok: boolean = p.run(key);
        this.toast(this.resText(ok
          ? $r('app.string.toast_run_cmd_sent').id
          : $r('app.string.toast_run_cmd_send_failed').id));
        return;
      }
    }
    this.toast(this.resText($r('app.string.toast_plugin_unavailable').id));
  }

  onClipboardPasteResult(granted: boolean): void {
    if (!granted) {
      this.log('paste button: temporary authorization failed');
      this.toast(this.resText($r('app.string.toast_clipboard_denied').id));
      return;
    }
    this.onDeviceAction('clipboard');
  }

  openDeviceDetail(d: DeviceItem): void {
    const online: boolean = this.getConnectedDevices().some((x: DeviceItem) => x.id === d.id);
    if (!online) {
      this.toast(this.resText($r('app.string.device_offline').id));
      return;
    }
    this.setSelectedDeviceId(d.id);
    this.pruneActionGate();
    this.setDeviceSection(0);
    this.log(`open device detail: ${d.id}`);
  }

  toastPlaceholder(key: string): void {
    const base: string = this.resText($r('app.string.toast_not_implemented').id);
    this.toast(`${base}: ${key}`);
  }

  sendTargetDevice(): DeviceItem | undefined {
    const id: string = this.getSelectedDeviceId();
    const connected: DeviceItem[] = this.getConnectedDevices();
    if (id.length > 0) {
      for (const d of connected) {
        if (d.id === id) {
          return d;
        }
      }
    }
    if (connected.length === 1) {
      return connected[0];
    }
    return undefined;
  }

  async pickAndSendFile(): Promise<void> {
    const connected: DeviceItem[] = this.getConnectedDevices();
    if (connected.length === 0) {
      this.log('send file: no connected device');
      return;
    }
    const target: DeviceItem | undefined = this.sendTargetDevice();
    if (target === undefined) {
      this.log(`send file: no unambiguous target (selected='${this.getSelectedDeviceId()}' connected=${connected.length})`);
      this.toast(this.resText($r('app.string.toast_send_no_target').id));
      return;
    }
    this.log(`send file target: ${target.name} (${target.id.substring(0, 8)})`);
    const hostCtx: Context | undefined = this.getHostContext();
    if (hostCtx === undefined) {
      this.log('send file: no host context');
      return;
    }
    let uris: string[] = [];
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(hostCtx);
      const options: picker.DocumentSelectOptions = { maxSelectNumber: MAX_PICK_FILES };
      uris = await docPicker.select(options);
    } catch (e) {
      this.log('send file: picker cancelled/failed');
      return;
    }
    if (uris.length === 0) {
      return;
    }
    const batchTs: number = Date.now();
    const jobs: SendJob[] = [];
    for (let i = 0; i < uris.length; i++) {
      const job: SendJob | undefined = this.stageSendJob(hostCtx, uris[i], batchTs, i);
      if (job !== undefined) {
        jobs.push(job);
      }
    }
    if (jobs.length === 0) {
      this.toast(this.resText($r('app.string.toast_send_file_failed').id));
      return;
    }
    this.payloadEnqueueSend(jobs, target.id);
  }

  private stageSendJob(ctx: Context, srcUri: string, batchTs: number, seq: number): SendJob | undefined {
    let fileName: string = srcUri.substring(srcUri.lastIndexOf('/') + 1);
    try {
      fileName = decodeURIComponent(fileName);
    } catch (e) {
    }
    const cachePath: string = `${ctx.cacheDir}/send_${batchTs}_${seq}_${fileName}`;
    let srcFd: fileIo.File | undefined = undefined;
    try {
      srcFd = fileIo.openSync(srcUri, fileIo.OpenMode.READ_ONLY);
      fileIo.copyFileSync(srcFd.fd, cachePath);
    } catch (e) {
      this.log(`send file: copy into sandbox failed (${fileName}): `
        + (e instanceof Error ? e.message : 'unknown'));
      return undefined;
    } finally {
      if (srcFd !== undefined) {
        try {
          fileIo.closeSync(srcFd);
        } catch (e) {
        }
      }
    }
    const job: SendJob = { cachePath: cachePath, fileName: fileName };
    return job;
  }
}
