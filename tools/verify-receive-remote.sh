#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 真机接收链路复验（自动保存开/关两态 + 僵尸条目断言 + 重启场景）。
# 前置：Linux 侧可 `kdeconnect-cli --share`；Win10 SSH 通道可用（tools/win10-ssh.sh）。
#
# 用法：
#   tools/verify-receive-remote.sh                 # 全流程
#   tools/verify-receive-remote.sh --skip-build    # 跳过远程构建
#
# 断言（任一失败 → 退出码 1）：
#   A1 收到文件（dump 中出现测试文件名）
#   A2 无「0/X 文件 · 0%」与「接收中」并存的僵尸批次
#   A3 存在 100% 批次
#   A4 重启后（history 非空）再收文件，A1–A3 仍成立
#   A5 新 started 事件不得带 settled=true（id 撞号签名）
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HELPER="$ROOT/tools/win10-ssh.sh"
DEVICE_ID=${KDC_DEVICE_ID:-db67beed6ca949ccb380191f276470d9}
HAP=${KDC_HAP:-entry\\build\\default\\outputs\\default\\entry-default-signed.hap}
HDC_WIN='"C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0

step() { printf '\n=== %s ===\n' "$*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "PASS: $*"; }

skip_build=0
[ "${1:-}" = "--skip-build" ] && skip_build=1

pull_layout() { # $1 remote json name, $2 local path
  "$HELPER" shell "$HDC_WIN shell uitest dumpLayout -p /data/local/tmp/$1" >/dev/null 2>&1
  "$HELPER" shell "$HDC_WIN file recv /data/local/tmp/$1 C:\\\\Users\\\\xiaoyi\\\\$1" >/dev/null 2>&1
  "$HELPER" shell "type C:\\\\Users\\\\xiaoyi\\\\$1" 2>/dev/null > "$2"
}

# 取底部「文件」页签坐标（空=不在主页面）
tab_coords() {
  pull_layout "nav.json" "$TMP/nav.json"
  python3 - "$TMP/nav.json" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding='utf-8', errors='replace').read()
i = raw.find('{')
if i < 0:
    print(''); sys.exit(0)
d = json.loads(raw[i:])
nodes = []
def walk(n):
    a = n.get('attributes', {}) or {}
    nodes.append(a)
    for c in (n.get('children') or []): walk(c)
walk(d)
H = 0
try:
    b = (d.get('attributes', {}) or {}).get('bounds', '')
    if b:
        H = int(b.strip('[]').split(',')[3])
except Exception:
    H = 0
if H <= 0:  # root 无 bounds 时退回「所有节点 y2 最大值」
    for a in nodes:
        b = a.get('bounds', '')
        if b:
            try:
                H = max(H, int(b.strip('[]').split(',')[3]))
            except Exception:
                pass
best = None
for a in nodes:
    if (a.get('text') or '').strip() != '文件':
        continue
    b = a.get('bounds', '')
    try:
        x1, y1, x2, y2 = map(int, b.strip('[]').split(','))
    except Exception:
        continue
    if H > 0 and y1 > H * 0.7:
        if best is None or y1 > best[1]:
            best = (x1, y1, x2, y2)
print(f'{(best[0] + best[2]) // 2} {(best[1] + best[3]) // 2}' if best else '')
PY
}

# 切到「文件」页签；不在主页面（如停在设备详情/弹窗）时强制重启到主页面
goto_files_tab() {
  local coords attempt=0
  coords=$(tab_coords)
  while [ -z "$coords" ] && [ "$attempt" -lt 2 ]; do
    attempt=$((attempt + 1))
    echo "  不在主页面 → force-stop + start（第 $attempt 次；Back 会退出应用，不能用）"
    "$HELPER" shell "$HDC_WIN shell aa force-stop org.kde.kdeconnect" >/dev/null 2>&1
    sleep 2
    "$HELPER" shell "$HDC_WIN shell aa start -a EntryAbility -b org.kde.kdeconnect" >/dev/null 2>&1
    sleep 5
    coords=$(tab_coords)
  done
  if [ -n "$coords" ]; then
    echo "  切到文件页：click $coords"
    "$HELPER" shell "$HDC_WIN shell uitest uiInput click $coords" >/dev/null 2>&1
    sleep 1
  else
    echo "  WARN: 仍未找到「文件」页签（保持当前页）"
  fi
}

# 解析布局：打印批次相关文本；返回 0=含测试文件, 1=未见, 2=解析失败
analyze_layout() { # $1 local json
  python3 - "$1" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding='utf-8', errors='replace').read()
i = raw.find('{')
if i < 0:
    print('  <layout 未取到>'); sys.exit(2)
