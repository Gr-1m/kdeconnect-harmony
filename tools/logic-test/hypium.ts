// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 宿主侧 hypium 替身（**仅供 tools/arkts-logic-test.ps1 使用，不进 HAP**）。
//
// 目的：让**同一份** `*.test.ets` 既能在设备上跑（真 hypium/ohosTest），
// 又能在宿主用 Node 跑（本替身）⇒ 纯逻辑回归**不需要设备/模拟器**。
// 由脚本在做 .ets→.ts 复制时把 `from '@ohos/hypium'` 重写为 `from './hypium'`。
//
// 只实现本工程实际用到的断言子集（assertEqual/assertTrue/assertFalse）；
// 新增断言时在此补齐（否则逻辑层测试会在编译期报缺方法，不会静默跳过）。

// 宿主 Node 环境的 process（不引入 @types/node，保持零依赖）
declare const process: { exitCode?: number };

const cases: TestCase[] = [];
let currentGroup: string = '';

interface TestCase {
  name: string;
  fn: () => void;
}

export function describe(name: string, fn: () => void): void {
  currentGroup = name;
  fn();
}

export function it(name: string, filter: number, fn: () => void): void {
  cases.push({ name: `${currentGroup} / ${name}`, fn: fn });
}

class Expectation {
  private actual: unknown;

  constructor(actual: unknown) {
    this.actual = actual;
  }

  assertEqual(expected: unknown): void {
    if (this.actual !== expected) {
      throw new Error(`assertEqual failed: actual=${JSON.stringify(this.actual)} expected=${JSON.stringify(expected)}`);
    }
  }

  assertTrue(): void {
    if (this.actual !== true) {
      throw new Error(`assertTrue failed: actual=${JSON.stringify(this.actual)}`);
    }
  }

  assertFalse(): void {
    if (this.actual !== false) {
      throw new Error(`assertFalse failed: actual=${JSON.stringify(this.actual)}`);
    }
  }
}

export function expect(actual: unknown): Expectation {
  return new Expectation(actual);
}

export function runAll(): void {
  let pass: number = 0;
  const failures: string[] = [];
  for (const c of cases) {
    try {
      c.fn();
      pass++;
    } catch (e) {
      failures.push(`${c.name} :: ${e instanceof Error ? e.message : String(e)}`);
    }
  }
  console.log(`[logic-test] total=${cases.length} pass=${pass} fail=${failures.length}`);
  for (const f of failures) {
    console.log(`[logic-test]   FAIL ${f}`);
  }
  if (failures.length > 0) {
    process.exitCode = 1;
  }
}
