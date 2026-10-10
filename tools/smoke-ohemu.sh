#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# smoke-ohemu.sh —— ohemu 一键冒烟（把「反复手敲」的事固化）
#
# 做的事（每步都有断言，失败即非零退出）：
#   ① 确保模拟器在线（不在则按 EMULATOR_NOTES 的配方拉起并等 hdc 可连）
#   ② 构建 + 签名 + 装机 + 启动（复用 tools/verify-on-ohemu.sh：内含 HDS 降级，ohemu 必需）
#   ③ 断言：`install bundle successfully` / `start ability successfully` /
#      `plugin routes registered: 7` / `native start`
#   ④ 收尾：`--revert` 还原 Index.ets（降级态**不可提交**）
#   ⑤ 可选：`--with-tests` 追加 hypium/ohosTest 27 用例（见 EMULATOR_NOTES §9）
#
# 用法:
#   tools/smoke-ohemu.sh                # ①②③④
#   tools/smoke-ohemu.sh --with-tests   # ①②③④⑤
#
# 环境变量: OHEMU_DIR 模拟器目录（默认 ~/WorkSpace2/openharmony-qemu-x86_64-x86_64_virt-phone）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OHEMU_DIR="${OHEMU_DIR:-$HOME/WorkSpace2/openharmony-qemu-x86_64-x86_64_virt-phone}"
SHIM="${OHOS_LIBXML2_SHIM:-$HOME/.local/share/ohos_libshim}"
WITH_TESTS=0
[ "${1:-}" = "--with-tests" ] && WITH_TESTS=1

fail=0
step() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  [OK] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=$((fail + 1)); }
note() { printf '  · %s\n' "$*"; }

# —————— ① 模拟器在线 ——————
step "① 确保模拟器在线"
if hdc list targets 2>/dev/null | grep -q '127.0.0.1:5555'; then
    ok "模拟器已在线（127.0.0.1:5555）"
else
    note "未在线 ⇒ 拉起 $OHEMU_DIR/launch/linux.sh（约 85s）"
    ( cd "$OHEMU_DIR" && setsid nohup ./launch/linux.sh -r 720x1560 -m 8G -s 4 \
        > "$HOME/WorkSpace2/ohemu.log" 2>&1 < /dev/null & )
    for i in $(seq 1 30); do
        sleep 5
        if timeout 20 hdc tconn 127.0.0.1:5555 2>/dev/null | grep -qi 'ok'; then break; fi
    done
    if hdc list targets 2>/dev/null | grep -q '127.0.0.1:5555'; then
        ok "模拟器已拉起并可连"
    else
        bad "模拟器未能就绪（看 ~/WorkSpace2/ohemu.log）"
        note "中止：无设备无法继续"
        exit 1
    fi
fi

# —————— ② 构建/签名/装机/启动（复用 verify-on-ohemu.sh）——————
step "② 构建 + 签名 + 装机 + 启动（HDS 降级版，ohemu 必需）"
# 先清空 hilog 缓冲：断言只关心**本次**运行 ⇒ 观察窗口干净，不必再与历史陈迹/pid 变化缠斗
# （曾用 pid 作用域，但实测「当前实例未记标记行、历史实例的标记行留在缓冲里」⇒ 产生假失败）。
# 观察窗口锚点：记录**装机/启动之前**缓冲里最后一行的时刻；断言只接受晚于该时刻的行。
# 理由：`hilog -x` 是历史缓冲，直接 grep 会命中**上一次运行**留下的同文本（假通过）；
#       而 hilog 首列即 `MM-DD HH:MM:SS.mmm`，同一时钟下字符串比较即时间序 ⇒ 无需时钟同步。
WIN="$(timeout 40 hdc -t 127.0.0.1:5555 shell "hilog -x | tail -1" 2>/dev/null | tr -d '\r' | awk '{print $1" "$2}')"
note "观察窗口锚点（装机前缓冲末行时刻）: ${WIN:-<空>}"
LOG="$(mktemp /tmp/smoke-ohemu-XXXX.log)"
if LD_LIBRARY_PATH="$SHIM" timeout 1200 bash "$ROOT/tools/verify-on-ohemu.sh" > "$LOG" 2>&1; then
    ok "verify-on-ohemu.sh 退出 0（日志 $LOG）"
else
    bad "verify-on-ohemu.sh 非零退出（日志 $LOG）"
fi
grep -q 'install bundle successfully' "$LOG" && ok "装机成功" || bad "未见 install bundle successfully"
grep -q 'start ability successfully'  "$LOG" && ok "启动成功" || bad "未见 start ability successfully"

