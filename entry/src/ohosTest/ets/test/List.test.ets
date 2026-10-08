// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// ohosTest 用例汇总入口（每个 *.test.ets 导出 default function 并在此登记）。
import packetRouterTest from './PacketRouter.test';
import pluginRegistryTest from './PluginRegistry.test';

export default function testsuite(): void {
  packetRouterTest();
  pluginRegistryTest();
}
