#!/usr/bin/env bash
# 真机（HarmonyOS）诊断工具：读取 KDE Connect 构建信息 / 抓取「切后台断链」瞬间日志。
#
# 前置：手机以 USB(HDC 模式) 或无线连接，且 `hdc list targets` 能看到它。
#   ★ root 政策：本工具及使用它的人**不得**以任何方式（udev 规则 / chmod / sudoers / pkexec /
#     以 root 运行 hdc 等）获得持久的 root 级权限。凡是需要 root 的动作（下面那条 udev 规则、
#     读 faultlog 等）**一律交给用户本人执行**，把命令交给用户即可。
#   ★ 零 root 首选路径：手机开发者选项 →「无线调试」，然后 `hdc tconn <手机IP>:<端口>`。
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
BUNDLE="${BUNDLE:-}"
TARGET="${TARGET:-}"
# 未指定 TARGET 时自动选择：**排除本机模拟器 127.0.0.1:5555**，避免误对模拟器取证（真机才有效）。
if [ -z "$TARGET" ] && [ "${1:-}" != "targets" ]; then
  _t=$(hdc list targets 2>/dev/null | grep -v '^\[Empty\]$' | grep -v '^127\.0\.0\.1:5555$' | head -1)
  if [ -n "$_t" ]; then TARGET="$_t"; else
    echo "✗ 没有可用真机目标（只有模拟器或为空）。请接真机/无线调试，或用 TARGET=<序列号> 指定。" >&2
    echo "  当前 hdc list targets：$(hdc list targets 2>/dev/null | tr '\n' ' ')" >&2
    exit 3
  fi
fi
D=""; [ -n "$TARGET" ] && D="-t $TARGET"
echo "[目标设备] ${TARGET:-（唯一/默认）}" >&2
# 包名自动探测：2026-09-21 改名前后各一个（真机上可能是旧包名）
if [ -z "$BUNDLE" ]; then
  BUNDLE=$(hdc $D shell "bm dump -a" 2>/dev/null | tr -d '\r' | grep -i 'kdeconnect' | head -1 | tr -d ' \t')
  BUNDLE="${BUNDLE:-org.kde.kdeconnect}"
fi
echo "[包名] $BUNDLE" >&2
hd() { hdc $D shell "$@" 2>&1 | tr -d '\r'; }

case "${1:-}" in
  targets) exec hdc list targets -v ;;
  info)
    echo "=== 包信息 $BUNDLE（TARGET=${TARGET:-默认唯一设备}）==="
    hd "bm dump -n $BUNDLE" | grep -E '"(versionName|versionCode|minCompatibleVersionCode|installTime|updateTime|codePath|cpuAbi|apiReleaseType|debug|appDistributionType)"' | sed 's/^[[:space:]]*/  /'
    echo "=== 构建时间（native 库 mtime = 该包的实际构建时刻）==="
    hd "ls -l /data/app/el1/bundle/public/$BUNDLE/libs/arm64-v8a/ 2>/dev/null" | awk '{print "  "$NF"  "$6" "$7" "$8}' | grep -E '\.so' | head -5
    echo "=== 设备时间 / 时区 ==="; hd "date" | sed 's/^/  /'
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
    ( i=0; while [ $i -lt "$SEC" ]; do
        printf '%s | %s\n' "$(date +%H:%M:%S)" "$(kdeconnect-cli -l 2>/dev/null | grep -iE 'Mate|OpenHarmony|Harmony' | tr '\n' '|')"
        sleep 2; i=$((i+2))
      done ) > "$OUT.desktop" 2>&1 &
    # 注意：hilog 的 -x 是 --exit（读完缓冲即退出、不流式），必须用无参 hilog 才持续输出
    timeout "$SEC" hdc $D shell hilog > "$OUT" 2>&1
    wait
    echo "=== 汇总 ==="
    echo "-- 版本/进程 --"; hd "ps -ef | grep $BUNDLE | grep -v grep" | sed 's/^/  /'
    for pat in "native stop" "net stack stopped" "native start" "net stack started" "KDC-PAYLOAD" "Disconnected" "sysfreeze" "appfreeze" "LIFECYCLE_TIMEOUT"; do
      n=$(grep -c -- "$pat" "$OUT" 2>/dev/null || true)
      printf '  %-22s %s\n' "$pat" "${n:-0}"
    done
    echo "-- 桌面侧状态变化（每 2s；看掉线是瞬间还是 ~12s 后）--"
    awk -F'|' '{s=$0; sub(/^[0-9:]+ \| /,"",s); if (s!=p) {print "  "$0; p=s}}' "$OUT.desktop" 2>/dev/null | head -20
    echo "-- 关键行（时间序）--"
    grep -E "native stop|net stack stopped|sysfreeze|appfreeze|LIFECYCLE_TIMEOUT|KDC-PAYLOAD|Disconnected" "$OUT" | tail -20 | sed 's/^/  /'
    echo "（完整日志：$OUT）"
    ;;
  *) sed -n '1,30p' "$0"; exit 2 ;;
esac