# —————— ③ 运行时断言 ——————
step "③ 运行时断言（hilog，最多等 60s；冷启动首启可能慢于固定 sleep）"
# 曾用「sleep 6 后单次取样」⇒ 冷启动必假失败（实测踩到）；改为轮询直到两个标记齐或超时。
HL="$(mktemp /tmp/smoke-hilog-XXXX.log)"
deadline=$(( $(date +%s) + 60 ))
seen_routes=0; seen_native=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    timeout 60 hdc -t 127.0.0.1:5555 shell "hilog -x" > "$HL" 2>&1
    if [ -n "$WIN" ]; then
        awk -v w="$WIN" '{ ts=$1" "$2; if (ts > w) print }' "$HL" > "$HL.win" 2>/dev/null || cp "$HL" "$HL.win"
    else
        cp "$HL" "$HL.win"
    fi
    grep -q 'plugin routes registered: 7' "$HL.win" && seen_routes=1
    grep -qE 'native start: deviceId'      "$HL.win" && seen_native=1
    if [ "$seen_routes" = 1 ] && [ "$seen_native" = 1 ]; then break; fi
    sleep 5
done
[ "$seen_routes" = 1 ] && ok "plugin routes registered: 7" || bad "60s 内未见 plugin routes registered: 7（窗口日志 $HL.win）"
[ "$seen_native" = 1 ] && ok "native start 已派发"          || bad "60s 内未见 native start（窗口日志 $HL.win）"
# 只认 HDS 专属签名：`hilog -x` 是**历史缓冲**，泛匹配 `SyntaxError` 会命中早前运行/其他模块的陈迹
# （实测踩到：降级生效、app 正常，却因缓冲里旧行为而误报）。
if grep -qiE 'hdsBaseComponent|@hms:hds' "$HL.win"; then
    bad "出现 HDS 模块加载失败签名（多为 HDS 未降级）"
else
    ok "无 HDS 模块加载失败签名"
fi

# —————— ④ 还原降级 ——————
# 守卫：检查工作区是否有未提交改动（DevEco MSG138 §4.1 建议，避免静默销毁）
if [ -n "$( cd "$ROOT" && git status --porcelain )" ]; then
    note "工作区有未提交改动 ⇒ stash 暂存（避免静默销毁）"
    ( cd "$ROOT" && git stash push -u -m "smoke-ohemu.sh auto-stash $(date +%Y%m%d-%H%M%S)" 2>&1 | tail -2 | sed 's/^/    /' )
    if [ -z "$( cd "$ROOT" && git status --porcelain )" ]; then
        ok "工作区已暂存（恢复用 git stash pop）"
    else
        bad "stash 未完全清空工作区 ⇒ 中止，请手工核对"
        exit 1
    fi
fi
step "④ 还原 Index.ets（降级态不可提交）"
( cd "$ROOT" && git checkout -- entry/src/main/ets/pages/Index.ets 2>/dev/null )
if [ -z "$( cd "$ROOT" && git status --porcelain | grep 'Index.ets' )" ]; then
    ok "工作区 Index.ets 已还原"
else
    bad "Index.ets 仍有改动，请手工核对"
fi

# —————— ⑤ 可选：hypium 27 用例 ——————
if [ "$WITH_TESTS" = 1 ]; then
    step "⑤ hypium/ohosTest 用例（EMULATOR_NOTES §9）"
    if timeout 1800 devecocli build --modules entry@ohosTest >/dev/null 2>&1; then
        ok "测试 HAP 构建成功"
        HAP_UNSIGNED="$ROOT/entry/build/default/outputs/ohosTest/entry-ohosTest-unsigned.hap" \
        HAP_SIGNED="$ROOT/sign/entry-ohosTest-signed.hap" \
            timeout 900 bash "$ROOT/tools/sign-debug.sh" sign-only >/dev/null 2>&1 \
            && ok "测试 HAP 签名成功" || bad "测试 HAP 签名失败"
        timeout 300 hdc install -r "$ROOT/sign/entry-ohosTest-signed.hap" >/dev/null 2>&1 \
            && ok "测试 HAP 安装成功" || bad "测试 HAP 安装失败"
        TR="$(mktemp /tmp/smoke-test-XXXX.log)"
        timeout 600 hdc shell "aa test -b org.kde.kdeconnect -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 120000" > "$TR" 2>&1
        line="$(grep -o 'OHOS_REPORT_RESULT: stream=Tests run: [0-9]*, Failure: [0-9]*, Error: [0-9]*, Pass: [0-9]*, Ignore: [0-9]*' "$TR" | tail -1)"
        if [ -n "$line" ]; then
            note "$line"
            echo "$line" | grep -q 'Failure: 0, Error: 0' && ok "测试全通过" || bad "测试有失败（日志 $TR）"
        else
            bad "未取到测试汇总（日志 $TR）"
        fi
    else
        bad "测试 HAP 构建失败"
    fi
fi

# —————— 汇总 ——————
step "汇总"
if [ "$fail" = 0 ]; then
    printf '  ✅ 冒烟通过（fail=0）\n'
    exit 0
else
    printf '  ❌ 冒烟失败：%d 项未通过\n' "$fail"
    exit 1
fi
