// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// ohosTest 用例汇总入口（每个 *.test.ets 导出 default function 并在此登记）。
import packetRouterTest from './PacketRouter.test';
import pluginRegistryTest from './PluginRegistry.test';
import deviceControllerTest from './DeviceController.test';
import mousepadThrottleTest from './MousepadThrottle.test';
import mousepadInputTest from './MousepadInput.test';
import remoteInputKeymapTest from './RemoteInputKeymap.test';
import remoteInputPluginTest from './RemoteInputPlugin.test';

export default function testsuite(): void {
  packetRouterTest();
  pluginRegistryTest();
  deviceControllerTest();
  mousepadThrottleTest();
  mousepadInputTest();
  remoteInputKeymapTest();
  remoteInputPluginTest();
}