texts = []
def walk(n):
    a = n.get('attributes', {}) or {}
    t = (a.get('text') or '').strip()
    if t: texts.append(t)
    for c in (n.get('children') or []): walk(c)
walk(json.loads(raw[i:]))
print('  文本节点：')
for t in texts:
    if any(k in t for k in ['接收', '已保存', '已完成', '批次', '%', 'kdc-']):
        print('   ', repr(t))
has_file = any('kdc-verify' in t for t in texts)
zombie = any(('0/' in t and '0%' in t and '占总字节' in t) for t in texts) and any(t == '接收中' for t in texts)
done = any('100%' in t and '占总字节' in t for t in texts)
print(f'  [has_file={has_file} zombie={zombie} done100={done}]')
if zombie:
    print('  FAIL: 存在「0/X · 0%」+「接收中」僵尸批次')
if not done:
    print('  FAIL: 未见 100% 批次')
if not has_file:
    print('  FAIL: 未见测试文件条目（可能未收到/未刷新）')
sys.exit(0 if (has_file and not zombie and done) else 1)
PY
}

wait_and_assert() { # $1 tag, $2 local json path
  local tag=$1 local=$2 i ok=1
  goto_files_tab
  for i in 1 2 3 4 5 6; do
    pull_layout "layout-$tag.json" "$local"
    if analyze_layout "$local"; then ok=0; break; fi
    echo "  …第 $i 次未达预期，5s 后重试"
    sleep 5
  done
  [ "$ok" -eq 0 ] && pass "$tag 断言通过" || fail "$tag 断言未通过"
}

step "1/7 设备"
"$HELPER" devices | head -3 || { echo "FAIL: Win10 设备不可达"; exit 1; }

if [ "$skip_build" -eq 0 ]; then
  step "2/7 远程构建（Win10）"
  out=$("$HELPER" build 2>&1)
  echo "$out" | tail -3
  echo "$out" | grep -q "BUILD SUCCESSFUL" || { echo "FAIL: 构建失败"; exit 1; }
else
  step "2/7 构建（跳过）"
fi

step "3/7 安装 + 启动"
"$HELPER" install "$HAP" | tail -2
"$HELPER" shell "$HDC_WIN shell aa start -a EntryAbility -b org.kde.kdeconnect" | tail -1
sleep 5

step "4/7 造测试文件并发送（图片 + 二进制）"
python3 - "$TMP" <<'PY'
import struct, sys, zlib
d = sys.argv[1]
def chunk(t, b):
    return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
w = h = 8
raw = b''.join(b'\x00' + b'\xff\x00\x00' * w for _ in range(h))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
open(d + '/kdc-verify.png', 'wb').write(png)
open(d + '/kdc-verify.bin', 'wb').write(b'\x00\x01\x02' * 100000)
PY
for f in "$TMP/kdc-verify.png" "$TMP/kdc-verify.bin"; do
  echo "share: $(basename "$f")"
  kdeconnect-cli --share "$f" -d "$DEVICE_ID" 2>&1 | tail -1
  sleep 3
done

step "5/7 首轮断言（不重启）"
wait_and_assert first "$TMP/layout-first.json"

step "6/7 重启场景（history 非空后再收文件；MSG217 缺陷 A 回归）"
"$HELPER" shell "$HDC_WIN shell aa force-stop org.kde.kdeconnect" >/dev/null 2>&1
sleep 2
"$HELPER" shell "$HDC_WIN shell aa start -a EntryAbility -b org.kde.kdeconnect" | tail -1
sleep 6
for f in "$TMP/kdc-verify.png" "$TMP/kdc-verify.bin"; do
  echo "share(after restart): $(basename "$f")"
  kdeconnect-cli --share "$f" -d "$DEVICE_ID" 2>&1 | tail -1
  sleep 3
done
echo "等待 35s（覆盖 watchdog 30s）…"
sleep 35
wait_and_assert restart "$TMP/layout-restart.json"

step "7/7 日志（保存/失败路径 + settled 撞号签名）"
saved=$("$HELPER" log 'auto-save|saved\(|saved to album' 2>/dev/null | tail -8 || true)
echo "$saved"
echo "$saved" | grep -qE "auto-save|saved|album" && pass "出现自动保存/落盘日志" || fail "未出现任何保存日志"
sig=$("$HELPER" log 'KDC diag payload started' 2>/dev/null | tail -6 || true)
echo "$sig"
echo "$sig" | grep -q "settled=true" && fail "新 started 事件带 settled=true（id 撞号未修）" || pass "新 started 事件无 settled=true"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "=== 复验全部通过 ==="
  exit 0
else
  echo "=== 复验失败：$FAILS 项未通过 ==="
  exit 1
fi
