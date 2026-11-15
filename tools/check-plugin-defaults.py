#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 静态门禁：ArkTS 侧 `defaultEnabled` 镜像（`common/PluginDefaults.ets`）必须与契约
# `contract/capabilities.v1.json` **逐项一致**（P1-3；防止契约改了插件开关默认值而 UI 悄悄失配）。
#
# 为什么需要：`defaultEnabled` 的运行时判定在 ArkTS（MSG264 §1 Q2 裁决：UI 默认开关，不做能力广告过滤），
# 而契约 JSON 不进 HAP ⇒ 两侧只能靠**门禁**锁死，否则就是新的漂移面。
#
# 用法：`python3 tools/check-plugin-defaults.py`（0 = 一致；1 = 漂移/解析失败）

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTRACT = ROOT / 'contract/capabilities.v1.json'
MIRROR = ROOT / 'entry/src/main/ets/common/PluginDefaults.ets'
# 匹配 `['ping', true],` 形式的表项
ENTRY_RE = re.compile(r"\[\s*'([a-z0-9_]+)'\s*,\s*(true|false)\s*\]")


def main() -> int:
    try:
        contract = json.loads(CONTRACT.read_text(encoding='utf-8'))
    except Exception as exc:  # noqa: BLE001
        print(f'[FAIL] 读契约失败 {CONTRACT}: {exc}')
        return 1
    src = MIRROR.read_text(encoding='utf-8')
    # 只看表体（`new Map<string, boolean>([ ... ])` 之内），避免误匹配注释里的例子
    start = src.find('new Map<string, boolean>(')
    end = src.find(']);', start)
    if start < 0 or end < 0:
        print('[FAIL] 未找到 PluginDefaults 表体（预期 `new Map<string, boolean>([...])`）')
        return 1
    mirror = {k: (v == 'true') for k, v in ENTRY_RE.findall(src[start:end])}
    expected = {p['key']: bool(p.get('defaultEnabled', False)) for p in contract.get('plugins', [])}

    problems = []
    for key, want in expected.items():
        if key not in mirror:
            problems.append(f'缺失: {key}（契约 {want}）')
        elif mirror[key] != want:
            problems.append(f'不一致: {key} 契约={want} 镜像={mirror[key]}')
    for key in mirror:
        if key not in expected:
            problems.append(f'多余: {key}（契约未登记）')
    if problems:
        print('[FAIL] PluginDefaults 与 contract/capabilities.v1.json 漂移：')
        for p in problems:
            print(f'  - {p}')
        print('  修法：同步 entry/src/main/ets/common/PluginDefaults.ets 的表项（本检查为门禁，不可静默跳过）。')
        return 1
    # PACKET_OWNERS：packet → 契约键（多所有者）也必须与契约一致
    pk_start = src.find('PACKET_OWNERS')
    pk_end = src.find(']);', pk_start)
    if pk_start < 0 or pk_end < 0:
        print('[FAIL] 未找到 PluginDefaults.PACKET_OWNERS 表')
        return 1
    body = src[pk_start:pk_end]
    mirror_pk = {}
    for pk, keys in re.findall(r"\['([a-z0-9_.]+)', \[([^\]]*)\]\]", body):
        mirror_pk[pk] = sorted(re.findall(r"'([a-z0-9_]+)'", keys))
    contract_pk = {}
    for plug in contract.get('plugins', []):
        for t in list(plug.get('incoming', [])) + list(plug.get('outgoing', [])):
            contract_pk.setdefault(t, [])
            if plug['key'] not in contract_pk[t]:
                contract_pk[t].append(plug['key'])
    for t in sorted(contract_pk):
        contract_pk[t] = sorted(contract_pk[t])
    pk_problems = []
    for t, keys in contract_pk.items():
        if mirror_pk.get(t) != keys:
            pk_problems.append(f'{t}: 契约={keys} 镜像={mirror_pk.get(t)}')
    for t in mirror_pk:
        if t not in contract_pk:
            pk_problems.append(f'多余 packet: {t}')
    if pk_problems:
        print('[FAIL] PACKET_OWNERS 与契约漂移：')
        for x in pk_problems:
            print(f'  - {x}')
        return 1

    off = sorted(k for k, v in expected.items() if not v)
    print(f'[PASS] defaultEnabled 镜像一致（{len(expected)} 项；默认关：{", ".join(off) or "无"}）'
          f'；PACKET_OWNERS 一致（{len(contract_pk)} 个 packet）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
