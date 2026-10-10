# SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# arkts-logic-test.ps1 —— 宿主侧「纯逻辑」测试通道（**无需设备/模拟器**）。
#
# 背景（借鉴 docs/kdeconnect-oh/ 09 §5 的 logic 层思路，落地到现工程）：
#   现工程的 hypium(ohosTest) 套件**必须装到设备**才能跑（ohemu/真机）；
#   而其中相当一部分是**零 Kit 依赖的纯逻辑**（节流/增量换算/码表/组帧字段名），
#   完全可以脱离设备验证 ⇒ 本脚本用 DevEco 自带 TypeScript 编译器 + Node 在宿主直接跑，
#   把回归从「依赖 ohemu」变成「本机秒级」。
#
#   关键设计：**测试源码只有一份**。本脚本把既有的 `*.test.ets` 复制到临时目录并做两处
#   路径重写（hypium 替身、扁平化），从而**同一份用例**既走设备侧真 hypium、又走宿主替身，
#   不存在"两套测试"的双真相风险。
#
# 覆盖范围：仅零 Kit 依赖的套件（见 tools/logic-test/run.ts 的登记）。
#   依赖 libkdeconnect_napi.so / @kit.* 的套件仍须设备侧跑（ohemu 配方见 EMULATOR_NOTES §9）。
#
# 用法：pwsh -File tools/arkts-logic-test.ps1

$ErrorActionPreference = 'Continue'

$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# --- 1) 定位 DevEco 自带 tsc（零安装）---
$tscCandidates = @(
  "$env:DEVECO_HOME\tools\hvigor\hvigor\node_modules\typescript\lib\tsc.js",
  'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\hvigor\node_modules\typescript\lib\tsc.js',
  'C:\Program Files\Huawei\DevEco Studio\tools\ohpm\node_modules\typescript\lib\tsc.js'
)
$tsc = $tscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $tsc) {
  Write-Host '[logic-test] 找不到 tsc.js（请设置 DEVECO_HOME）' -ForegroundColor Red
  exit 2
}
$nodeExe = 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe'
if (-not (Test-Path $nodeExe)) { $nodeExe = 'node' }

# --- 2) 临时工作目录（仓库外，避免污染工作区）---
$work = Join-Path $env:TEMP 'deveco\kdc-logic-test'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
$src = Join-Path $work 'src'
$out = Join-Path $work 'out'
New-Item -ItemType Directory -Path $src -Force | Out-Null

$utf8 = New-Object System.Text.UTF8Encoding($false)   # 无 BOM；显式编码 ⇒ 不动仓库文件

$pluginsDir = Join-Path $repo 'entry\src\main\ets\plugins'
$modelDir = Join-Path $repo 'entry\src\main\ets\model'
$testDir = Join-Path $repo 'entry\src\ohosTest\ets\test'

# 扁平复制的清单（源文件 + 目的名）
$copies = @(
  @{ from = "$pluginsDir\PluginEvent.ets";        to = 'PluginEvent.ts' },
  @{ from = "$pluginsDir\PluginBase.ets";         to = 'PluginBase.ts' },
  @{ from = "$pluginsDir\MousepadThrottle.ets";   to = 'MousepadThrottle.ts' },
  @{ from = "$pluginsDir\MousepadInput.ets";      to = 'MousepadInput.ts' },
  @{ from = "$pluginsDir\RemoteInputKeymap.ets";  to = 'RemoteInputKeymap.ts' },
  @{ from = "$pluginsDir\RemoteInputPlugin.ets";  to = 'RemoteInputPlugin.ts' },
  @{ from = "$modelDir\MprisModels.ets";          to = 'MprisModels.ts' },
  @{ from = "$modelDir\SystemVolumeModels.ets";   to = 'SystemVolumeModels.ts' },
  @{ from = "$testDir\MousepadThrottle.test.ets";   to = 'MousepadThrottle.test.ts' },
  @{ from = "$testDir\MousepadInput.test.ets";      to = 'MousepadInput.test.ts' },
  @{ from = "$testDir\RemoteInputKeymap.test.ets";  to = 'RemoteInputKeymap.test.ts' },
  @{ from = "$testDir\RemoteInputPlugin.test.ets";  to = 'RemoteInputPlugin.test.ts' }
)

foreach ($c in $copies) {
  if (-not (Test-Path $c.from)) {
    Write-Host "[logic-test] 缺少源文件: $($c.from)" -ForegroundColor Red
    exit 2
  }
  $text = [System.IO.File]::ReadAllText($c.from, [System.Text.Encoding]::UTF8)
  # 重写 1：hypium 真身 → 宿主替身
  $text = $text.Replace("from '@ohos/hypium'", "from './hypium'")
  # 重写 2：扁平化 main 侧 import（../model/X、../../../main/ets/plugins/X → ./X）
  $text = $text -replace "from '\.\./\.\./\.\./main/ets/plugins/", "from './"
  $text = $text -replace "from '\.\./\.\./\.\./main/ets/model/", "from './"
  $text = $text -replace "from '\.\./model/", "from './"
  [System.IO.File]::WriteAllText((Join-Path $src $c.to), $text, $utf8)
}

# 替身与入口（仓库内文件，直接复制，无重写）
Copy-Item (Join-Path $repo 'tools\logic-test\hypium.ts') (Join-Path $src 'hypium.ts') -Force
Copy-Item (Join-Path $repo 'tools\logic-test\arkui-shim.ts') (Join-Path $src 'arkui-shim.ts') -Force
Copy-Item (Join-Path $repo 'tools\logic-test\run.ts') (Join-Path $src 'run.ts') -Force

# --- 3) 编译 ---
$files = Get-ChildItem $src -Filter *.ts | ForEach-Object { $_.FullName }
& $nodeExe $tsc --outDir $out --module commonjs --target es2020 --moduleResolution node `
  --esModuleInterop --skipLibCheck --strict false --noImplicitAny false --experimentalDecorators $files
if ($LASTEXITCODE -ne 0) {
  Write-Host '[logic-test] TypeScript 编译失败' -ForegroundColor Red
  exit 1
}

# --- 4) 运行 ---
& $nodeExe (Join-Path $out 'run.js')
exit $LASTEXITCODE
