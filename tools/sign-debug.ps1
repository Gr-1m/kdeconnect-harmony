# SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 本地 debug 签名 + 安装（**Windows 版**，逐条移植自 tools/sign-debug.sh）
# ---------------------------------------------------------------------------
# 为什么需要它：`devecocli signature generate`（以及 DevEco 的「自动签名」）走的是**华为云侧 provision**，
# 受**每月配额**限制（本会话实测 `Provision number exceeds limit`）。而本脚本只用 **SDK 自带的本地材料**
# + `hap-sign-tool -mode localSign` ⇒ **零配额**，可无限次重签/装机。
#
# 用法（仓库根）：
#   powershell -ExecutionPolicy Bypass -File tools/sign-debug.ps1 sign-only   # 构建 + 签名
#   powershell -ExecutionPolicy Bypass -File tools/sign-debug.ps1 install     # 只装已签 HAP
#   powershell -ExecutionPolicy Bypass -File tools/sign-debug.ps1             # 构建 + 签名 + 安装（默认）
#
# 依赖（Win10 均已就位）：OpenHarmony SDK 里的 hap-sign-tool.jar / OpenHarmony.p12 /
#   OpenHarmonyProfileDebug.pem / UnsgnedDebugProfileTemplate.json；java；hdc；devecocli。
#
# 移植时保留的原脚本踩坑记录（勿改）：
#  · hap-sign-tool 的 appCertFile / profileCertFile 都要**完整证书链**（leaf, 中间CA, root），单张报 11013004；
#  · p12 里 "openharmony application release" 是私钥自签名包装，真正配对的叶证书是 profile 模板里的
#    `development-certificate`（App CA 签发），必须用它；
#  · 模板 validity 已过期（2021~2023），要重填 not-before / not-after（这里给 2 年）；
#  · debug profile 的 device-ids 必须填**目标设备 UDID**（hdc shell bm get --udid）；
#  · sign-app 的 -compatibleVersion 对 .hap 必填；签名算法证书实为 ecdsa-with-SHA384 ⇒ SHA384withECDSA；
#  · WRITE_IMAGEVIDEO / WRITE_AUDIO 属 system_core 级 ACL：debug 安装须在 profile 的 allowed-acls 里声明，
#    否则 install 报 9568289（grant request permissions failed）。**用户 2026-09-22 裁决保留写权限** ⇒ 保留该 ACL。

param(
  [ValidateSet('all', 'sign-only', 'install')]
  [string]$Mode = 'all'
)

# 注意：外部命令（devecocli/java/hdc）会把进度信息写到 stderr，若用 Stop 会被当成致命错误 ⇒ 用 Continue + 显式检查
$ErrorActionPreference = 'Continue'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SdkLib = Join-Path $env:LOCALAPPDATA 'OpenHarmony\Sdk\26.0.0\toolchains\lib'
$Tool = Join-Path $SdkLib 'hap-sign-tool.jar'
# hdc 不在 PATH：它就在 SDK toolchains 目录下（与即可用的 hap-sign-tool 同级）
$Hdc = Join-Path (Split-Path $SdkLib -Parent) 'hdc.exe'
$SignDir = Join-Path $ProjectRoot 'sign'
$BundleName = 'org.kde.kdeconnect'
$ApiVersion = 26
$KsPwd = '123456'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Build-Hap {
  # Win10 侧等价于 hvigorw assembleHap（CLT 的薄封装）
  & devecocli build 2>&1 | Select-String -Pattern 'BUILD SUCCESSFUL|error:|Error Message' | Select-Object -First 4 | ForEach-Object { Write-Host ('  ' + $_.Line.Trim()) }
}

function Prepare-Materials {
  New-Item -ItemType Directory -Force -Path $SignDir | Out-Null
  $pem = [System.IO.File]::ReadAllText((Join-Path $SdkLib 'OpenHarmonyProfileDebug.pem'), [System.Text.Encoding]::UTF8)
  $certs = [regex]::Matches($pem, '-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----', 'Singleline')
  if ($certs.Count -lt 3) { throw "PEM 里证书数量不足（$($certs.Count)）：$SdkLib\OpenHarmonyProfileDebug.pem" }
  [System.IO.File]::WriteAllText((Join-Path $SignDir 'root-ca.cer'), $certs[0].Value + "`n", $utf8)
  [System.IO.File]::WriteAllText((Join-Path $SignDir 'app-ca.cer'), $certs[1].Value + "`n", $utf8)

  $tplRaw = [System.IO.File]::ReadAllText((Join-Path $SdkLib 'UnsgnedDebugProfileTemplate.json'), [System.Text.Encoding]::UTF8)
  $tpl = $tplRaw | ConvertFrom-Json
  $leaf = $tpl.'bundle-info'.'development-certificate'
  if ([string]::IsNullOrWhiteSpace($leaf)) { throw '模板里没有 development-certificate' }
  [System.IO.File]::WriteAllText((Join-Path $SignDir 'app-release.cer'), $leaf, $utf8)
  # 证书链：leaf, 中间CA, root
  [System.IO.File]::WriteAllText((Join-Path $SignDir 'app-release-chain.cer'),
    $leaf + $certs[1].Value + "`n" + $certs[0].Value + "`n", $utf8)
  # profile 链：profile-debug, 中间CA, root
  [System.IO.File]::WriteAllText((Join-Path $SignDir 'profile-debug-chain.cer'),
    $certs[2].Value + "`n" + $certs[1].Value + "`n" + $certs[0].Value + "`n", $utf8)

  $p12 = Join-Path $SignDir 'OpenHarmony.p12'
  if (-not (Test-Path $p12)) { Copy-Item (Join-Path $SdkLib 'OpenHarmony.p12') $p12 -Force }
  Write-Host '  材料就绪：root-ca / app-ca / app-release(-chain) / profile-debug-chain / OpenHarmony.p12'
}

