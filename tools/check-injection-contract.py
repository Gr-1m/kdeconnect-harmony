#!/usr/bin/env python3
"""
装配契约完整性检查 — 阶段 3 批次 4 装配自检（AtomCode MSG119 建议2）

解析 DeviceController.ets / DeviceActionController.ets 的注入回调声明，
然后检查 Index.ets 中是否有对应的装配语句（`this.xxxController.fieldName =`）。
任何声明但未装配的字段 → 退出码 1 + 报告。

用法：python3 tools/check-injection-contract.py
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CONTROLLERS = [
    ("DeviceController", REPO_ROOT / "entry/src/main/ets/state/DeviceController.ets"),
    ("DeviceActionController", REPO_ROOT / "entry/src/main/ets/state/DeviceActionController.ets"),
]
INDEX_ETS = REPO_ROOT / "entry/src/main/ets/pages/Index.ets"


def extract_injection_fields(controller_path: Path) -> list[str]:
    """提取 controller 文件中所有注入回调字段名（形如 `fieldName: (...) => ... = ...;` 的行）。"""
    text = controller_path.read_text(encoding="utf-8")
    fields = []
    for m in re.finditer(
        r'^\s+(\w+)\s*:\s*\([^)]*\)\s*=>\s*[^=]+=\s*[^;]+;',
        text,
        re.MULTILINE,
    ):
        name = m.group(1)
        if name.startswith("_"):
            continue
        fields.append(name)
    return fields


def check_assembly(index_path: Path, controller_var: str, fields: list[str]) -> list[str]:
    """检查 Index.ets 中是否有 `this.<controller_var>.<field> =` 装配语句。返回缺失字段列表。"""
    text = index_path.read_text(encoding="utf-8")
    missing = []
    for f in fields:
        pattern = rf'this\.{controller_var}\.{f}\s*='
        if not re.search(pattern, text):
            missing.append(f)
    return missing


def main() -> int:
    all_ok = True
    for ctrl_name, ctrl_path in CONTROLLERS:
        if not ctrl_path.exists():
            print(f"ERROR: controller file not found: {ctrl_path}")
            all_ok = False
            continue
        fields = extract_injection_fields(ctrl_path)
        print(f"\n{ctrl_name} ({ctrl_path.name}): {len(fields)} injection fields declared")

        var_name = "deviceController" if ctrl_name == "DeviceController" else "actionController"
        missing = check_assembly(INDEX_ETS, var_name, fields)

        if missing:
            print(f"  MISSING ({len(missing)}): {', '.join(missing)}")
            all_ok = False
        else:
            print(f"  OK: all {len(fields)} fields assembled in Index.ets")

    if not all_ok:
        print("\nFAIL: injection contract check failed")
        return 1
    print("\nPASS: injection contract check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
