#!/usr/bin/env bash
# 三实例一键冷启动：折叠 Spatialfoldable:5555 / 平板 SpatialPad:5557 / 手机 SpatialPhone:5559
#
# 用法:
#   tools/start-both.sh                              # 停旧实例 + 冷启动三实例 + 等就绪 + 画面自检
#   FOLD_ADDR=127.0.0.1:5561 tools/start-both.sh     # 自定义地址（同法 PAD_ADDR / PHONE_ADDR）
#
# 为什么必须冷启动（2026-10-24 实测，详见 devdocs/EMULATOR_NOTES.md）:
#   snapshot 热启动有两种故障:
#     ① guest hdcd 不向宿主 hdc server 注册（端口在 LISTEN 但 tconn 失败）
#     ② guest 显示损坏——窗口撕裂/颜色怪异、原生截图全黑（~26KB 纯色）
#   -bootMode coldboot 保用户数据，只是不走快照，两种故障都可避免。
#   devecocli emulator start 默认走 snapshot，勿用。
#
# 说明:
#   - 就绪判定: hdc list targets 出现地址 + hdc shell 应答，再留 UI 落定缓冲
#   - 模拟器日志: /tmp/emufold.log / /tmp/emupad.log / /tmp/emuphone.log（临时文件，丢了不影响）
#   - 画面自检: 就绪后各截一张，<80KB 判疑似全黑/花屏（10-24 事故特征 ≈26KB），
#     仅告警不判失败——阈值是启发式
#   - 启动完成后部署应用: tools/build-both.sh
#
set -euo pipefail

EMU_BIN="/opt/command-line-tools/emulator/Emulator"
[[ -x "$EMU_BIN" ]] || { echo "[FAIL] 找不到 $EMU_BIN（检查 command-line-tools 安装）"; exit 1; }

export PATH="/opt/command-line-tools/bin:$HOME/.local/bin:$PATH"

FOLD_ADDR="${FOLD_ADDR:-127.0.0.1:5555}"
PAD_ADDR="${PAD_ADDR:-127.0.0.1:5557}"
PHONE_ADDR="${PHONE_ADDR:-127.0.0.1:5559}"
BOOT_LOG_DIR="${BOOT_LOG_DIR:-/tmp}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-240}"
SHOT_DIR="$HOME/.local/share/verify-shots/sanity"

start_one() {
  local name="$1" inst="$2"
  echo "-- [$inst] 停在跑实例"
  devecocli emulator stop "$inst" >/dev/null 2>&1 || true
  pkill -f "Emulator -start $inst" 2>/dev/null || true
  sleep 2
  echo "-- [$inst] 冷启动（保数据）"
  setsid nohup "$EMU_BIN" -start "$inst" -bootMode coldboot \
    > "$BOOT_LOG_DIR/emu$name.log" 2>&1 < /dev/null &
  echo "   日志: $BOOT_LOG_DIR/emu$name.log"
}

wait_one() {
  local name="$1" addr="$2" waited=0
  echo "-- [$name] 等就绪（≤${WAIT_TIMEOUT}s，冷启动约 1~2 分钟）"
  while (( waited < WAIT_TIMEOUT )); do
    hdc tconn "$addr" >/dev/null 2>&1 || true
    if hdc list targets 2>/dev/null | grep -qF "$addr" \
       && hdc -t "$addr" shell echo ok >/dev/null 2>&1; then
      sleep 15   # UI 落定缓冲
      echo "   [OK] $name 就绪（$addr）"
      return 0
    fi
    sleep 5; waited=$((waited+5))
  done
  echo "   [FAIL] $name ${WAIT_TIMEOUT}s 未就绪，查日志: tail -40 $BOOT_LOG_DIR/emu$name.log"
  return 1
}

check_one() {
  local name="$1" inst="$2" f size
  "$EMU_BIN" -instance "$inst" -screenshot -screenshotPath "$SHOT_DIR/$inst" >/dev/null 2>&1 || true
  sleep 2
  f="$(ls -t "$SHOT_DIR/$inst"/Screenshot_*.png 2>/dev/null | head -1 || true)"
  if [[ -z "$f" ]]; then
    echo "   [WARN] $name 未能截图自检（不影响使用）"
    return 0
  fi
  size="$(stat -c%s "$f")"
  if (( size < 80000 )); then
    echo "   [WARN] $name guest 画面疑似异常（${size}B，参考 10-24 全黑 ≈26KB）: $f"
  else
    echo "   [OK] $name 画面正常（${size}B）: $f"
  fi
}

echo "== 1. 清理 hdc server（清陈旧注册）=="
hdc kill -r >/dev/null 2>&1 || true
sleep 2

echo "== 2. 冷启动三实例 =="
start_one "fold"  Spatialfoldable
start_one "pad"   SpatialPad
start_one "phone" SpatialPhone

echo "== 3. 等就绪 =="
fail=0
wait_one "fold"  "$FOLD_ADDR"  || fail=1
wait_one "pad"   "$PAD_ADDR"   || fail=1
wait_one "phone" "$PHONE_ADDR" || fail=1

echo "== 4. 画面自检 =="
mkdir -p "$SHOT_DIR/Spatialfoldable" "$SHOT_DIR/SpatialPad" "$SHOT_DIR/SpatialPhone"
check_one "fold"  Spatialfoldable
check_one "pad"   SpatialPad
check_one "phone" SpatialPhone

if (( fail )); then
  echo "[FAIL] 有实例未就绪，按上方提示查日志"
  exit 1
fi
echo "[OK] 三实例就绪：$FOLD_ADDR / $PAD_ADDR / $PHONE_ADDR —— 部署应用跑 tools/build-both.sh"
