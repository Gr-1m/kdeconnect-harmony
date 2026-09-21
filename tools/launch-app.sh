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

case "$MODE" in
  start)
    hdc shell "aa start -b $BUNDLE_NAME -a $MAIN_ABILITY"
    ;;
  stop)
    hdc shell "aa force-stop $BUNDLE_NAME"
    ;;
  restart)
    hdc shell "aa force-stop $BUNDLE_NAME"
    sleep 1
    hdc shell "aa start -b $BUNDLE_NAME -a $MAIN_ABILITY"
    ;;
  *)
    echo "用法: $0 [start|stop|restart]" >&2
    exit 2
    ;;
esac
