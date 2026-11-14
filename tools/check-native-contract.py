#!/usr/bin/env python3
"""
Native 契约门禁 —— `Index.d.ts ↔ napi 导出` / `capabilities ↔ bootstrap caps`（MSG259 §3 · P1-2）

三组检查：

  A（阻塞）`entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts` 声明的导出
           ↔ `rust/full/napi/src/lib.rs` 的 `#[napi] pub fn`（snake_case → camelCase 后双向相等）。
           任一侧新增/改名而另一侧未跟 ⇒ 失败（今天即有效：两者都是**现行**桥面）。
  B（阻塞）`core/src/state.rs` 的 bootstrap caps（`caps_in` / `caps_out` 字面量）必须是
           `contract/capabilities.v1.json` 广告过的 packet type（∪ 协议层 `identity` / `pair`）。
  C（**仅报告**）冻结契约 `contract/kcbridge.d.ts` 的 `KcApi` 方法 ↔ 现行 napi 导出的差集。
           桥层阶段 A 落地前**故意不阻塞**：`kcbridge.d.ts` 是**目标** API（见 MSG259 §3①），
           今天断言「相等」必然为红；本项只打印差距，供阶段 A 排期参考。

用法：`python3 tools/check-native-contract.py`
退出码：0 全通过；1 任一**阻塞**检查失败；2 输入文件缺失（不得静默跳过）。
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
INDEX_DTS = REPO_ROOT / "entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts"
NAPI_LIB = REPO_ROOT / "entry/src/main/cpp/rust/full/napi/src/lib.rs"
STATE_RS = REPO_ROOT / "entry/src/main/cpp/rust/full/core/src/state.rs"
CAPABILITIES = REPO_ROOT / "contract/capabilities.v1.json"
BRIDGE_DTS = REPO_ROOT / "contract/kcbridge.d.ts"

# 协议层类型（非插件能力，恒广告）
PROTOCOL_TYPES = {"kdeconnect.identity", "kdeconnect.pair"}


def die_missing(paths: list[Path]) -> None:
    missing = [p for p in paths if not p.is_file()]
    if missing:
        for p in missing:
            print(f"FAIL: 输入文件缺失 → {p}")
        sys.exit(2)


def to_camel(snake: str) -> str:
    head, *rest = snake.split("_")
    return head + "".join(part[:1].upper() + part[1:] for part in rest)


def dts_exports(text: str) -> set[str]:
    """Index.d.ts 里的 `export const NAME` / `export function NAME`。"""
    return set(re.findall(r"^export\s+(?:const|function)\s+([A-Za-z_][A-Za-z0-9_]*)", text, re.M))


def napi_exports(text: str) -> set[str]:
    """`#[napi]`（可带参数，并可夹带其它属性）后面的 `pub fn NAME`；结构体的 `#[napi(object)]` 不计。"""
    pattern = re.compile(
        r"#\[napi(?:\([^)]*\))?\]\s*\n(?:\s*#\[[^\]]*\]\s*\n)*\s*pub\s+fn\s+([a-z_][a-z0-9_]*)"
    )
    return set(pattern.findall(text))


def kcapi_methods(text: str) -> set[str]:
    """`export interface KcApi { ... }` 块内的方法名。"""
    block = text.split("export interface KcApi", 1)
    if len(block) < 2:
        return set()
    body = block[1].split("\n}", 1)[0]
    out = set()
    for line in body.splitlines():
        stripped = line.strip()
        pos = stripped.find("(")
        if pos <= 0:
            continue
        name = stripped[:pos].strip()
        if name and all(c.isalnum() or c == "_" for c in name):
            out.add(name)
    return out


def state_bootstrap_caps(text: str) -> tuple[set[str], set[str]]:
    """`state.rs` 里 `caps_in` / `caps_out` 的字面量 packet type。"""

    def grab(field: str) -> set[str]:
        match = re.search(rf"{field}:\s*Mutex::new\(vec!\[(.*?)\]\)", text, re.S)
        if not match:
            return set()
        return set(re.findall(r'"([^"]+)"', match.group(1)))

    return grab("caps_in"), grab("caps_out")


def capability_types(text: str) -> set[str]:
    """`capabilities.v1.json` 的 incoming/outgoing 类型（不引入 json 依赖，正则足矣）。"""
    return set(re.findall(r'"(kdeconnect\.[A-Za-z0-9_.]+)"', text))


def main() -> int:
    die_missing([INDEX_DTS, NAPI_LIB, STATE_RS, CAPABILITIES, BRIDGE_DTS])
    index_text = INDEX_DTS.read_text(encoding="utf-8")
    napi_text = NAPI_LIB.read_text(encoding="utf-8")
    state_text = STATE_RS.read_text(encoding="utf-8")
    caps_text = CAPABILITIES.read_text(encoding="utf-8")
    bridge_text = BRIDGE_DTS.read_text(encoding="utf-8")

    failed = False

    # ---- A. Index.d.ts ↔ napi 导出 ----
    declared = dts_exports(index_text)
    implemented = {to_camel(name) for name in napi_exports(napi_text)}
    if not declared or not implemented:
        print("FAIL[A]: 解析结果为空（d.ts 或 napi 解析失败）")
        failed = True
    only_dts = sorted(declared - implemented)
    only_napi = sorted(implemented - declared)
    if only_dts or only_napi:
        failed = True
        print("FAIL[A] Index.d.ts ↔ napi 导出不一致：")
        if only_dts:
            print(f"        声明了但 napi 未导出：{only_dts}")
        if only_napi:
            print(f"        napi 导出了但 d.ts 未声明：{only_napi}")
    else:
        print(f"PASS[A] Index.d.ts ↔ napi 导出一致（{len(declared)} 个）")

    # ---- B. capabilities ↔ bootstrap caps ----
    advertised = capability_types(caps_text) | PROTOCOL_TYPES
    incoming, outgoing = state_bootstrap_caps(state_text)
    if not incoming or not outgoing:
        print("FAIL[B]: state.rs 的 caps_in/caps_out 解析为空")
        failed = True
    else:
        offenders = sorted((incoming | outgoing) - advertised)
        if offenders:
            failed = True
            print(f"FAIL[B] bootstrap caps 未被 capabilities.v1.json 广告：{offenders}")
        else:
            print(
                f"PASS[B] bootstrap caps ⊆ 能力契约（in={len(incoming)} out={len(outgoing)}）"
            )

    # ---- C. 冻结 KcApi ↔ 现行导出（仅报告） ----
    frozen = kcapi_methods(bridge_text)
    gap = sorted(frozen - implemented)
    print(
        f"REPORT[C] 冻结 KcApi {len(frozen)} 项 vs 现行 napi {len(implemented)} 项；"
        f"阶段 A 待落地 {len(gap)} 项（不阻塞）：{gap[:6]}{' …' if len(gap) > 6 else ''}"
    )

    if failed:
        print("native contract check: FAILED")
        return 1
    print("native contract check: PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
