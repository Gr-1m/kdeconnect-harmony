#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# verify-on-ohemu.sh —— 在 ohemu（OpenHarmony 模拟器）上跑通 UI 的**可重复**流程
#
# 背景（2026-10-12）：设备页已增加 HdsNavigation（标题栏滚动模糊），未来 0.8.2
# 还会接入 HdsSideBar。ohemu 没有 HMS/HDS 运行时，因此降级必须覆盖现有 HdsNavigation；
# HdsSideBar 目前尚未进入主线，若未来出现则脚本会明确拒绝继续，避免静默白屏，待补充
# 对应的标准 SideBarContainer 构建期替换。
# => 本脚本做**构建期降级**（临时、不提交）：HdsTabs → Tabs、HdsNavigation → Column，
#    去掉 HDS 专属修饰器；HdsSideBar 当前按“未使用透传”处理。
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

echo "[verify-on-ohemu] 施加构建期降级（HDS → 标准 ArkUI）"
python3 - "$IDX" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text(encoding='utf-8')

def remove_call(text: str, name: str) -> tuple[str, bool]:
    """Remove chained .name(...) calls while respecting nested parentheses."""
    needle = '.' + name + '('
    changed = False
    while needle in text:
        start = text.index(needle)
        pos = start + len(needle)
        depth = 1
        quote = None
        escaped = False
        while pos < len(text) and depth:
            ch = text[pos]
            if quote:
                if escaped:
                    escaped = False
                elif ch == '\\':
                    escaped = True
                elif ch == quote:
                    quote = None
            elif ch in ('"', "'"):
                quote = ch
            elif ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
            pos += 1
        if depth:
            raise SystemExit(f'未闭合 .{name}(...)')
        text = text[:start] + text[pos:]
        changed = True
    return text, changed

# HDS imports are static; remove the complete UIDesignKit import line during
# the temporary source rewrite. Standard ArkUI globals remain available.
s, import_removed = re.subn(r"^import \{[^\n]*\} from '@kit\.UIDesignKit';\n", "", s, flags=re.M)
if not import_removed:
    raise SystemExit('未找到 UIDesignKit import')

if 'HdsSideBar' in s or 'HdsSideMenu' in s:
    raise SystemExit('当前源码已使用 HdsSideBar/HdsSideMenu；ohemu 降级尚未实现，请勿运行，避免白屏')

assert 'HdsTabs(' in s, '未找到 HdsTabs 用法'
s = s.replace("HdsTabs({ controller: this.tabsController }) {", "Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {", 1)
s, removed = remove_call(s, 'barFloatingStyle')
if not removed:
    raise SystemExit('未找到 barFloatingStyle')

# HdsNavigation's builder body maps to a plain Column in the OpenHarmony smoke
# build. Strip its HDS-only modifiers using balanced-parenthesis parsing.
if 'HdsNavigation() {' in s:
    s = s.replace('HdsNavigation() {', 'Column() {')
else:
    raise SystemExit('未找到 HdsNavigation() builder')
for method in ('titleMode', 'hideBackButton', 'bindToScrollable', 'titleBar'):
    s, _ = remove_call(s, method)

# Drop HDS-only configuration helpers. Their only consumers were the HdsNavigation
# titleBar, removed above. Keep an ordinary controller stub for tab switching.
def remove_block(text: str, signature: str) -> str:
    start = text.find(signature)
    if start < 0:
        raise SystemExit(f'未找到待降级方法: {signature}')
    brace = text.find('{', start)
    if brace < 0:
        raise SystemExit(f'方法缺少 body: {signature}')
    depth = 0
    quote = None
    escaped = False
    pos = brace
    while pos < len(text):
        ch = text[pos]
        if quote:
            if escaped:
                escaped = False
            elif ch == '\\':
                escaped = True
            elif ch == quote:
                quote = None
        elif ch in ('"', "'", '`'):
            quote = ch
        elif ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return text[:start] + text[pos + 1:]
        pos += 1
    raise SystemExit(f'未闭合方法体: {signature}')

s = remove_block(s, 'private titleBarMenuOptions():')
s = remove_block(s, 'private titleBarOptions():')
s = s.replace('HdsTabsController', 'OhemuTabsController')
stub = "\nclass OhemuTabsController {\n  changeIndex(_index: number): void {\n  }\n}\n"
last_import = list(re.finditer(r'^import .*$', s, re.M))[-1]
s = s[:last_import.end()] + stub + s[last_import.end():]

# Fail closed on actual HDS code references; ignore comments and quoted strings.
code = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', ' ', s)
for symbol in ('HdsNavigation', 'HdsTabs', 'HdsSideBar', 'HdsSideMenu', 'HdsNavigationTitleMode',
               'ScrollEffectType', 'HdsNavigationMenuContentOptions', 'HdsNavigationMenuItemOptions',
               'HdsNavigationTitleBarOptions', 'HdsTabsController', 'hdsMaterial'):
    if re.search(r'\b' + symbol + r'\b', code):
        raise SystemExit(f'HDS symbol remains after downgrade: {symbol}; update the downgrade before using ohemu')

p.write_text(s, encoding='utf-8')
print("  已改为标准 Tabs/Column（HDS imports、组件、配置方法和类型均已降级）")
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
