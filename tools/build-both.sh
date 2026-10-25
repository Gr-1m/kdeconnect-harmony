#!/usr/bin/env bash
# 三实例一键构建部署：构建 + 按端签名 + 安装 + 启动（折叠 5555 / 平板 5557 / 手机 5559）
#
# 用法:
#   tools/build-both.sh                # 构建 + 签名 + 安装 + 启动三实例（默认）
#   PHONE=127.0.0.1:5560 TABLET=127.0.0.1:5561 FOLDABLE=127.0.0.1:5562 tools/build-both.sh   # 自定义端地址
#
# 说明:
#   - debug profile 绑单 UDID（tools/sign-debug.sh 用 hdc shell bm get --udid 取），
#     双端必须分别签名，本脚本按端各签一次（第二次构建为增量，秒级）
#   - 依赖 ~/.local/bin/hdc 垫片：读 HDC_TARGET 环境变量注入 -t 路由到指定实例，
#     未设时直通真实 hdc；server 级命令（kill -r 等）不受影响
#   - libxml2 shim：CLT 的 ld.lld 依赖 libxml2.so.2，系统 libxml2 2.15 是 .so.16，
#     经 LD_LIBRARY_PATH 垫上（~/.local/share/ohos_libshim）
#   - hdc install 失败可能不返非零码，故对输出断言 "install bundle successfully"
#
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$HOME/.local/share/ohos_libshim"
export PATH="$HOME/.local/bin:$PATH"

FOLDABLE="${FOLDABLE:-127.0.0.1:5555}"
TABLET="${TABLET:-127.0.0.1:5557}"
PHONE="${PHONE:-127.0.0.1:5559}"

deploy_one() {
  local name="$1" target="$2" out
  echo "========== $name ($target) =========="
  out="$(HDC_TARGET="$target" tools/sign-debug.sh 2>&1)" || {
    echo "[FAIL] $name 构建/签名失败："
    echo "$out" | tail -5
    exit 1
  }
  echo "$out" | tail -3
  echo "$out" | grep -q "install bundle successfully" || {
    echo "[FAIL] $name 安装未确认（hdc install 可能静默失败）："
    echo "$out" | tail -5
    exit 1
  }
  HDC_TARGET="$target" bash tools/launch-app.sh
}

deploy_one "双折叠" "$FOLDABLE"
deploy_one "平板" "$TABLET"
deploy_one "手机" "$PHONE"
echo "[OK] 三实例部署完成：$FOLDABLE / $TABLET / $PHONE"
