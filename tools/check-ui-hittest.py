#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 静态门禁：`HitTestMode.Block` 的使用规则（P1-3；源自 MSG245 真机事故）。
#
# 背景（ArkUI 语义）：`HitTestMode.Block` = 「本级响应命中、**屏蔽子节点**」。
#   * 若 Block 容器**自己没有** onClick ⇒ 点击无人接收（表现为「点了没反应」，MSG245 实机事故：
#     按钮组的容器写了 Block，而 onClick 挂在**子 Button** 上 ⇒ 全部按钮失效）。
#   * 因此规则 R1：**任何 `HitTestMode.Block` 所在组件块必须自带 `onClick`**（把点击放在容器上）。
#   * 规则 R2（告警、不判失败）：Block 附近出现 `Button(`/`Toggle(` ⇒ 提示复核（子控件可能被屏蔽）。
#
# 用法：`python3 tools/check-ui-hittest.py`（0 = 通过；1 = 违反 R1）

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCAN = ROOT / 'entry/src/main/ets'
BLOCK_RE = re.compile(r'\.hitTestBehavior\(\s*HitTestMode\.Block\s*\)')
# 组件块内「自带 onClick」的判定窗口（ArkTS 链式调用常在 hitTestBehavior 前后若干行内）
WINDOW = 18


def main() -> int:
    violations = []
    advisories = []
    scanned = 0
    for path in sorted(SCAN.rglob('*.ets')):
        scanned += 1
        rel = path.relative_to(ROOT).as_posix()
        lines = path.read_text(encoding='utf-8').splitlines()
        for idx, line in enumerate(lines):
            if not BLOCK_RE.search(line):
                continue
            lo = max(0, idx - WINDOW)
            hi = min(len(lines), idx + WINDOW + 1)
            window = '\n'.join(lines[lo:hi])
            if '.onClick(' not in window:
                violations.append(f'{rel}:{idx + 1}')
            if re.search(r'\b(Button|Toggle)\s*\(', window):
                advisories.append(f'{rel}:{idx + 1}')
    if violations:
        print('[FAIL] HitTestMode.Block 所在块缺少 onClick（点击会无人接收 ⇒ 表现为「点了没反应」）：')
        for v in violations:
            print(f'  - {v}')
        print('  修法：把 onClick 放到 Block 容器上（不要把 onClick 挂在被 Block 屏蔽的子控件上）。')
        return 1
    print(f'[PASS] HitTestMode.Block 用法合规（扫描 {scanned} 个 .ets；'
          f'告警 {len(advisories)} 处需人工复核）')
    for a in advisories:
        print(f'  [warn] Block 附近有 Button/Toggle，请确认它们不被屏蔽：{a}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
