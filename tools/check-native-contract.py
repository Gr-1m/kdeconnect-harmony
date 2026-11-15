#!/usr/bin/env python3
"""
Native 契约门禁 —— `Index.d.ts ↔ napi 导出` / `capabilities ↔ bootstrap caps`（MSG259 §3 · P1-2）

三组检查：

  A（阻塞）`entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts` 声明的导出
           ↔ `rust/full/napi/src/lib.rs` 的 `#[napi] pub fn`（snake_case → camelCase 后双向相等）。
           任一侧新增/改名而另一侧未跟 ⇒ 失败（今天即有效：两者都是**现行**桥面）。
  B（阻塞）`core/src/state.rs` 的 bootstrap caps（`caps_in` / `caps_out` 字面量）必须是
           `contract/capabilities.v1.json` 广告过的 packet type（∪ 协议层 `identity` / `pair`）。
  C（默认**仅报告**，`--c-blocking` 转阻塞）冻结契约 `contract/kcbridge.d.ts` 的 `KcApi` 方法集合
           ↔ `entry/src/main/ets/net/KcBridge.ets` 的 **static 方法**集合。
           阶段 A 两者均为 19 ⇒ 现在即可比对；CCR-3 生效（d.ts 增 8 方法 = 27）后，在阶段 B 把 8 个
           方法实装进 KcBridge 之前它会变红 —— 正是「C 组转阻塞」的时点（MSG264 §2.4）。
           默认非阻塞的原因：d.ts 是**目标** API，阶段过渡期红是预期，不应打断日常门禁。

用法：`python3 tools/check-native-contract.py [--c-blocking]`
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
KC_BRIDGE_ETS = REPO_ROOT / "entry/src/main/ets/net/KcBridge.ets"

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


def kcbridge_static_methods(text: str) -> set[str]:
    """`KcBridge.ets` 里的 `static name(` 方法名（阶段 A/B 的 native 适配层）。"""
    return set(re.findall(r"^\s*static\s+(?:async\s+)?([a-zA-Z_][a-zA-Z0-9_]*)\s*\(", text, re.M))


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
    c_blocking = "--c-blocking" in sys.argv[1:]
    die_missing([INDEX_DTS, NAPI_LIB, STATE_RS, CAPABILITIES, BRIDGE_DTS, KC_BRIDGE_ETS])
    index_text = INDEX_DTS.read_text(encoding="utf-8")
    napi_text = NAPI_LIB.read_text(encoding="utf-8")
    state_text = STATE_RS.read_text(encoding="utf-8")
    caps_text = CAPABILITIES.read_text(encoding="utf-8")
    bridge_text = BRIDGE_DTS.read_text(encoding="utf-8")
    kcbridge_text = KC_BRIDGE_ETS.read_text(encoding="utf-8")

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

    # ---- C. 冻结 KcApi ↔ KcBridge.ets（默认报告；--c-blocking 转阻塞） ----
    frozen = kcapi_methods(bridge_text)
    adapted = kcbridge_static_methods(kcbridge_text)
    missing_in_bridge = sorted(frozen - adapted)
    extra_in_bridge = sorted(adapted - frozen)
    c_ok = not missing_in_bridge and not extra_in_bridge
    if c_ok:
        print(f"PASS[C] 冻结 KcApi ↔ KcBridge.ets 一致（{len(frozen)} 项）")
    elif c_blocking:
        failed = True
        print("FAIL[C] 冻结 KcApi ↔ KcBridge.ets 不一致（--c-blocking）：")
        if missing_in_bridge:
            print(f"        KcBridge 未实装：{missing_in_bridge}")
        if extra_in_bridge:
            print(f"        KcBridge 多出（契约未登记）：{extra_in_bridge}")
    else:
        common = sorted(frozen & adapted)
        print(
            f"REPORT[C] 冻结 KcApi {len(frozen)} 项 vs KcBridge.ets {len(adapted)} 项"
            f"（交集 {len(common)}：{common}）"
        )
        print(
            f"          阶段 B 目标：KcBridge 由「旧导出转发」演进为「冻结 KcApi 全集」；"
            f"待实装 {len(missing_in_bridge)} 项、待退场 {len(extra_in_bridge)} 项"
            f"（非阻塞；阶段 B 完成后 run.sh 加 --c-blocking）"
        )
    if not frozen:
        print("FAIL[C]: KcApi 解析为空")
        failed = True

    if failed:
        print("native contract check: FAILED")
        return 1
    print("native contract check: PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
