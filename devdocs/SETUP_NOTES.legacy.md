> **【导入说明 2026-09-22】** 本文件是 2026-09-12 前、工程骨架搭建阶段的**历史记录快照**，从
> 已降级为只读参考的旧工作区（`~/WorkSpace2/KDE_connect_hap/kdeconnect-harmony-PreDev/`）导入，
> 目的是让 Win10 侧与后续 agent 也能读到这些环境/踩坑记录。
>
> **权威来源以当前仓库为准**：构建/签名/网络栈等**现行**约定见仓库根 `AGENTS.md`（「鸿蒙构建要点」
> 一节已吸收并更新了本文件的关键结论，并补充了后续实测：libxml2 soname shim、INTERNET 权限、
> codelinter 类型门禁、ohemu 模拟器等）。本文件中的路径（如 `kdeconnect-harmony-PreDev/`）、
> bundleName、工具版本等**可能已过时**，请勿直接照抄执行。

# KDE Connect 鸿蒙版工程骨架搭建笔记

> 面向未来想复现这套环境的人。按顺序照着跑即可把一个空的 HarmonyOS NEXT 工程骨架从零搭起来并构建出 HAP。
>
> 记录时间：2026-09-01　系统：CachyOS Linux（Arch 系，滚动更新，包管理 `paru`）　用户：`cagp`（home `/home/cagp`）

## 目录

