// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 宿主侧纯逻辑测试入口（**仅供 tools/arkts-logic-test.ps1 使用，不进 HAP**）。
//
// 只登记「零 Kit 依赖」的套件 —— 依赖 `libkdeconnect_napi.so` / `@kit.*` 的套件
// （PacketRouter / DeviceController / PluginRegistry 的真插件部分）**不能**在此跑，
// 仍须走设备侧 hypium（ohemu / 真机）。
import './arkui-shim';   // 必须最先：置好 ArkUI 装饰器替身（见该文件头注释）
import { runAll } from './hypium';
import mousepadThrottleTest from './MousepadThrottle.test';
import mousepadInputTest from './MousepadInput.test';
import remoteInputKeymapTest from './RemoteInputKeymap.test';
import remoteInputPluginTest from './RemoteInputPlugin.test';

mousepadThrottleTest();
mousepadInputTest();
remoteInputKeymapTest();
remoteInputPluginTest();

runAll();
