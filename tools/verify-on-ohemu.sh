#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# verify-on-ohemu.sh —— 在 ohemu（OpenHarmony 模拟器）上跑通 UI 的**可重复**流程
#
# 背景（2026-09-23 实测）：工程现为 `runtimeOS: "HarmonyOS"`，而 ohemu 是 OpenHarmony 镜像 ⇒
#   Index.ets 顶部**静态导入** `@kit.UIDesignKit`（HDS：HdsTabs/hdsMaterial）会解析到 HMS 模块，
#   在 ohemu 上**模块加载即失败** ⇒ 白屏（app 进程在、原生栈不启动）：
#     E ArkCompiler: SyntaxError: '@hms:hds.hdsBaseComponent' does not provide an export name 'HdsTabsController'
#   静态导入无法运行期 catch，ArkTS 的 builder 也是编译期概念 ⇒ **无法做运行期降级**。
#   => 本脚本做**构建期降级**（临时、不提交）：把 HdsTabs 换成标准 Tabs、去掉 barFloatingStyle，
#      跑「构建 → 签名 → 安装 → 启动 → 截图 → 日志取证」，结束后可用 --revert 还原。
#
# 用法：
#   tools/verify-on-ohemu.sh            # 施加降级 → 构建/签名/安装/启动 → 截图 + 关键日志
#   tools/verify-on-ohemu.sh --revert   # 还原 Index.ets（等价 git checkout --）
#
# 前置：ohemu 已在跑且 `hdc list targets` 可见（见仓库根 AGENTS.md「模拟器调试」）。
# 注意：**降级状态不可提交**（CI/主线保留 HDS）；脚本结束时若仍处降级态会显式提醒。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
IDX="entry/src/main/ets/pages/Index.ets"
SHIM="$HOME/.local/share/ohos_libshim"

revert() {
  git checkout -- "$IDX" 2>/dev/null || true
  echo "[verify-on-ohemu] 已还原 $IDX"
}

if [ "${1:-}" = "--revert" ]; then
  revert
  exit 0
fi

if ! git diff --quiet -- "$IDX"; then
  echo "[verify-on-ohemu] ⚠️ $IDX 已有未提交改动 —— 先 commit/stash 再跑本脚本（避免混入你的改动）" >&2
  exit 1
fi

echo "[verify-on-ohemu] 施加构建期降级（HDS → 标准 Tabs）"
python3 - "$IDX" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text(encoding='utf-8')

stub = """// ⚠️ ohemu 验证用降级（tools/verify-on-ohemu.sh 施加，**勿提交**）：ohemu 是 OpenHarmony 镜像，
// 运行时无 HMS/HDS ⇒ 静态导入 @kit.UIDesignKit 会让 Index 模块加载失败（白屏）。此处以最小替身顶替。
class HdsTabsController {
  changeIndex(index: number): void {
  }
}"""

s = s.replace("import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';\n", "")
assert 'HdsTabs(' in s, '未找到 HdsTabs 用法'
s = s.replace("HdsTabs({ controller: this.tabsController }) {", "Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {", 1)
s2 = re.sub(r"\n *\.barFloatingStyle\(\{[\s\S]*?\n *\}\)", "", s, count=1)
assert s2 != s, '未找到 barFloatingStyle'
s = s2
# 替身类放到 import 区之后（ArkTS 不允许 import 出现在语句之后）
m = list(re.finditer(r'^import .*$', s, re.M))[-1]
s = s[:m.end()] + "\n\n" + stub + s[m.end():]
p.write_text(s, encoding='utf-8')
print("  已改为标准 Tabs（barFloatingStyle 已移除）")
PY

echo "[verify-on-ohemu] 构建 + 签名 + 安装"
LD_LIBRARY_PATH="$SHIM" hvigorw --no-daemon assembleHap >/dev/null
bash tools/sign-debug.sh 2>&1 | grep -E "install bundle successfully|ERROR" | tail -2

echo "[verify-on-ohemu] 启动 app"
bash tools/launch-app.sh restart 2>&1 | tail -2
sleep 10

echo "[verify-on-ohemu] 截图 + 日志取证"
hdc shell "snapshot_display -f /data/local/tmp/verify_shot.jpeg" >/dev/null 2>&1 || true
hdc file recv /data/local/tmp/verify_shot.jpeg /tmp/verify_shot.jpeg >/dev/null 2>&1 || true
echo "  截图: /tmp/verify_shot.jpeg"
echo "  --- 关键日志（HDS 报错应消失；应见原生栈启动）---"
hdc shell "hilog -x | grep -E 'SyntaxError|KDEConnect' | tail -8" 2>&1 | tail -8 | sed 's/^/  /'

echo
echo "[verify-on-ohemu] ⚠️ 当前工作区处于**降级态**（勿提交）。跑通后请执行：tools/verify-on-ohemu.sh --revert"
