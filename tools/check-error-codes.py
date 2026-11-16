#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 静态门禁：ArkTS 错误码镜像（`common/KcError.ets`）必须与契约 `contract/errors.v1.json` **逐项一致**
# （B-3；code/name/kind/disposition 四项都比）。契约改了码表而 UI/处置未同步 ⇒ 门禁失败。
#
# 用法：`python3 tools/check-error-codes.py`（0 = 一致；1 = 漂移/解析失败）

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTRACT = ROOT / 'contract/errors.v1.json'
MIRROR = ROOT / 'entry/src/main/ets/common/KcError.ets'
ENTRY_RE = re.compile(
    r"\[\s*(\d+)\s*,\s*\{\s*code:\s*(\d+),\s*name:\s*'([A-Z0-9_]+)',\s*"
    r"kind:\s*'([a-z]+)',\s*disposition:\s*'([A-Za-z]+)'\s*\}\]"
)


def main() -> int:
    try:
        contract = json.loads(CONTRACT.read_text(encoding='utf-8'))
    except Exception as exc:  # noqa: BLE001
        print(f'[FAIL] 读契约失败 {CONTRACT}: {exc}')
        return 1
    src = MIRROR.read_text(encoding='utf-8')
    start = src.find('new Map<number, KcErrorInfo>(')
    end = src.find(']);', start)
    if start < 0 or end < 0:
        print('[FAIL] 未找到 KcError 表体（预期 `new Map<number, KcErrorInfo>([...])`）')
        return 1
    mirror = {}
    for key, code, name, kind, disp in ENTRY_RE.findall(src[start:end]):
        mirror[int(key)] = {'code': int(code), 'name': name, 'kind': kind, 'disposition': disp}
    expected = {c['code']: c for c in contract.get('codes', [])}

    problems = []
    for code, want in expected.items():
        got = mirror.get(code)
        if got is None:
            problems.append(f'缺失码: {code}（{want["name"]}）')
            continue
        for field in ('name', 'kind', 'disposition'):
            if got[field] != want[field]:
                problems.append(f'{code} {field}: 契约={want[field]} 镜像={got[field]}')
        if got['code'] != code:
            problems.append(f'{code}: 表项 key 与 code 不一致（{got["code"]}）')
    for code in mirror:
        if code not in expected:
            problems.append(f'多余码: {code}')
    if problems:
        print('[FAIL] KcError 镜像与 contract/errors.v1.json 漂移：')
        for p in problems:
            print(f'  - {p}')
        print('  修法：同步 entry/src/main/ets/common/KcError.ets 的表项（本检查为门禁，不可静默跳过）。')
        return 1
    disp = {}
    for c in expected.values():
        disp[c['disposition']] = disp.get(c['disposition'], 0) + 1
    pretty = ', '.join(f'{k}={v}' for k, v in sorted(disp.items()))
    print(f'[PASS] KcError 镜像一致（{len(expected)} 码；{pretty}）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