1. [任务背景](#1-任务背景)
2. [环境搭建](#2-环境搭建)
3. [创建工程骨架](#3-创建工程骨架)
4. [构建过程](#4-构建过程)
5. [踩过的坑及解决方案](#5-踩过的坑及解决方案)
6. [最终状态](#6-最终状态)
7. [附录：协议背景](#7-附录协议背景)

---

## 1. 任务背景

工作区 `/home/cagp/WorkSpace2/KDE_connect_hap`（2026-09-12 起为项目正本；曾短暂放在 libvirt 共享目录）用于开发 KDE Connect 的鸿蒙版（HarmonyOS NEXT / OpenHarmony API 26 / Stage 模型 / ArkTS），参考现有 Android、KDE 两份实现。子项目：

| 子项目 | 作用 |
| --- | --- |
| `kdeconnect-meta/` | 跨实现协议规范（`schemas/` 下 JSON Schema 定义 `NetworkPacket` 的 `body`） |
| `kdeconnect-android/` | Android 参考实现（Kotlin/Java，Gradle，包名 `org.kde.kdeconnect_tp`） |
| `kdeconnect-kde/` | KDE 桌面参考实现（C++20 / Qt6 / KF6） |
| `kdeconnect-harmony-PreDev/` | 鸿蒙实现，**本次从零搭建工程骨架** |

目标：在 `kdeconnect-harmony-PreDev/` 下建一个标准 HarmonyOS 工程骨架，能通过 `hvigorw assembleHap` 构建出未签名 HAP，为后续移植 KDE Connect 核心分层（NetworkPacket / Device / LinkProvider / Plugin）打底。

---

## 2. 环境搭建

### 2.1 安装系统包

```sh
# AUR 的 OpenHarmony SDK 26.0.0.38 (Beta)
# 装到 /opt/ohos-sdk/26，含 hdc 3.2.0f、clang 15 交叉工具链
#   （aarch64 / armv7-unknown-linux-ohos）、ets/arkts API、previewer
paru -S ohos-sdk

# HarmonyOS Sans 字体（可选，预览/调试时 UI 不至于方块）
paru -S ttf-harmonyos-sans

# PackageHap 打包任务需要 java
paru -S jdk17-openjdk
```

### 2.2 安装华为 Command Line Tools（闭源）

AUR 没有这玩意，需要手动下载：

1. 到 <https://developer.huawei.com/consumer/cn/deveco-studio/> 下载 `commandline-tools-linux-x64-26.0.0.821.zip`。
2. 解压到 `/opt/command-line-tools/`。

该工具集包含：

- hvigor 6.26.4（构建工具）
- ohpm 26.0.0.630（包管理器）
- 自带 SDK 26.0.0.105 (Release)
- hdc（设备调试桥）
- node（内嵌运行时）

### 2.3 修正属主与目录结构

**改属主**：解压后整个目录属主是 `nobody`，hvigor 需要写 SDK 目录，必须改属主给当前用户：

```sh
sudo chown -R cagp:cagp /opt/command-line-tools/
```

> ⚠️ **不要用 `find` 去 x 位修权限**：会误伤内部可执行脚本（hvigor/node 等会失去执行位）。要清理权限就重新解压。

**SDK 版本化目录调整**：hvigor 期望 SDK 组件在版本子目录下（`openharmony/26.0.0/ets`），但 Command Line Tools 自带是扁平结构（`openharmony/ets`）。手动移动：

```sh
cd /opt/command-line-tools/sdk/default/openharmony
mkdir -p 26.0.0
mv ets js native previewer toolchains 26.0.0/
```

调整后结构：

```
/opt/command-line-tools/sdk/default/openharmony/26.0.0/
├── ets
├── js
├── native
├── previewer
└── toolchains
```

### 2.4 配置环境变量

在 `~/.zshrc`（或对应 shell 配置）追加：

```sh
# OpenHarmony SDK 26 + Command Line Tools
export OHOS_SDK_HOME=/opt/ohos-sdk
export OHOS_NDK_HOME=/opt/ohos-sdk/26/native
export PATH=/opt/command-line-tools/bin:/opt/ohos-sdk/26/toolchains:/opt/ohos-sdk/26/native/llvm/bin:$PATH
```

`source ~/.zshrc` 后验证：

```sh
which hvigorw ohpm hdc   # 都应在 /opt/command-line-tools/bin 下
```

---

## 3. 创建工程骨架

在 `kdeconnect-harmony-PreDev/` 下创建标准 HarmonyOS 工程结构，共 18 个文件。

### 3.1 工程级配置

**`build-profile.json5`** — 注意 API 26+ 版本号必须是**字符串** `"26.0.0"`，不能是数字：

```json5
{
  "app": {
    "signingConfigs": [],
    "products": [
      {
        "name": "default",
        "signingConfig": "default",
        "compileSdkVersion": "26.0.0",
        "compatibleSdkVersion": "26.0.0",
        "targetSdkVersion": "26.0.0",
        "runtimeOS": "OpenHarmony"
      }
    ]
  },
  "modules": [
    { "name": "entry", "srcPath": "./entry", "targets": [
      { "name": "default", "applyToProducts": ["default"] }
    ]}
  ]
}
```

**`oh-package.json5`** — `modelVersion` 用 `"6.0.0"`（hvigor 6.x 要求）。devDependencies 只声明 `@ohos/hypium`，**不要在这里声明 hvigor**（见 [坑 2](#2-file-依赖失败)）：

```json5
{
  "modelVersion": "6.0.0",
  "description": "KDE Connect for HarmonyOS",
  "dependencies": {},
  "devDependencies": {
    "@ohos/hypium": "1.0.6"
  }
}
```

**`hvigorfile.ts`**：

```ts
import { appTasks } from '@ohos/hvigor-ohos-plugin';
export default {
  system: appTasks,
  plugins: []
}
```

**`hvigor/hvigor-config.json5`** — hvigorw 启动时找这个文件，漏建会报错：

```json5
{
  "modelVersion": "6.0.0"
}
```

**`.gitignore`**：

```
node_modules/
oh_modules/
.hvigor/
.cxx/
.test/
build/
.idea/
*.log
local.properties
```

**`local.properties`** — 本地 SDK 路径，**不提交**：

```
sdk.dir=/opt/command-line-tools/sdk/default/openharmony
```

### 3.2 AppScope

**`AppScope/app.json5`**：

```json5
{
  "app": {
    "bundleName": "org.kde.kdeconnect.harmony",
    "vendor": "kde",
    "versionCode": 1,
    "versionName": "1.0.0",
    "icon": "$media:app_icon",
    "label": "$string:app_name"
  }
}
```

**`AppScope/resources/base/element/string.json`**：

```json
{ "string": [
  { "name": "app_name", "value": "KDE Connect" }
]}
```

**`AppScope/resources/base/media/app_icon.png`** — 任意 1024×1024 PNG 占位图标。

### 3.3 entry 模块

**`entry/build-profile.json5`**：

```json5
{
  "apiType": "stageMode",
  "buildOption": {},
  "targets": [
    { "name": "default", "runtimeOS": "OpenHarmony" },
    { "name": "ohosTest", "runtimeOS": "OpenHarmony" }
  ]
}
```

**`entry/oh-package.json5`**：

```json5
{
  "name": "entry",
  "modelVersion": "6.0.0",
  "description": "KDE Connect entry module",
  "main": "",
  "dependencies": {}
}
```

**`entry/hvigorfile.ts`**：

```ts
import { hapTasks } from '@ohos/hvigor-ohos-plugin';
export default {
  system: hapTasks,
  plugins: []
}
```

**`entry/src/main/module.json5`** — `deviceTypes` 用 `["default"]`，**不要用 `"phone"`**（OpenHarmony API 26 不支持，见 [坑 9](#9-devicetypes-phone-不支持)）：

```json5
{
  "module": {
    "name": "entry",
    "type": "entry",
    "description": "$string:module_desc",
    "mainElement": "EntryAbility",
    "deviceTypes": ["default"],
    "deliveryWithInstall": true,
    "installationFree": false,
    "pages": "$profile:main_pages",
    "abilities": [
      {
        "name": "EntryAbility",
        "srcEntry": "./ets/entryability/EntryAbility.ts",
        "description": "$string:EntryAbility_desc",
        "icon": "$media:app_icon",
        "label": "$string:EntryAbility_label",
        "startWindowIcon": "$media:start_icon",
        "startWindowBackground": "$color:start_window_background",
        "exported": true,
        "skills": [
          { "entities": ["entity.system.home"], "actions": ["action.system.home"] }
        ]
      }
    ]
  }
}
```

**`entry/src/main/ets/entryability/EntryAbility.ets`**：

```ts
import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.ohos.window';

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) console.error(`Failed to load content. ${JSON.stringify(err)}`);
    });
  }
}
```

**`entry/src/main/ets/pages/Index.ets`**：

```ts
@Entry
@Component
struct Index {
  build() {
    Column() {
      Text('KDE Connect')
        .fontSize(50)
        .fontWeight(FontWeight.Bold)
    }
    .width('100%')
    .height('100%')
  }
}
```

**`entry/src/main/resources/base/element/string.json`**：

```json
{ "string": [
  { "name": "module_desc", "value": "KDE Connect entry module" },
  { "name": "EntryAbility_desc", "value": "KDE Connect" },
  { "name": "EntryAbility_label", "value": "KDE Connect" }
]}
```

**`entry/src/main/resources/base/element/color.json`**：

```json
{ "color": [
  { "name": "start_window_background", "value": "#FFFFFF" }
]}
```

**`entry/src/main/resources/dark/element/color.json`**：

```json
{ "color": [
  { "name": "start_window_background", "value": "#000000" }
]}
```

**`entry/src/main/resources/base/media/start_icon.png`** — 任意 PNG 占位图标。

**`entry/src/main/resources/base/profile/main_pages.json`**：

```json
{ "src": ["pages/Index"] }
```

---

## 4. 构建过程

> ⚠️ **必须在用户终端跑**：CodeArts 的 bash 工具沙箱断网（npmjs / baidu / 华为 registry 全连不上）且 `/home/cagp` 只读，`uid=1000` 无用户名。`ohpm install` / `hvigorw` 在 bash 工具里跑不起来。详见 [坑 11](#11-codearts-bash-沙箱限制)。

```sh
cd /home/cagp/WorkSpace2/KDE_connect_hap/kdeconnect-harmony-PreDev

# 1) 装依赖：从 ohpm.openharmony.cn 拉 @ohos/hypium
ohpm install

# 2) hvigor 不在 registry，手动软链自带包到 oh_modules/@ohos/
mkdir -p oh_modules/@ohos
ln -sf /opt/command-line-tools/hvigor/hvigor            oh_modules/@ohos/hvigor
ln -sf /opt/command-line-tools/hvigor/hvigor-ohos-plugin oh_modules/@ohos/hvigor-ohos-plugin

# 3) 构建 HAP
hvigorw assembleHap
```

产物：

```
entry/build/default/outputs/default/entry-default-unsigned.hap   # 约 76 KB，未签名
```

---

## 5. 踩过的坑及解决方案

按出现顺序排列。每条都是真踩过、有具体报错对应的。

### 1. ohpm registry 碎片

**现象**：`ohpm.openharmony.cn` 有 `@ohos/hypium` 但没有 `@ohos/hvigor`（404）；`repo.harmonyos.com` 有 hvigor 但没 hypium。两个 registry 互不完整。

**解决**：hypium 从 `openharmony.cn` 装，hvigor 不走 ohpm，直接软链 Command Line Tools 自带的包到 `oh_modules/@ohos/`。

### 2. file: 依赖失败

**现象**：尝试在 `oh-package.json5` 里写 `"@ohos/hvigor": "file:/opt/command-line-tools/hvigor/hvigor"`。但 ohpm 期望依赖目录里有 `oh-package.json5`，而自带包是 npm 格式的 `package.json`。即使 `sudo cp package.json oh-package.json5` 之后，ohpm 又尝试从 registry 装 hvigor 的子依赖（`socket.io-client` 等 npm 包，registry 没有），照样失败。

**解决**：放弃 `file:` 依赖，改用软链自带包到 `oh_modules/@ohos/`，绕过 ohpm 解析。

### 3. hvigorw 期望工程 hvigor/hvigor-config.json5

**现象**：初始骨架漏创建 `hvigor/hvigor-config.json5`，hvigorw 启动报找不到配置。

**解决**：补上 `hvigor/hvigor-config.json5`，内容 `{ "modelVersion": "6.0.0" }`。

### 4. 缺 compileSdkVersion

**现象**：hvigor 要求 OpenHarmony 工程的 product 配 `compileSdkVersion`，初始 build-profile.json5 没写。

**解决**：在 `build-profile.json5` 的 `products[0]` 里补 `compileSdkVersion` / `compatibleSdkVersion` / `targetSdkVersion`。

### 5. modelVersion

**现象**：hvigor 6.26.4 要求 `hvigor-config.json5` 和 `oh-package.json5` 都有 `modelVersion` 字段。先用 `"5.0.0"` 能跑过基础校验，但配 API 26 字符串版本后又报版本不匹配。

**解决**：统一升到 `"6.0.0"`。

### 6. SDK 版本数字 vs 字符串

**现象**：API 10–25 用数字（如 `12`），API 26+ 必须用字符串（如 `"26.0.0"`）。初始写数字 `26` 报错。

**解决**：`compileSdkVersion` / `compatibleSdkVersion` / `targetSdkVersion` 全改成字符串 `"26.0.0"`。

### 7. SDK 路径不可写

**现象**：`/opt/command-line-tools` 解压后属主 `nobody`，hvigor 需写 SDK 目录（缓存、临时文件），权限拒绝。

**解决**：`sudo chown -R cagp:cagp /opt/command-line-tools`。

### 8. SDK 管理模式 / 版本化目录

**现象**：hvigor 期望 `openharmony/26.0.0/ets`，自带是 `openharmony/ets`（扁平结构），找不到组件。

**解决**：把 `ets js native previewer toolchains` 全部移到 `26.0.0/` 子目录下。

### 9. deviceTypes "phone" 不支持

**现象**：`module.json5` 写 `"deviceTypes": ["phone"]`，构建报 OpenHarmony API 26 不支持该 deviceType。

**解决**：改成 `["default"]`。

### 10. 缺 java

**现象**：构建到 `PackageHap` 任务时 `spawn java ENOENT`。

**解决**：`paru -S jdk17-openjdk`。

### 11. CodeArts bash 沙箱限制

**现象**：在 CodeArts 的 bash 工具里跑 `ohpm install`，npmjs / baidu / 华为 registry 全连不上（断网）；且 `/home/cagp` 只读，`uid=1000` 无用户名，写文件失败。

**解决**：`ohpm install` 和 `hvigorw assembleHap` 一律在用户真实终端跑，不在 bash 工具里跑。

---

## 6. 最终状态

- ✅ 工程骨架 18 个文件全部就位
- ✅ `hvigorw assembleHap` 构建通过
- ✅ HAP 产物生成：`entry/build/default/outputs/default/entry-default-unsigned.hap`（约 76 KB，未签名）
- ✅ 构建知识已沉淀到 `kdeconnect-harmony-PreDev/AGENTS.md` 和根 `AGENTS.md`

### 待续

1. 搭 KDE Connect 核心分层基类：`NetworkPacket` / `Device` / `LinkProvider` / `Plugin`
2. 配调试签名 + hdc 连真机，装上 HAP 验证启动
3. 按 `kdeconnect-meta/schemas/` 实现 packet 序列化，确保 `type` / `body` 字段与 schema 严格一致

---

## 7. 附录：协议背景

KDE Connect 设备间通过 `NetworkPacket` 通信，结构：

```json
{ "id": 123, "type": "com.example.plugin", "body": { ... }, "version": 1 }
```

带二进制负载时增加 `payloadSize`（`-1` 表示流式）和 `payloadTransferInfo`（由 Link 实现决定）。

架构四块：

| 组件 | 职责 |
| --- | --- |
| **LinkProvider** | 发现设备并建立 Link（`backends/{lan,bluetooth,loopback}`） |
| **Device** | 抽象远程设备，与具体 Link 解耦 |
| **NetworkPacket** | JSON 序列化信息单元 |
| **Plugin** | 实现具体功能，通过 NetworkPacket 与对端同名 Plugin 通信 |

**鸿蒙版约束**：packet `type` 和 `body` 字段必须与 `kdeconnect-meta/schemas/` 中的 Schema 严格一致。新增/修改 packet 类型要先改 schema，再 `make check`，然后同步到实现。参考实现里同名插件可对照字段顺序与版本号。
