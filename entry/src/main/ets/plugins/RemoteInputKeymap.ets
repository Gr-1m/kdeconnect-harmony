// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 远程输入特殊键码表（阶段4 方向B / B1b；设计见
// devdocs/DESIGN_STAGE4_REMOTE_INPUT_deveco.md §1.3）。
//
// 跨端契约 = **下标语义**（各平台只换键码值，下标不变），照搬 KDE 桌面 `SpecialKeysMap`
// （`x11remoteinput.cpp:27`，原文见 AtomCode MSG134 §三.4）。
//
// 不变量：
//   ① **下标 0 无效**：桌面端校验 `specialKey > 0 && < size` ⇒ UI 不得发出 0；
//   ② 有效范围 = **1..32**（含）；超出即非法，UI 应禁用对应键而非发送；
//   ③ 本表是**唯一来源**（UI 与发送侧都查它，不各自硬编码）。
export const SPECIAL_KEY_INVALID: number = 0;

// index = specialKey 下标（0 起）；仅 1..32 有效
const SPECIAL_KEY_NAMES: string[] = [
  'Invalid',      // 0  —— 保留/无效
  'BackSpace',    // 1
  'Tab',          // 2
  'Linefeed',     // 3
  'Left',         // 4
  'Up',           // 5
  'Right',        // 6
  'Down',         // 7
  'PageUp',       // 8
  'PageDown',     // 9
  'Home',         // 10
  'End',          // 11
  'Return',       // 12
  'Delete',       // 13
  'Escape',       // 14
  'SysReq',       // 15
  'ScrollLock',   // 16
  'Ctrl',         // 17（左 Ctrl）
  'Alt',          // 18（左 Alt）
  'Shift',        // 19（左 Shift）
  'Super',        // 20（左 Super）
  'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'  // 21..32
];

// 合法范围上界（含）
export const SPECIAL_KEY_MAX: number = SPECIAL_KEY_NAMES.length - 1;  // 32

export function isValidSpecialKey(code: number): boolean {
  return code === Math.floor(code) && code > SPECIAL_KEY_INVALID && code <= SPECIAL_KEY_MAX;
}

// 展示名；非法下标返回空串（调用方据此禁用发送）
export function specialKeyName(code: number): string {
  return isValidSpecialKey(code) ? SPECIAL_KEY_NAMES[code] : '';
}

// 供 UI 遍历生成按键行（返回 1..32 的合法下标）
export function specialKeyCodes(): number[] {
  const out: number[] = [];
  for (let i = SPECIAL_KEY_INVALID + 1; i <= SPECIAL_KEY_MAX; i++) {
    out.push(i);
  }
  return out;
}