function Sign-Profile {
  $udid = (& $Hdc shell "bm get --udid" 2>&1 | Select-Object -Last 1).ToString().Trim()
  if ($udid.Length -ne 64) { throw "UDID 获取失败（长度 $($udid.Length)）：$udid" }
  # 用 ConvertFrom-Json 解析（比正则稳；app.json5 此处是标准双引号 JSON）
  $appJson = ([System.IO.File]::ReadAllText((Join-Path $ProjectRoot 'AppScope\app.json5'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json).app
  $vName = "$($appJson.versionName)"
  $vCode = "$($appJson.versionCode)"
  if ($vName -eq '' -or $vCode -eq '') { throw '无法从 AppScope/app.json5 解析 versionName/versionCode' }

  $t = [System.IO.File]::ReadAllText((Join-Path $SdkLib 'UnsgnedDebugProfileTemplate.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  $now = [int][double]::Parse((Get-Date -UFormat %s))
  $t.'version-name' = $vName
  $t.'version-code' = [int]$vCode
  $t.validity = [pscustomobject]@{ 'not-before' = ($now - 86400); 'not-after' = ($now + 730 * 86400) }
  $t.'bundle-info'.'bundle-name' = $BundleName
  $t.'debug-info'.'device-ids' = @($udid)
  # 受限开放权限（system_core 级）必须在 allowed-acls 声明，否则 install 报 9568289。
  # 用户 2026-09-22 裁决「保留写权限」⇒ 这两条 ACL 保留。
  $t.acls = [pscustomobject]@{ 'allowed-acls' = @('ohos.permission.WRITE_IMAGEVIDEO', 'ohos.permission.WRITE_AUDIO') }
  [System.IO.File]::WriteAllText((Join-Path $SignDir 'profile-debug.json'), ($t | ConvertTo-Json -Depth 30), $utf8)

  & java -jar $Tool sign-profile -mode localSign `
    -keyAlias 'openharmony application profile debug' -keyPwd $KsPwd `
    -profileCertFile (Join-Path $SignDir 'profile-debug-chain.cer') `
    -inFile (Join-Path $SignDir 'profile-debug.json') -signAlg SHA256withECDSA `
    -keystoreFile (Join-Path $SignDir 'OpenHarmony.p12') -keystorePwd $KsPwd `
    -outFile (Join-Path $SignDir 'profile-debug.p7b') | Out-Null
  if (-not (Test-Path (Join-Path $SignDir 'profile-debug.p7b'))) { throw 'sign-profile 未产出 p7b' }
  Write-Host "  profile 已签：profile-debug.p7b  (UDID=$($udid.Substring(0,8))… v$vName/$vCode)"
}

function Sign-Hap {
  $inHap = Join-Path $ProjectRoot 'entry\build\default\outputs\default\entry-default-unsigned.hap'
  if (-not (Test-Path $inHap)) { throw "找不到未签名 HAP：$inHap（先跑构建）" }
  $outHap = Join-Path $SignDir 'entry-debug-signed.hap'
  & java -jar $Tool sign-app -mode localSign `
    -keyAlias 'openharmony application release' -keyPwd $KsPwd `
    -appCertFile (Join-Path $SignDir 'app-release-chain.cer') `
    -profileFile (Join-Path $SignDir 'profile-debug.p7b') `
    -inFile $inHap -signAlg SHA384withECDSA `
    -keystoreFile (Join-Path $SignDir 'OpenHarmony.p12') -keystorePwd $KsPwd `
    -outFile $outHap -compatibleVersion $ApiVersion -signCode 1 | Out-Null
  if (-not (Test-Path $outHap)) { throw 'sign-app 未产出 HAP' }
  Write-Host "  已签名：$outHap  ($([int]((Get-Item $outHap).Length/1024)) KB)"
}

function Install-Hap {
  $hap = Join-Path $SignDir 'entry-debug-signed.hap'
  & $Hdc install $hap 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-Host ('  ' + $_) }
}

switch ($Mode) {
  'sign-only' { Build-Hap; Prepare-Materials; Sign-Profile; Sign-Hap }
  'install' { Install-Hap }
  default { Build-Hap; Prepare-Materials; Sign-Profile; Sign-Hap; Install-Hap }
}
Write-Host '完成（**未消耗任何华为云侧签名配额**）。'
