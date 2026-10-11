#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# arkts-logic-test.sh —— 宿主侧「纯逻辑」测试通道（Linux/CI 版）。
# 与 `tools/arkts-logic-test.ps1` **同一份替身与重写规则**（tools/logic-test/{hypium,arkui-shim,run}.ts），
# 只是编排器换成 bash ⇒ 两车道跑的是**同一套用例、同一套判定**。
#
# ⚠️ **本脚本在 Win10 侧未经验证**（该侧无 bash/Linux 环境），首次运行请 Linux 侧确认；
#    逻辑与 ps1 版逐条对应（复制清单 / sed 重写规则 / bun 运行）。
#
# 用法：bash tools/arkts-logic-test.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/kdc-logic-test"
SRC="$WORK/src"

rm -rf "$WORK"
mkdir -p "$SRC"

P="$REPO/entry/src/main/ets/plugins"
M="$REPO/entry/src/main/ets/model"
C="$REPO/entry/src/main/ets/common"
T="$REPO/entry/src/ohosTest/ets/test"

# .ets → .ts 复制 + 两处路径重写（hypium 替身 / 扁平化 main 侧 import）
copy() {
  sed -e "s|from '@ohos/hypium'|from './hypium'|" \
      -e "s|from '\.\./\.\./\.\./main/ets/plugins/|from './|" \
      -e "s|from '\.\./\.\./\.\./main/ets/model/|from './|" \
      -e "s|from '\.\./\.\./\.\./main/ets/common/|from './|" \
      -e "s|from '\.\./model/|from './|" \
      -e "s|from '\.\./common/|from './|" \
      "$1" > "$SRC/$2"
}

copy "$P/PluginEvent.ets"        PluginEvent.ts
copy "$P/PluginBase.ets"         PluginBase.ts
copy "$P/MousepadThrottle.ets"   MousepadThrottle.ts
copy "$P/MousepadInput.ets"      MousepadInput.ts
copy "$P/RemoteInputKeymap.ets"  RemoteInputKeymap.ts
copy "$P/RemoteInputPlugin.ets"  RemoteInputPlugin.ts
copy "$M/MprisModels.ets"        MprisModels.ts
copy "$M/SystemVolumeModels.ets" SystemVolumeModels.ts
copy "$M/NotificationModels.ets" NotificationModels.ts
copy "$C/NotificationStore.ets"  NotificationStore.ts
copy "$T/MousepadThrottle.test.ets"  MousepadThrottle.test.ts
copy "$T/MousepadInput.test.ets"     MousepadInput.test.ts
copy "$T/RemoteInputKeymap.test.ets" RemoteInputKeymap.test.ts
copy "$T/RemoteInputPlugin.test.ets" RemoteInputPlugin.test.ts
copy "$T/Notification.test.ets"      Notification.test.ts

cp "$REPO/tools/logic-test/hypium.ts"    "$SRC/hypium.ts"
cp "$REPO/tools/logic-test/arkui-shim.ts" "$SRC/arkui-shim.ts"
cp "$REPO/tools/logic-test/run.ts"       "$SRC/run.ts"

if ! command -v bun >/dev/null 2>&1; then
  echo "[logic-test] 未找到 bun；本脚本只走 bun 路径（安装：curl -fsSL https://bun.sh/install | bash，需用户确认）" >&2
  exit 2
fi

echo "[logic-test] runner = bun ($(command -v bun))"
exec bun run "$SRC/run.ts"
