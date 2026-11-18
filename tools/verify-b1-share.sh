#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# verify-b1-share.sh —— B-1（kind 通道）与系统分享入口的**一键取证**脚本
#
# 背景：B-1 生产切换（`KcBridge.setDecodedListener`）与系统分享 S0（skills + getSharedData）
# 已入库，但真机冒烟一直缺设备。本脚本把「装包 → 冷启 → 抓日志 → 判定」固化成一条命令，
# 设备可用时直接跑，不需要再拼命令。
#
# 判定口径（任一 FAIL 即退出非 0）：
#   1) `net stack started` 出现           ⇒ native 起栈
#   2) `native event dropped:` **不出现**  ⇒ kind 解码零丢弃（B-1 全通）
#   3) `contract version: … ok=true`       ⇒ 契约版本一致（B-4）
#   4) `KDC-Share` 有 `share want received` ⇒ 分享入口被系统拉起（需用户此时从相册/文件管理器分享一次）
#
# 用法：
#   tools/verify-b1-share.sh              # 自动选通道：Win10（优先）或 本机 hdc
#   tools/verify-b1-share.sh --win10      # 强制 Win10（tools/win10-ssh.sh）
#   tools/verify-b1-share.sh --local      # 强制本机 hdc（tools/sign-debug.sh）
#   tools/verify-b1-share.sh --share-wait 60   # 启动后等待用户分享的秒数（默认 45）
#
# 说明：分享类判据（4）需要人在设备上操作一次分享；脚本会给出等待窗口并提示。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="auto"
SHARE_WAIT=45
HAP="entry/build/default/outputs/default/entry-default-signed.hap"
LOG="/tmp/verify-b1-share.log"

for arg in "$@"; do
  case "$arg" in
    --win10) MODE="win10" ;;
    --local) MODE="local" ;;
    --share-wait=*) SHARE_WAIT="${arg#*=}" ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

say() { echo "[verify-b1-share] $*"; }
die() { echo "[verify-b1-share] FAIL: $*" >&2; exit 1; }

# ---------- 通道选择 ----------
if [ "$MODE" = "auto" ]; then
  if timeout 40 bash tools/win10-ssh.sh devices 2>/dev/null | grep -qE '^[0-9A-Za-z]{8,}$'; then
    MODE="win10"
  elif timeout 15 hdc list targets 2>/dev/null | grep -qvE '^\[Empty\]$|^$'; then
    MODE="local"
  else
    die "无可用设备（Win10 hdc 与本机 hdc 都没有目标）"
  fi
fi
say "通道：$MODE"

if [ "$MODE" = "win10" ]; then
  say "构建（Win10 hvigorw）"
  timeout 900 bash tools/win10-ssh.sh build 2>&1 | tail -2 || die "Win10 构建失败"
  say "安装"
  timeout 180 bash tools/win10-ssh.sh install 'entry\build\default\outputs\default\entry-default-signed.hap' 2>&1 | tail -2 || die "安装失败"
  HDC='C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
  run_hdc() { timeout 90 bash tools/win10-ssh.sh shell "\"$HDC\" $1" 2>&1; }
  launch() { run_hdc "shell aa force-stop org.kde.kdeconnect" >/dev/null 2>&1 || true;
             run_hdc "shell aa start -a EntryAbility -b org.kde.kdeconnect"; }
  dump_log() { run_hdc "shell hilog -x > C:\\Users\\xiaoyi\\b1share.txt" >/dev/null 2>&1;
               timeout 90 bash tools/win10-ssh.sh shell 'type C:\Users\xiaoyi\b1share.txt' 2>/dev/null; }
else
  say "构建（本机 hvigorw）"
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$HOME/.local/share/ohos_libshim"
  timeout 900 hvigorw --no-daemon assembleHap 2>&1 | tail -2 || die "本机构建失败"
  say "签名 + 安装 + 启动"
  timeout 300 bash tools/sign-debug.sh 2>&1 | grep -E "install bundle successfully|ERROR" | tail -2 || die "签名/安装失败"
  launch() { timeout 60 bash tools/launch-app.sh restart 2>&1 | tail -1; }
  dump_log() { timeout 60 hdc shell hilog -x 2>/dev/null; }
fi

say "冷启应用"
launch || die "启动失败"
sleep 8

say "抓取日志（先给 ${SHARE_WAIT}s 窗口做一次分享；可 Ctrl-C 提前结束）"
sleep "$SHARE_WAIT"
dump_log > "$LOG" 2>/dev/null || true

# ---------- 判定 ----------
fail=0
check_present() {
  if grep -q "$2" "$LOG"; then
    printf '  [PASS] %s\n' "$1"
  else
    printf '  [FAIL] %s（日志未见 %s）\n' "$1" "$2"; fail=1
  fi
}
check_absent() {
  if grep -q "$2" "$LOG"; then
    printf '  [FAIL] %s（出现 %s）\n' "$1" "$2"; fail=1
  else
    printf '  [PASS] %s\n' "$1"
  fi
}

echo
echo "== 判定（日志：$LOG）=="
check_present "native 起栈"                "net stack started"
check_absent  "kind 解码零丢弃（B-1）"      "native event dropped:"
check_present "契约版本一致（B-4）"          "contract version:.*ok=true"
check_present "分享入口被拉起（S0/S7）"      "share want received"
echo
if [ "$fail" -ne 0 ]; then
  echo "== 关键日志片段 =="
  grep -E "KDC-Share|native event dropped|contract version|net stack started|KC_E" "$LOG" | tail -20 | sed 's/^/  /'
  die "存在未通过项（见上）"
fi
say "全部通过 ✅"
