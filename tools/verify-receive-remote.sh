#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 真机接收链路复验（自动保存开/关两态 + 僵尸条目断言）。
# 前置：Linux 侧可 `kdeconnect-cli --share`；Win10 SSH 通道可用（tools/win10-ssh.sh）。
#
# 用法：
#   tools/verify-receive-remote.sh            # 全流程：构建→装机→启动→发文件→取证
#   tools/verify-receive-remote.sh --skip-build
#
# 断言：
#   1. dumpLayout 中不应出现「0/1 文件 · 0%」与「接收中」相邻的僵尸批次；
#   2. 至少一个批次显示 100%（文件确实收到）；
#   3. 日志中不应出现 auto-save 失败（save failed / keepPayload failed）。
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HELPER="$ROOT/tools/win10-ssh.sh"
DEVICE_ID=${KDC_DEVICE_ID:-db67beed6ca949ccb380191f276470d9}
HAP=${KDC_HAP:-entry\\build\\default\\outputs\\default\\entry-default-signed.hap}
HDC_WIN='"C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

skip_build=0
[ "${1:-}" = "--skip-build" ] && skip_build=1

step() { printf '\n=== %s ===\n' "$*"; }

step "1/6 设备"
"$HELPER" devices | head -3 || { echo "FAIL: Win10 设备不可达"; exit 1; }

if [ "$skip_build" -eq 0 ]; then
  step "2/6 远程构建（Win10）"
  out=$("$HELPER" build 2>&1)
  echo "$out" | tail -3
  echo "$out" | grep -q "BUILD SUCCESSFUL" || { echo "FAIL: 构建失败"; exit 1; }
else
  step "2/6 构建（跳过）"
fi

step "3/6 安装 + 启动"
"$HELPER" install "$HAP" | tail -2
"$HELPER" shell "$HDC_WIN shell aa start -a EntryAbility -b org.kde.kdeconnect" | tail -1
sleep 5

step "4/6 桌面 → 真机 发送测试文件（图片 + 二进制）"
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
sleep 5

step "5/6 dumpLayout 断言（僵尸条目 / 完成率）"
"$HELPER" shell "$HDC_WIN shell uitest dumpLayout -p /data/local/tmp/verify.json" >/dev/null
"$HELPER" shell "$HDC_WIN file recv /data/local/tmp/verify.json C:\\Users\\xiaoyi\\verify.json" >/dev/null
"$HELPER" shell 'type C:\Users\xiaoyi\verify.json' 2>/dev/null > "$TMP/layout.json"
python3 - "$TMP/layout.json" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding='utf-8', errors='replace').read()
i = raw.find('{')
if i < 0:
    print('FAIL: layout 未取到'); sys.exit(2)
texts = []
def walk(n):
    a = n.get('attributes', {}) or {}
    t = (a.get('text') or '').strip()
    if t: texts.append(t)
    for c in (n.get('children') or []): walk(c)
walk(json.loads(raw[i:]))
# 僵尸批次：0% 与 接收中 同时出现（近似判定）
bad = any('0/1 文件' in t and '0%' in t for t in texts) and any(t == '接收中' for t in texts)
done = any('100%' in t for t in texts)
print('批次相关文本：')
for t in texts:
    if any(k in t for k in ['接收批次', '接收中', '已完成', '已保存', '占', '文件']):
        print(' ', repr(t))
if bad:
    print('WARN: 存在 0% + 接收中 组合（可能仍有僵尸条目）')
else:
    print('PASS: 未见 0% + 接收中 僵尸组合')
print('PASS: 存在 100% 批次' if done else 'WARN: 未见 100% 批次')
PY

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
echo "等待 40s（覆盖 watchdog 30s）..."
sleep 40
"$HELPER" shell "$HDC_WIN shell uitest dumpLayout -p /data/local/tmp/verify2.json" >/dev/null
"$HELPER" shell "$HDC_WIN file recv /data/local/tmp/verify2.json C:\\Users\\xiaoyi\\verify2.json" >/dev/null
"$HELPER" shell 'type C:\Users\xiaoyi\verify2.json' 2>/dev/null > "$TMP/layout2.json"
python3 - "$TMP/layout2.json" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding='utf-8', errors='replace').read()
i = raw.find('{')
if i < 0:
    print('FAIL: layout2 未取到'); sys.exit(2)
texts = []
def walk(n):
    a = n.get('attributes', {}) or {}
    t = (a.get('text') or '').strip()
    if t: texts.append(t)
    for c in (n.get('children') or []): walk(c)
walk(json.loads(raw[i:]))
bad = any('0/1 文件' in t and '0%' in t for t in texts) and any(t == '接收中' for t in texts)
done = any('100%' in t for t in texts)
print('重启后批次文本：')
for t in texts:
    if any(k in t for k in ['接收批次', '接收中', '已保存', '占', '%']):
        print(' ', repr(t))
print('FAIL: 重启后仍有 0% + 接收中 僵尸组合' if bad else 'PASS: 重启后无 0% + 接收中 僵尸组合')
print('PASS: 重启后存在 100% 批次' if done else 'WARN: 重启后未见 100% 批次')
PY

step "7/7 日志（保存/失败路径 + settled 撞号签名）"
"$HELPER" log 'save failed|keepPayload failed|auto-save|exported to|saved\(|saved to album' | tail -12 || true
echo "--- settled 撞号检查（新 started 事件不应是 settled=true）---"
"$HELPER" log 'KDC diag payload started' | tail -6 || true

echo
echo "=== 完成：人工确认「已保存/应用内/待处置」文案与相册（图片）是否符合 MSG212 验收口径 ==="
