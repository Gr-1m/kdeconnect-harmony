#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 静态门禁：**ArkTS 侧只能有一个文件 import native**（`entry/src/main/ets/net/KcBridge.ets`）。
#
# 为什么（P0-4/P1-1 阶段 A；MSG262 §2 建议把分层守卫并入 tools/）：
#   · 参考库 `docs/kdeconnect-oh/06-coding-standards.md §4.1`：只有 `bridge/` 允许 import native；
#   · 直连 native 会让该文件的纯逻辑无法在宿主（bun）秒级回归，且 native 边界散落、改契约要全仓找。
#
# 用法：`python3 tools/check-native-import.py`（退出码 0 = 通过；1 = 有越界 import）
# 允许清单只有一条；新增例外必须在 `devdocs/MAP_KCApi_PHASEA_20261114.md` 写明理由并同时改本文件。

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCAN = ROOT / 'entry/src/main/ets'
ALLOWED = {'entry/src/main/ets/net/KcBridge.ets'}
# 只匹配真正的 import / from 语句（注释里提到模块名不算）
IMPORT_RE = re.compile(r"^\s*(?:import|export)\b[^\n]*\bfrom\s*['\"]libkdeconnect_napi\.so['\"]", re.M)
BARE_IMPORT_RE = re.compile(r"^\s*import\s*['\"]libkdeconnect_napi\.so['\"]", re.M)


def main() -> int:
    offenders = []
    scanned = 0
    for path in sorted(SCAN.rglob('*.ets')):
        scanned += 1
        rel = path.relative_to(ROOT).as_posix()
        text = path.read_text(encoding='utf-8')
        if IMPORT_RE.search(text) or BARE_IMPORT_RE.search(text):
            if rel not in ALLOWED:
                offenders.append(rel)
    allowed_hit = sorted(ALLOWED)
    if offenders:
        print('[FAIL] 除 KcBridge 外仍有文件 import native：')
        for f in offenders:
            print(f'  - {f}')
        print('  修法：改经 `net/KcBridge.ets`（阶段 A 同签名转发）；确需例外须写明理由并更新本脚本。')
        return 1
    print(f'[PASS] native import 边界 OK（扫描 {scanned} 个 .ets；唯一允许：{", ".join(allowed_hit)}）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
