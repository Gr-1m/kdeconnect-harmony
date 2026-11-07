#!/usr/bin/env bash
# 启动 / 停止 / 重启 app（配合 sign-debug.sh 用）
#
# 用法:
#   tools/launch-app.sh          # 启动 app
#   tools/launch-app.sh stop     # 停止 app
#   tools/launch-app.sh restart  # 重启 app（先 stop 再 start）
#
# 依赖: hdc 已连上设备

set -euo pipefail
MODE="${1:-start}"
BUNDLE_NAME="org.kde.kdeconnect"
MAIN_ABILITY="EntryAbility"
# 多设备同时在线时显式指定目标：HDC_TARGET=127.0.0.1:5559 tools/launch-app.sh
HDC_TARGET="${HDC_TARGET:-}"
HDC_OPTS=()
if [[ -n "$HDC_TARGET" ]]; then HDC_OPTS=(-t "$HDC_TARGET"); fi

case "$MODE" in
  start)
    hdc "${HDC_OPTS[@]}" shell "aa start -b $BUNDLE_NAME -a $MAIN_ABILITY"
    ;;
  stop)
    hdc "${HDC_OPTS[@]}" shell "aa force-stop $BUNDLE_NAME"
    ;;
  restart)
    hdc "${HDC_OPTS[@]}" shell "aa force-stop $BUNDLE_NAME"
    sleep 1
    hdc "${HDC_OPTS[@]}" shell "aa start -b $BUNDLE_NAME -a $MAIN_ABILITY"
    ;;
  *)
    echo "用法: $0 [start|stop|restart]" >&2
    exit 2
    ;;
esac
