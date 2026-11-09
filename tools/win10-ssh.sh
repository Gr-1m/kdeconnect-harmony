#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Win10 远程执行 helper（SSH 免密）。用途：总指挥在 Linux 侧直接驱动 Win10
# 完成「构建 / 装真机 / 拉 hilog」，不再逐个消息指挥 DevEco。
#
# 前置：Win10 已装公钥到 C:\ProgramData\ssh\administrators_authorized_keys。
#
# 用法：
#   tools/win10-ssh.sh doctor            # 路径/版本/环境自检
#   tools/win10-ssh.sh devices           # hdc list targets
#   tools/win10-ssh.sh build [task]      # 默认 assembleHap（--no-daemon）
#   tools/win10-ssh.sh install [hap]     # 默认 sign\entry-debug-signed.hap
#   tools/win10-ssh.sh log [grep]        # hilog -x -T KDEConnect（本地过滤）
#   tools/win10-ssh.sh shell '<cmd>'     # 任意 cmd.exe 命令
#
# 环境变量覆盖：WIN10_HOST / WIN10_USER / WIN10_KEY / WIN10_REPO
set -uo pipefail

HOST=${WIN10_HOST:-192.168.3.26}
USER=${WIN10_USER:-xiaoyi}
KEY=${WIN10_KEY:-$HOME/.ssh/harmonyWin10}
REPO=${WIN10_REPO:-C:\\Users\\xiaoyi\\DevEcoStudioProjects\\kdeconnect-harmony}
HVIGOR=${WIN10_HVIGOR:-C:\\Program Files\\Huawei\\DevEco Studio\\tools\\hvigor\\bin\\hvigorw.bat}
HDC=${WIN10_HDC:-C:\\Program Files\\Huawei\\DevEco Studio\\sdk\\default\\openharmony\\toolchains\\hdc.exe}
DEVECO_SDK=${WIN10_DEVECO_SDK:-C:\\Program Files\\Huawei\\DevEco Studio\\sdk}

SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
ssh_run() { ssh "${SSH_OPTS[@]}" "$USER@$HOST" "$@"; }

usage() { sed -n '6,16p' "$0"; exit 1; }

cmd=${1:-}; shift || true

case "$cmd" in
  doctor)
    echo "user:        $(ssh_run 'whoami' 2>/dev/null)"
    echo "repo:        $(ssh_run "if exist \"$REPO\" (echo OK) else (echo MISSING)" 2>/dev/null)"
    echo "hvigorw:     $(ssh_run "\"$HVIGOR\" --version" 2>/dev/null | tr -d '\r' | tail -1)"
    echo "hdc:         $(ssh_run "\"$HDC\" -v" 2>/dev/null | tr -d '\r' | tail -1)"
    echo "devices:     $(ssh_run "\"$HDC\" list targets" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
    echo "cargo:       $(ssh_run "%USERPROFILE%\\.cargo\\bin\\cargo.exe --version" 2>/dev/null | tr -d '\r' | tail -1)"
    echo "OHOS_LLVM_LINK: $(ssh_run 'echo %OHOS_LLVM_LINK%' 2>/dev/null | tr -d '\r')"
    echo "junction:    $(ssh_run "if exist %USERPROFILE%\\ohos-llvm\\bin\\clang.exe (echo OK) else (echo MISSING)" 2>/dev/null | tr -d '\r')"
    ;;
  devices)
    ssh_run "\"$HDC\" list targets" 2>/dev/null | tr -d '\r'
    ;;
  build)
    task=${1:-assembleHap}
    # 内联设置 OHOS_LLVM_LINK（无空格 junction），避免依赖 setx 持久化
    ssh_run "cd /d \"$REPO\" & set \"DEVECO_SDK_HOME=$DEVECO_SDK\" & set \"OHOS_LLVM_LINK=%USERPROFILE%\\ohos-llvm\" & set \"JAVA_HOME=C:\\Program Files\\Huawei\\DevEco Studio\\jbr\" & set \"PATH=C:\\Program Files\\Huawei\\DevEco Studio\\jbr\\bin;%PATH%\" & \"$HVIGOR\" --stop-daemon & \"$HVIGOR\" --no-daemon $task" 2>&1 | tr -d '\r'
    ;;
  install)
    hap=${1:-sign\\entry-debug-signed.hap}
    ssh_run "cd /d \"$REPO\" & \"$HDC\" install -r \"$hap\"" 2>&1 | tr -d '\r'
    ;;
  log)
    pat=${1:-}
    # tag 用 grep 匹配（-T KDEConnect 在真机上匹配不到 A00001/org.kde.kdeconnect/KDEConnect）
    if [ -n "$pat" ]; then
      ssh_run "\"$HDC\" shell \"hilog -x\"" 2>/dev/null | tr -d '\r' | grep -i "kdeconnect" | grep -E "$pat" | tail -40
    else
      ssh_run "\"$HDC\" shell \"hilog -x\"" 2>/dev/null | tr -d '\r' | grep -i "kdeconnect" | tail -60
    fi
    ;;
  shell)
    if [ -z "${1:-}" ]; then usage; fi
    ssh_run "$1" 2>&1 | tr -d '\r'
    ;;
  *) usage;;
esac
