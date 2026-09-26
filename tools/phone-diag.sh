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
#   tools/phone-diag.sh verdict <log> [desk]# 按 RUNBOOK §4 自动判决 PASS/FAIL
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
  verdict)
    # 用法: phone-diag.sh verdict <hilog文件> [桌面状态文件]
    # 按 devdocs/RUNBOOK_KI1_REAL_DEVICE.md §4 的判据自动给出 PASS/FAIL。
    LOG="${2:-}"; DESK="${3:-}"
    [ -n "$LOG" ] && [ -f "$LOG" ] || { echo "用法: $0 verdict <hilog文件> [桌面状态文件]" >&2; exit 2; }
    p=0; f=0
    echo "=== KI-1 真机验收自动判决 ==="
    # 1 短时任务是否申请到
    n=$(grep -c "transient task id=" "$LOG" 2>/dev/null || true)
    if [ "${n:-0}" -gt 0 ]; then echo "  [PASS] 1 短时任务已申请（$n 次命中）"; p=$((p+1));
    else echo "  [FAIL] 1 未发现 'transient task id=' ⇒ 钩子没跑到或构建不含修复"; f=$((f+1)); fi
    # 2 传输结果
    ok=$(grep -c "KDC-PAYLOAD.*state=finished" "$LOG" 2>/dev/null || true); bad=$(grep -c "KDC-PAYLOAD.*state=failed" "$LOG" 2>/dev/null || true)
    if [ "${ok:-0}" -gt 0 ] && [ "${bad:-0}" -eq 0 ]; then echo "  [PASS] 2 载荷 finished（failed=0）"; p=$((p+1));
    else echo "  [FAIL] 2 载荷未成功（finished=$ok failed=$bad）—— 典型 code=110 payload handshake/accept timeout"; f=$((f+1)); fi
    # 3 桌面侧 reachable 是否持续
    if [ -n "$DESK" ] && [ -f "$DESK" ]; then
      saw=$(grep -c "reachable" "$DESK" 2>/dev/null || true); lst=$(awk -F'|' '{s=$0; sub(/^[0-9:]+ \| /,"",s); if (s!=p) p=s} END{print p}' "$DESK" 2>/dev/null)
      if [ "${saw:-0}" -gt 0 ] && echo "$lst" | grep -q "reachable"; then echo "  [PASS] 3 桌面侧全程保持 reachable"; p=$((p+1));
      else echo "  [FAIL] 3 桌面侧失去 reachable（命中 $saw 次；末态: $(echo "$lst" | grep -o 'Mate[^|]*' | head -c 60)）"; f=$((f+1)); fi
    else echo "  [SKIP] 3 未提供桌面状态文件（capture 会生成 <log>.desktop）"; fi
    # 4 遥测连续性：既看相邻间隔，也看「采集仍在继续而 App 已静默」（这才是冻结的真正信号）
    gap=$(grep "KDC-NETLOOP" "$LOG" 2>/dev/null | awk '{print $2}' | awk -F: '{s=$3; sub(/\..*/,"",s); print $1*3600+$2*60+s}' | awk 'NR>1 && $1-p>mx {mx=$1-p} {p=$1} END{print int(mx+0)}')
    tosec='function t(x,p){split(x,p,":"); n=p[3]; sub(/\..*/,"",n); return p[1]*3600+p[2]*60+n}'
    lastapp=$(grep "KDEConnect" "$LOG" 2>/dev/null | awk '{print $2}' | grep -E '^[0-9]+:[0-9]+:[0-9]+' | sort | tail -1)
    lastany=$(awk -v _=1 'NF>2 && $2 ~ /^[0-9]+:[0-9]+:[0-9]+/ {print $2}' "$LOG" 2>/dev/null | sort | tail -1)
    sil=0
    if [ -n "$lastapp" ] && [ -n "$lastany" ]; then
      sil=$(awk -v a="$lastapp" -v b="$lastany" "$tosec BEGIN{print t(b)-t(a)}" 2>/dev/null)
    fi
    if awk -v g="${gap:-0}" 'BEGIN{exit !(g<=15)}' && awk -v s="${sil:-0}" 'BEGIN{exit !(s<=30)}'; then
      echo "  [PASS] 4 遥测连续（最大间隔 ${gap}s，采集结束前静默 ${sil}s）"; p=$((p+1));
    else
      echo "  [FAIL] 4 遥测异常：最大间隔 ${gap}s，采集结束前 App 静默 ${sil}s（>30s 即被冻结）"; f=$((f+1));
    fi
    # 5 系统冻结事件
    fr=$(grep -c "OnAppFrozen" "$LOG" 2>/dev/null || true)
    if [ "${fr:-0}" -eq 0 ]; then echo "  [PASS] 5 无 OnAppFrozen（或不在链路存活期）"; p=$((p+1));
    else echo "  [FAIL] 5 出现 $fr 次 OnAppFrozen ⇒ 仍被系统冻结"; f=$((f+1)); fi
    # 6 配额/降级
    q=$(grep -cE "requestSuspendDelay failed|9900002|9900001" "$LOG" 2>/dev/null || true)
    [ "${q:-0}" -eq 0 ] && echo "  [ok]   6 无配额/短时任务校验失败" || echo "  [WARN] 6 出现 $q 条配额或校验失败"
    echo "=== 结论: PASS=$p FAIL=$f ==="
    [ "$f" -eq 0 ] && echo "  ⇒ KI-1 修复生效（真机）" || echo "  ⇒ 未通过：按 FAIL 项对照 RUNBOOK §4/§6 排查"
    ;;
  *) sed -n '1,34p' "$0"; exit 2 ;;
esac
