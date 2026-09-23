// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import { PluginBase } from './PluginBase';

// 远程输入插件（kdeconnect.mousepad.request / .keyboardstate）——P1 只声明能力（MSG112 §4）：
// 声明 caps 让电脑端显示 Controls 标签页；触控板/键盘 UI 属 P2。
export class RemoteInputPlugin extends PluginBase {
  constructor() {
    super();
    this.displayName = 'RemoteInput';
    this.description = 'Use this device as touchpad/keyboard for the peer';
    this.supportedPacketTypes = ['kdeconnect.mousepad.keyboardstate'];
    this.outgoingPacketTypes = ['kdeconnect.mousepad.request'];
  }

  onPacketReceived(packetType: string, body: Object): boolean {
    if (packetType !== 'kdeconnect.mousepad.keyboardstate') {
      return false;
    }
    this.log('mousepad keyboard state received (UI is P2)');
    return true;
  }
}
