#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 静态门禁（B-1）：两处 ArkTS 镜像必须与 native 契约一致 ——
#   ① `contract/kcbridge.d.ts` 的 `EventKind`（18 项）↔ `common/EventKind.ets` 的 `EVENT_KIND_NAMES`
#   ② `Index.d.ts` 的 `NetEventBase` 字段 ↔ `common/EventShapes.ets` 的镜像（字段级存在性）
# 漂移即失败（不得静默跳过）：契约改 kind/字段而桥层未跟进 ⇒ 事件会被误导或被丢弃。
#
# 用法：`python3 tools/check-event-kinds.py`（0 = 一致；1 = 漂移/解析失败）

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DTS = ROOT / 'contract/kcbridge.d.ts'
INDEX_DTS = ROOT / 'entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts'
KIND_ETS = ROOT / 'entry/src/main/ets/common/EventKind.ets'
SHAPES_ETS = ROOT / 'entry/src/main/ets/common/EventShapes.ets'


def main() -> int:
    problems = []
    dts = DTS.read_text(encoding='utf-8')
    block = re.search(r'export const EventKind: \{(.*?)\};', dts, re.S)
    if block is None:
        print('[FAIL] 未在 contract/kcbridge.d.ts 找到 EventKind 声明')
        return 1
    contract = {int(n): name for name, n in re.findall(r'readonly (\w+):\s*(\d+);', block.group(1))}
    kind_src = KIND_ETS.read_text(encoding='utf-8')
    body = kind_src[kind_src.find('EVENT_KIND_NAMES'):kind_src.find(']);', kind_src.find('EVENT_KIND_NAMES'))]
    mirror = {int(n): name for n, name in re.findall(r'\[(\d+),\s*\'([A-Za-z]+)\'\]', body)}
    if contract != mirror:
        for k in sorted(set(contract) | set(mirror)):
            if contract.get(k) != mirror.get(k):
                problems.append(f'kind {k}: 契约={contract.get(k)} 镜像={mirror.get(k)}')

    idx = INDEX_DTS.read_text(encoding='utf-8')
    nb = re.search(r'export interface NetEventBase \{(.*?)\n\}', idx, re.S)
    if nb is None:
        print('[FAIL] 未在 Index.d.ts 找到 NetEventBase')
        return 1
    fields = re.findall(r'^\s{2}(\w+)\??:', nb.group(1), re.M)
    shapes = SHAPES_ETS.read_text(encoding='utf-8')
    missing = [f for f in fields if not re.search(r'^\s{2}' + f + r'\??:', shapes, re.M)]
    if missing:
        problems.append('EventShapes.ets 缺字段: ' + ', '.join(missing))

    if problems:
        print('[FAIL] 事件形状/kind 镜像与契约漂移：')
        for p in problems:
            print(f'  - {p}')
        print('  修法：同步 common/EventKind.ets 的 EVENT_KIND_NAMES 与 common/EventShapes.ets 的字段。')
        return 1
    print(f'[PASS] EventKind 镜像一致（{len(contract)} 项）且 NetEvent 字段镜像完整（{len(fields)} 字段）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
