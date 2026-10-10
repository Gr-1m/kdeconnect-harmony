// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 宿主侧 ArkUI 装饰器替身（**仅供 tools/arkts-logic-test.ps1 使用，不进 HAP**）。
//
// 为何需要：纯逻辑模块的**类型依赖**可能牵入带 ArkUI 装饰器的 model 文件
// （如 `PluginEvent` → `SystemVolumeModels` 的 `@Observed`）。宿主 Node 里没有这些装饰器，
// 模块加载时会 ReferenceError ⇒ 这里把它们置为无副作用的 no-op。
//
// 注意：被装饰的类在宿主侧**失去可观测性**（这是合理的——本通道只验纯逻辑行为，
// 响应式刷新属 ArkUI 运行时职责，仍由设备侧 hypium + 真机验收覆盖）。
// 必须在其它模块之前被 import（见 tools/logic-test/run.ts 首行）。

declare global {
  var Observed: (target: unknown) => void;
  var ObservedV2: (target: unknown) => void;
  var ObservedObject: (target: unknown) => void;
}

globalThis.Observed = (): void => {
};
globalThis.ObservedV2 = (): void => {
};
globalThis.ObservedObject = (): void => {
};

export {};
