#!/usr/bin/env bash
# 真机（HarmonyOS）诊断工具：读取 KDE Connect 构建信息 / 抓取「切后台断链」瞬间日志。
#
# 前置：手机以 USB(HDC 模式) 或无线连接，且 `hdc list targets` 能看到它。
#   USB 权限（Linux，需 root，一次性）：hdc 走 USB 需要能读写 /dev/bus/usb/... 节点。
#   注意：系统自带的 51-android.rules 只覆盖 ADB 接口，**不匹配 HDC 接口**，所以通常要自己加一条。
#   推荐（把设备交给当前用户所在的 uucp 组，比 0666 干净）：
#     echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="12d1", MODE="0660", GROUP="uucp"' | sudo tee /etc/udev/rules.d/51-harmony-hdc.rules
#     sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=usb
#   （12d1 = 华为；若已有等价规则可跳过。改完拔插一次 USB 或等 trigger 生效）
#   无 root 的替代方案：手机开发者选项里开「无线调试」，然后 hdc tconn <手机IP>:<端口>。
#
# 用法：
#   tools/phone-diag.sh targets            # 列出 hdc 目标（选真机序列号）
#   tools/phone-diag.sh info               # 包版本/安装时间/ABI/权限（判断手机上装的是哪个构建）
#   tools/phone-diag.sh state              # 当前进程 + 已连接设备（桌面侧另用 kdeconnect-cli -l）
#   tools/phone-diag.sh capture [秒数]     # 抓取日志到 /tmp/phone-<时间戳>.log，并打印汇总（默认 90 秒）
#
# 环境变量：TARGET=<序列号> 指定设备（多设备时必需）；BUNDLE 默认 org.kde.kdeconnect
set -uo pipefail
BUNDLE="${BUNDLE:-org.kde.kdeconnect}"
TARGET="${TARGET:-}"
D=""; [ -n "$TARGET" ] && D="-t $TARGET"
hd() { hdc $D shell "$@" 2>&1 | tr -d '\r'; }

case "${1:-}" in
  targets) exec hdc list targets -v ;;
  info)
    echo "=== 包信息 $BUNDLE（TARGET=${TARGET:-默认唯一设备}）==="
    hd "bm dump -n $BUNDLE" | grep -E '"(versionName|versionCode|minCompatibleVersionCode|installTime|updateTime|codePath|cpuAbi|apiReleaseType|debug|appDistributionType)"' | sed 's/^[[:space:]]*/  /'
    echo "=== 已声明权限 ==="; hd "bm dump -n $BUNDLE" | grep -A40 '"reqPermissionDetails"' | grep -E '"name"' | sed 's/^[[:space:]]*/  /' | head -20
    ;;
  state)
    echo "=== App 进程 ==="; hd "ps -ef | grep $BUNDLE | grep -v grep" | sed 's/^/  /'
    echo "=== 桌面侧（本机）==="; kdeconnect-cli -l 2>&1 | grep -iE "OpenHarmony|Mate|Harmony" | sed 's/^/  /'
    ;;
  capture)
    SEC="${2:-90}"; OUT="/tmp/phone-$(date +%Y%m%d-%H%M%S).log"
    echo "=== 抓取 ${SEC}s ⇒ $OUT ==="
    echo ">>> 现在请在手机上：① 打开 App 并连接桌面  ② 按 Home 切到后台  ③ 从桌面分享文件  ④ 等 30~60 秒 <<<"
    timeout "$SEC" hdc $D shell hilog -x > "$OUT" 2>&1
    echo "=== 汇总 ==="
    echo "-- 版本/进程 --"; hd "ps -ef | grep $BUNDLE | grep -v grep" | sed 's/^/  /'
    for pat in "native stop" "net stack stopped" "native start" "net stack started" "KDC-PAYLOAD" "Disconnected" "sysfreeze" "appfreeze" "LIFECYCLE_TIMEOUT"; do
      n=$(grep -c -- "$pat" "$OUT" 2>/dev/null || true)
      printf '  %-22s %s\n' "$pat" "${n:-0}"
    done
    echo "-- 关键行（时间序）--"
    grep -E "native stop|net stack stopped|sysfreeze|appfreeze|LIFECYCLE_TIMEOUT|KDC-PAYLOAD|Disconnected" "$OUT" | tail -20 | sed 's/^/  /'
    echo "（完整日志：$OUT）"
    ;;
  *) sed -n '1,30p' "$0"; exit 2 ;;
esac
