# KDE-H Connect — ArkTS 标准化开发指导（v0.1）

> 2026-09-12，DevEco Code（Win10，ArkTS 侧职能固定）起草。
> 适用范围：**ArkTS 全部** —— Stage 模型、ArkUI（页面/导航/状态）、业务层、插件层、NAPI 接口 TS 侧封装、`Index.d.ts` 契约提案。C++ native 侧见 `devdocs/CPP_GUIDE.md`（zcode），流程事务（commit 时机/单测指导/CI 规格）听 CodeArts。
> 背景与全局约束见仓库根 `KICKOFF_PROMPT.md` 与 `AgentsConversion/AGENTS.md`，本文不重复，只做 ArkTS 侧落地规范。

## 0. 事实源优先级

1. `kdeconnect-meta/schemas/`（协议 JSON Schema，唯一事实源；**本仓库不含此目录**，需查 schema 时给 zcode 发消息代查）
2. `entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts`（NAPI 契约，唯一定义源；变更流程见 §5）
3. `KICKOFF_PROMPT.md` + `AgentsConversion/AGENTS.md` + `devdocs/CPP_GUIDE.md`（流程与硬约束）
4. 参考实现 `kdeconnect-android/`（插件架构蓝本）、`kdeconnect-kde/`（只读，不在本仓库，经 zcode 代查）；`docs/` 17 篇调研（gitignore，按符号名搜索勿按行号引用；12/13/14 三篇为移植蓝本）

冲突按上述顺序裁决；文档与代码不符先在 `AgentsConversion/` 发消息对齐再改代码。

## 1. 重建策略：携带移植 + 配对流程纠偏（AP-0 已完成）

与 CPP_GUIDE 同一原则：旧工程已端到端验证的 ArkTS 基线**整体搬入**，不推倒重写。AP-0 已完成（2026-09-12）：

| 项 | 状态 | 说明 |
|---|---|---|
| 工程骨架（AppScope/根构建配置/hvigor/module.json5/资源） | ✅ | 照 PreDev 快照逐文件移植；`app_name` 已改 **KDE-H Connect**（base+zh_CN），`bundleName` 开发期保持 `org.kde.kdeconnect.harmony`（用户裁决，上架前改，见 §3 AP-7） |
| `ets/entryability/EntryAbility.ets` | ✅ | 原样（沉浸式全屏 + 安全区高度入 AppStorage） |
| `ets/kdeconnect/NetworkPacket.ets` | ✅ | 原样（镜像 Android NetworkPacket，插件层基类依赖） |
| `ets/net/PacketRouter.ets` | ✅ | 原样（帧切分 + pair/identity/ping 骨架处理；**自动接受配对是骨架行为**，AP-1 用配对确认 UI 替换） |
| `ets/pages/Index.ets` | ✅ | **移植 HEAD 提交版本**——旧工程「connected 后主动发 pair」的未提交改动**未带入**（用户 2026-09-12 裁决：配对流程与 iOS 一致，由配对确认 UI 触发；见 `AgentsConversion/MSG21_TO_ZCODE.md` §1 说明） |
| `tools/sign-debug.sh`、`tools/launch-app.sh` | ✅ | 快照拷入（脚本本身用相对路径，无需改路径） |
| 构建 | ✅ | Win10 DevEco（商用 SDK 26.0.0）`hvigorw assembleHap` BUILD SUCCESSFUL（33 tasks，含 CompileArkTS + CMake/Ninja 全 native 栈）——KICKOFF「Win10 首验①」通过，报告见 `AgentsConversion/WIN10_LOG_20260912_win10-first-verify.md` |

## 2. 目录结构规范（随 M1/M2 演进）

```
entry/src/main/ets/
├── entryability/EntryAbility.ets   # UIAbility 生命周期 + 全屏/安全区
├── common/                         # (AP-1 起) 协议常量、验证码算法、日志工具
│   ├── Constants.ets               #   跨端常量唯一出处（§6），禁止散落硬编码
│   └── PairingUtils.ets            #   验证码 = 双方公钥 DER 排序拼接 + SHA256 前 8 位 hex 大写
├── model/DeviceModels.ets          # 纯数据模型：DeviceItem（已连接/发现）、RememberedDevice（已配对）
├── net/PacketRouter.ets            # 连接层：帧切分 + pair/identity/ping 处理（配对回调 onPaired/onUnpaired）
├── kdeconnect/NetworkPacket.ets    # 协议对象：NetworkPacket
├── plugins/                        # (M2) PluginBase + PluginRegistry + 各功能插件
│   ├── PluginBase.ets
│   ├── PluginRegistry.ets          #   注册表驱动：能力 → 插件构造器 的 map（勿学 iOS 硬编码 switch）
│   └── <plugin>/                   #   battery / clipboard / findmyphone / runcommand / share / mousepad / presenter
├── components/                     # 可复用 UI：GlassCard（玻璃/沉浸卡片容器）+ 四个 Tab 组件
│   ├── GlassCard.ets               #   注意：自定义组件不能链通用属性（.onClick/.layoutWeight 会编译错）
│   ├── DevicesTab.ets              #   设备页：左侧收纳/展开栏（已连接/发现/记住的/手动连接）+ 右侧主区
│   ├── FilesTab.ets                #   文件页：占位（等 WP-1 payload 通道 + d.ts v2）
│   ├── SettingsTab.ets             #   设置页：设备名改名 / 主题 / 语言 / 本机信息
│   └── LogsTab.ets                 #   日志页：开发期用，上架前评估移除
└── pages/Index.ets                 # 壳：状态 + native 生命周期/事件 + 底部悬浮栏 Tab 切换
```

UI 结构（对齐 iOS 端 Devices+Settings 两 Tab，鸿蒙扩展为四 Tab）：
- **底部悬浮胶囊栏**（华为应用商店/我的华为风格，药丸高亮）：设备 / 文件 / 设置 / 日志[开发期]；
- **设备页**：**左侧收纳/展开竖栏**（已连接 / 发现设备 / 记住的设备 / 手动连接，带数量角标，`‹/›` 折叠为窄条），选中后**右侧主区**展示对应内容；已连接（绿点+断开）、发现设备（蓝点+连接，host 未知时禁用）、记住的设备（紫点+已配对徽标，Preferences 持久化 `rememberedDevices`）；手动连接为侧栏可选项；
- **连接/配对会话（AP-1c，与 iOS 一致，2026-09-13 用户裁决）**：发现列表「连接」与手动连接**共用一条状态机** `idle → connecting → prompt → awaiting → idle(成功) | failed`：
  - 点「连接」**立刻**弹居中模态（标题「正在连接…」+ 目标 host:port + 取消），解决"点击后无任何反馈"；
  - 连上（`connected` 事件）后：已配对 → 直接成功；未配对 → 弹窗切为**配对确认**（设备名 + 验证码 + 取消/配对），验证码用本侧生成的 timestamp 计算（同一值随 pair 帧发给对端）；
  - 点「配对」→ 状态 `awaiting`（30s 超时）；对端先发 pair 请求时不再叠第二个弹窗，本弹窗的「配对」按钮即接受；
  - 成功（`onPaired`）→ 提示「配对成功」并**自动把设备分区切回 0 = 已连接设备**（`@Link deviceSection`，此前需手动切回）；失败 → 同一弹窗显示「连接失败」/「配对失败」+ 原因（连接 20s 超时、`error` 事件、`disconnected`、配对 30s 超时）；「取消」只收弹窗、保留已建立的连接；
  - 分区状态由 `DevicesTab` 的 `@State selectedSection` **改为 `@Link deviceSection`**，供页面在配对成功后跳转。
- **文件页**：连接后可收发（kdeconnect.share + payload），当前占位；
- **设置页**：本机身份与协议信息（deviceId 等）+ **可自定义设备名**（持久化 `deviceName` 并重启 native 栈，使 identity 广播用新名，deviceId/证书不变）+ **主题**（跟随系统 / 亮 / 暗）+ **语言**（默认跟随系统）；
- **沉浸光感（API 26 `uiMaterial`）已知坑（官方文档实证）**：`systemMaterial` **只在两类区域生效**——Navigation/NavDestination 标题栏、或「横向 Tabs + `barPosition: BarPosition.End` 的底部 TabBar」（弹窗类/Slider/Toggle 除外）；**范围外组件材质失活，现象=完全透明/无效果，且控制台会打印 `Material inactive: out of scope`**。此外 `backgroundColor` 不透明、`backgroundBlurStyle` 会盖住材质层；`materialColor` 必须带透明度。→ 本项目自绘卡片/悬浮胶囊栏**不在范围内**，故统一走毛玻璃降级；将来启用材质的正解是把底部栏改成真正的 `Tabs` 底部 TabBar（官方 FAQ《基于 Tabs 组件实现胶囊样式、悬浮留空及重叠毛玻璃等常见 TabBar 自定义样式》：`Stack{ Tabs(barHeight 0) + 自绘栏 }` 或 `TabContent.tabBar(自定义 builder)`）。
- **响应式布局**：`display.getDefaultDisplaySync().width` 经 `getUIContext().px2vp()` 换算 vp，**600vp 断点**区分手机/平板；手机侧栏走抽屉（背景变暗 + 占屏大部分 + 选中收起），平板侧栏常驻可收起为仅汉堡按钮。汉堡/关闭等小图标用 `Row` 自绘（避免猜 `sys.symbol.*` 资源名）。
- **底部悬浮栏两条路线（重要，勿混用）**：
  1. **OpenHarmony 兼容路线（当前 dev/feat 分支在用）**：真 `Tabs({barPosition: End, barModifier: CommonModifier})`，用 `CommonModifier` 给**整条 TabBar** 设 `margin/borderRadius/backgroundColor + systemMaterial`，即"一个胶囊 + 沉浸光感"；`uiMaterial`（`ImmersiveMaterial`/`systemMaterial`）在 OpenHarmony SDK 26 中可用。注意：`backgroundColor` 不透明会盖住材质层、`systemMaterial` 必须放在其它样式属性之后。
  2. **官方最佳实践路线（HdsTabs，`feat/immersive-tabbar` 待办）**：官方《沉浸光感》最佳实践 <https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-spatiality-immersive> 与本地文档《设置页签栏的悬浮样式》推荐 `HdsTabs` + `barOverlap(true)` + `barFloatingStyle({ barWidth: {small/medium/large}, barBottomMargin, gradientMask, systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE, materialLevel }, miniBar })`，自带悬浮胶囊形态、渐变遮罩、迷你栏与自适应材质等级。
     ⚠️ **工具链约束**：`@kit.UIDesignKit`（`HdsTabs`/`hdsMaterial`/`HdsTabsFloatingStyle`）**只存在于 HMS/商用 HarmonyOS SDK**（`<DevEco>/sdk/default/hms/...`，内部 `@hms.hds.*`），**我们当前编译用的 OpenHarmony SDK 26.0.0 没有**（kits 无 UIDesignKit、全 SDK grep 零命中）。要用必须把工程切 `runtimeOS: "HarmonyOS"` + SDK 指向 DevEco 内置商用 SDK，并配合 HarmonyOS 运行时（模拟器/真机）与对应签名——属**项目级决策**（与 KICKOFF 的 OpenHarmony API 26 目标冲突），需用户/CodeArts 拍板。
     用户提供的参考片段存档：`~/Documents/cv/cjgg.txt`。
- **主题/语言实现口径**：颜色统一走 `resources/base|dark/element/color.json`（base=亮 / dark=暗，**禁硬编码颜色**，QEMU 无沉浸材质时同样适用）；主题切换调 `ApplicationContext.setColorMode(ConfigurationConstant.ColorMode.*)`、语言调 `setLanguage`，二者**必须在页面加载完成后调用**（本项目在 `onPageShow` 首次执行），设置持久化在 Preferences `themeMode`/`language`。

拆分原则：`common/`、`model/`、`plugins/` 只依赖 ArkTS 标准库 + `libkdeconnect_napi.so` 类型，**不 import ArkUI 组件**（可测性，配合 CodeArts 单测指导）；页面层薄、逻辑下沉。

## 3. ArkTS 工作包（AP-*，与 CPP_GUIDE WP-* 对齐）

| AP | 内容 | 对齐 | 交付 / 验收 |
|---|---|---|---|
| AP-0 | 骨架 + 基线移植 + Win10 构建首验 | WP-0 | ✅ 完成（§1 表） |
| AP-1 | **配对确认（1a/1b 均已完成）**：状态机（不再自动接受；`requestPair/acceptPair/rejectPair/forgetPeer`，区分「本侧发起被确认」与「对端请求」）+ 配对确认模态弹窗 + 设备行配对状态（已配对徽标/等待确认/配对按钮）；**验证码已接真值**（native `getPairVerificationCode(deviceId, timestamp)`，公钥 SPKI DER 算法在 native，ArkTS 只格式化 `AB CD EF 12`，无链路显示占位） | M1 | 连桌面 KDE：桌面发起配对 → 鸿蒙弹验证码 → 双端一致 → 接受 → 配对成功；拒绝路径可用；重启后记住列表仍在 |
| AP-2 | **d.ts v2 payload 契约共定**：与 zcode WP-1 逐字对齐（方法名/事件名/字段名），ArkTS 侧先出提案草案 → 双方定稿 → zcode 实现。方向：`payloadReceived`（含 `payloadTransferInfo`/`payloadSize`）、`payloadProgress`（bytes/total）、接收落盘路径约定（沙箱 `files/kdeconnect/`）、发送侧 `sendPayload` 排队语义 | WP-1 | d.ts v2 定稿并经 CodeArts 评审 |
| AP-3 | **信任设备存储（Preferences 侧完成）**：`TrustStore`（键 `trustedDevices`，JSON 带 `schemaVersion=2`）+ 旧 `rememberedDevices` 自动迁移 + 配对时存对端证书 PEM + 解除配对移除；**已与 WP-2 钉扎对接**（配对登记 `setTrustedCertificate` / 启动回灌 / unpair 先 `removeTrustedCertificate`） | WP-2 | 匹配 WP-2 钉扎：证书变更拒连、限流 error 文案可读化 |
| AP-4 | **插件框架（M2 地基）已完成**：`PluginBase`（能力声明/生命周期/收包回调，`onDestroy` 必达）+ `PluginRegistry`（注册表驱动，禁硬编码 switch）+ `PluginHost`（每设备一份实例、能力交集装载、逐个 try/catch 分发、插件→UI 事件通道 `uiFn`）+ 已落地 `PingPlugin` / `SharePlugin` / `BatteryPlugin`；capabilities 由注册表汇总喂 `native.setCapabilities`（单一来源） | M2 | 注册新插件零改动框架代码；identity 能力协商随插件清单自动更新 |
| AP-5 | iOS 功能集插件逐个实现，**已完成 6/8**：`PingPlugin`（回显+主动发）、`SharePlugin`（**接收**：声明 caps + 文件信息；**发送**：文件页选文件 → 沙箱复制 → `native.sendPayload`）、`BatteryPlugin`（设备行显示 `82% ⚡`）、`ClipboardPlugin`（接收写系统剪贴板；`sendClipboard()` 待 UI 入口）、`FindMyPhonePlugin`（振动 4s，`VIBRATE` 权限，onDestroy 停振）；剩余：RunCommand（受限命令集）、Mousepad/Presenter（输入注入需系统权限，评估中） | M2 | 每个插件连桌面实测通过 |
| AP-6 | 多设备管理、前后台/保活策略、错误恢复重连、全量中文文案、图标与界面打磨 | M3 | 真机/模拟器体验验收 |
| AP-7 | **上架前置**：bundleName 改最终标识（用户定名后一次改 `AppScope/app.json5` + 两处 label）、**改名后 Preferences 迁移逻辑 + 单元测试**（用户要求：开发期保持、上架前改动能正常——迁移代码我写，测试计划按 CodeArts 单测指导，测试代码可由 CodeArts/我分工）、Release 混淆启用评估、隐私政策/权限用途文案（正式前用户确认） | M4/WP-6 | Release HAP 可安装且老用户数据不丢（模拟改名演练） |

排序即优先级：AP-1 与 zcode WP-1 并行（配对 UI 不依赖 payload）；AP-2 是 share 类插件的前置。

### AP-1 详细规划：配对确认弹窗（M1）

**目标**：`kdeconnect.pair` 请求改由用户确认（展示验证码 + 接受/拒绝），替换 PacketRouter 现有「骨架自动接受」；本侧主动配对由 UI 触发；行为与 iOS 端一致（用户 2026-09-12 裁决）。

**1. 每设备配对状态机**（`model/PairingModels.ets` 新增 `PairState`）：
`idle` →（对端请求）`requestedByPeer` →（用户接受）`paired` /（用户拒绝·超时）`idle`；
`idle` →（本侧点配对）`requestedByUs` →（对端确认）`paired` /（拒绝·超时）`idle`；`paired` →（任一侧 unpair）`idle`。
超时阈值：对端请求 60s（iOS 观感），本侧请求 60s。

**2. 验证码算法（跨端一致，v8 追加 timestamp）**：
双方公钥 DER **按字节序排序拼接** → SHA256 → **前 8 位 hex 大写**（v8 再把配对 timestamp 追加进输入）。
本侧证书 `certPem` 已在 Index 持有；**对端证书需 native 提供** → 需 d.ts 扩展提案（见 §5 流程）：
`getPeerCertificate(deviceId: string): string`（返回对端证书 PEM/DER；握手期由 tls_engine 暂存）。此接口是与 zcode 的 M1 依赖项。

**3. PacketRouter 改动**（`net/PacketRouter.ets`）：
- `handlePair(pair=true)`：**不再自动回 {pair:true}**，改回调 `onPairRequest(deviceId, timestamp)` → UI 弹窗；保留时钟偏差 >1800s 拒绝。
- 新增公开方法：`acceptPair(deviceId)`（回 `{pair:true}` + 发 identity）、`rejectPair(deviceId)`（回 `{pair:false}`）、`requestPair(deviceId)`（本侧主动 `{pair:true, timestamp}`）。
- `handlePair(pair=false)` → 视为对端解除配对（已有 `onUnpaired` 钩子）。
- 未配对设备仍只接受 `kdeconnect.pair`，其余包丢弃（既有约束）。

**4. UI**：
- `components/PairingDialog.ets`（`@CustomDialog` + Index 持 `CustomDialogController`）：设备名 + 验证码（大字等宽、分组显示，如 `A1B2 C3D4`）+ 提示「请确认与对端显示一致」+ 接受/拒绝；弹窗类组件属沉浸光感生效范围，后续可上材质。
- 设备页：发现列表设备行加「配对」按钮（连接成功后可用）；记住的设备行显示已配对/解除配对入口。

**5. 与其它工作包联动**：接受后把设备与对端证书指纹写入信任表（AP-3 ↔ zcode WP-2 证书钉扎）；`rememberedDevices` 持久化已就绪（现由骨架自动接受触发，AP-1 改为用户接受后触发）。

**6. 阶段拆分（重要，避免阻塞联调）**：
- **AP-1a**：状态机 + 弹窗 + 拒绝/接受流程；验证码暂显示占位（对端证书未接入时显示 `--`），配对链路本身可用。
- **AP-1b**：d.ts 增加 `getPeerCertificate` → 真实验证码 → 端到端验收。

**7. 验收**：①桌面 KDE 发起配对 → 鸿蒙弹验证码 → 两端一致 → 接受 → 双端显示已配对；②拒绝 → 桌面侧失败、鸿蒙不记住；③重启后记住列表仍在、已配对设备重连不再弹窗；④时钟偏差 >30min 拒绝；⑤解除配对（先发 unpair 再 disconnect）后重新配对可用。

**8. 单测介入点（请 CodeArts 排期）**：验证码算法（纯函数：排序拼接 + SHA256 + 大小写/截断）、状态机迁移（accept/reject/timeout/unpair）、持久化读写（记住列表 JSON 往返 + 改名迁移）。

## 4. 编码规范（ArkTS 严格模式，编译期强制）

- **类型**：禁 `any`/`unknown`/`as unknown as` 双重断言；禁结构化类型——**所有 native 相关类型一律 `import { ... } from 'libkdeconnect_napi.so'`**，禁止本地重声明同构 interface；对象字面量必须有显式类型上下文（先声明 interface/class 再用）；`Record` 字面量键加引号。
- **空安全**：可空值传参前 `?? fallback` 或显式判空；组件状态初始为空用 `T | undefined`，禁非空断言。
- **函数/类**：`async` 必须显式 `Promise<T>`（无返回值 `Promise<void>`）；禁嵌套函数/函数表达式（用箭头）；禁 `#` 私有字段；`throw` 只抛 `Error` 子类。
- **语句**：禁解构赋值；禁正则字面量（用 `new RegExp()`，现有代码中 `replace(/-/g,'')` 随基线保留，新代码勿新增）；禁 `delete`/`for...in`/`globalThis`/`@ts-ignore`。
- **ArkUI**：统一 V1 装饰器家族（`@Component`/`@State`/`@StorageProp`，勿混 V2）；`build()` 内仅 UI 语法；成员名勿与通用属性撞名（`opacity`/`width` 等）；废弃全局 API（`px2vp` 等）走 `this.getUIContext()`；每个 `main_pages.json` 页面恰好一个 `@Entry`。
- **资源**：用户可见文案一律 `$r('app.string.*')`，base(en) + zh_CN **同改动成对更新**；勿用官方 KDE 图标（商标合规）。
- **命名**：文件 PascalCase（页面/组件）/ camelCase（工具）沿用现状；类 CamelCase；常量全大写；注释中文为主、标识符英文。
- **风格**：LF 换行（`.editorconfig` 精神：4 空格缩进、文件末尾换行）；新增文件带 SPDX 头（`GPL-3.0-or-later`，仓库 LICENSE 口径，旧文件 `GPL-2.0-or-later` 随基线不动）。

## 5. NAPI 契约硬规则（ArkTS 侧执行）

1. 类型与函数**只从 `libkdeconnect_napi.so` 导入**，d.ts 是唯一契约源（`entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts`）。
2. **契约变更流程**（硬规则）：DevEco Code 提案（先发 `MSG*_TO_ZCODE.md` 说明动机/语义）→ 双方确认后同一改动更新 d.ts → zcode 按 d.ts 实现 → CodeArts 评审。native 不单方面改 d.ts；ArkTS 不调用 d.ts 之外的符号。
3. 事件回调（`native.init(cb)`）内：**每个 case 全 try/catch**、勿做重活/长循环；事件对象字段全部按可选处理（`?? fallback`）。
4. `native.*` 调用点全部 try/catch，错误进 UI 日志 + hilog，不崩溃。
5. NAPI 方法体内是排队/置标志语义（native 侧约定），ArkTS 勿假设同步完成——结果一律以事件为准。
6. 层间契约：native 必须在**所有**断开路径派发 `disconnected`（旧验证结论），UI 据此清理连接列表；发现该契约被破坏时发消息给 zcode，勿在 ArkTS 侧打补丁掩盖。

## 6. 协议一致性常量（ArkTS 侧，改一处核对 meta/kde/android 三端）

protocolVersion=8；UDP 1716；TCP 1716–1764；payload 端口 ≥1739；单包 32 MiB；identity 包 ≤8 KiB；配对 timestamp 容差 **±1800 秒**（秒，非毫秒）；deviceId 正则 `^[a-zA-Z0-9_-]{32,38}$` 且=证书 CN 且**必须持久化**；证书有效期 −1y→+10y；验证码 = 双方公钥 DER 按字节序排序拼接 + SHA256 前 8 位 hex 大写（v8 追加配对 timestamp）。

实现规则（已验证，勿走样）：
- TCP 是流：`packetReceived.packet` 是**原始读数据**，可能含多帧/半帧——按设备缓冲、按 `\n` 切分、半包留存、非法 JSON 丢该行继续（`PacketRouter.onPacket` 现状即此，勿当单帧 parse）；
- 发送侧组帧**自带 `\n`**；发送队列单写者（防帧交错）；
- identity 包不含证书；必须忽略自己的 deviceId；未配对设备只收 `kdeconnect.pair`；
- `pairingRequest` 事件 ≠ 配对请求（是 TLS 层 identity 帧），只回填设备名；
- packet `type`/`body` 与 schema 逐字一致，新包型先核 schema（经 zcode 代查）再实现。

## 7. 构建与验证（Win10 侧）

- 构建：DevEco Code `build_project`（= `hvigorw assembleHap` 薄封装）或 DevEco Studio GUI；**构建前不动 `local.properties` 的 Linux 侧对应物**（`.stignore` 已排除互不覆盖）。
- 快速静态检查：`arkts_check`（编辑 ets 后先跑，再全量构建）；**编译期检查以 `assembleHap` 为准**。
- lint 面板：Linux 侧 codelinter 被商用 CLT 类型门禁卡死（假象），**lint 结论以 Win10 DevEco 实测为准**（首验③，进行中）。
- 模拟器/真机：装设备优先在用户终端执行（历史约定）；本侧 HAP 未配置签名（`signingConfigs` 空）——模拟器安装运行前需用户在 DevEco 配置自动签名（首验②阻塞项，见 WIN10_LOG）。
- 沉浸光感材质：`uiMaterial` 探测失败静默降级毛玻璃，勿写屏幕日志（QEMU 已知不支持）。
- **ArkUI 组件成员命名坑**：子组件（`@Component`）成员名**不能与通用属性同名**（如 `direction`/`size`/`width`/`opacity`/`backgroundColor`），否则报「Property 'x' in type 'X' is not assignable to the same property in base type 'CustomComponent'」——用领域前缀（`payloadDirection`/`payloadSize`）。
- **Win10 侧签名/装机（2026-09-13 新，方案 A 兼容）**：tracked `build-profile.json5` 的 `signingConfigs` 恒为 `[]`；本机改用**仓库外自签调试脚本** `C:\Users\<user>\.ohos\kdc-sign-win.ps1`（材料在 `C:\Users\<user>\.ohos\kdc-sign\`，机器本地不入库）：
  - 关键技巧：SDK 的 `OpenHarmony.p12` 里带 **`openharmony application ca` 的私钥**，用 `hap-sign-tool generate-app-cert` 以该 CA 签发**自定义 subject 的叶证书**（本项目 `O=Gr1m, OU=Gr1m, CN=KDE-H Connect`），证书链仍是 leaf→App CA→Root CA，**设备照常信任**；团队名即证书 subject 的 O/OU。
  - 用法：`powershell -ExecutionPolicy Bypass -File kdc-sign-win.ps1 -Mode all`（`materials|sign-only|install|all`）；profile 的 `device-ids` 绑定目标设备 UDID（脚本自动取自 `hdc shell bm get --udid`），**换设备需重跑**。
  - 坑：`generate-app-cert` 要求 **subject 密钥与 CA 私钥在同一 keystore**（本方案用 SDK keystore 副本 `gr1m-work.p12` + `generate-keypair` 加入自己的密钥）；keytool 读不了这套老 p12 的私钥（改用 hap-sign-tool）；PowerShell 脚本里**不要用 `$pwd` 当密码变量**（= 当前目录自动变量）。
- **ArkUI 状态刷新坑（易踩；"点击有效但高亮不跟随"的根因）**：`@Builder` 的**值参数变化不会触发刷新**（值传递语义）——选中态/进度等动态内容必须**在 Builder 内部直接读状态**（如 `this.themeMode === mode`），或只传 `id` 进去再在 Builder 内现读（如 `this.payloadOf(transferId)`）。`ForEach` 用稳定 key 时尤其明显：列表项不重建，传进去的旧值会一直显示旧值。
- **两个编译器口径不同（重要）**：Win10 DevEco 编译器宽松，**Linux CLT 会额外报 `arkts-no-implicit-return-types`**——凡作为**函数类型参数**传入的箭头函数（`RouterCallbacks` 字段、`SendFrameFn`/`uiFn`、`native.init` 回调、组件回调 prop）**必须显式标注返回类型**（`(): void => { ... }` / `(): boolean => ...`）。Win10 绿 ≠ Linux 绿：UI 预览用 Win10，**最终构建门禁以 Linux 侧为准**（ZCode MSG49）。
- **工具约定（血泪教训）**：不要用 PowerShell `Get-Content`/`Set-Content`/`-replace` 批量改 `.ets`/`.md`（PS 5.1 按 ANSI 读 UTF-8 → 中文变 `鈥?` 且丢失字节，导致 `Unterminated string literal` 或文档损坏）；一律用编辑工具逐处改，改完先 `arkts_check` 再 `build_project`，改 `.md` 后用 grep 复核中文。
- 每次交付前冒烟：`arkts_check` → `assembleHap` →（有设备时）安装启动看 hilog 关键行（deviceId / packet type / 错误码）。

## 8. 协作纪律（ArkTS 侧执行细则）

- **文件范围**（新仓库）：`entry/src/main/ets/**`、`AppScope/**`、根与 entry 的构建配置（`build-profile.json5`/`hvigorfile.ts`/`hvigor/`/`oh-package.json5`/`code-linter.json5`/`obfuscation-rules.txt`）、`entry/src/main/module.json5`、`entry/src/main/resources/**`、`tools/*.sh`（AP-0 已放入）、`entry/src/main/cpp/types/libkdeconnect_napi/`（契约提案方，与 zcode 共同维护）、`devdocs/ARKTS_GUIDE.md`。
- **不碰**：`entry/src/main/cpp/**` 其余部分（zcode 的）、`devdocs/CPP_GUIDE.md`、`.codeartsdoer/`、`bearssl/`/`json/`（vendor）。
- 同步：Syncthing 双向实时；**同一文件勿两机同改**；Win10 侧 `.stignore` 已镜像 Linux 侧（§7 的产物目录已排除），改动忽略清单须两侧同步手动更新。
- 通信：仓库内 `AgentsConversion/`（正本）。给 zcode `MSG*_TO_ZCODE.md`、给 CodeArts `MSG*_TO_CODEARTS.md`；执行命令前后检查 `USER_SAY.md` 与目录变化；状态维护在本文名片 `AgentsConversion/DEVECO.md`。
- **未经用户明确要求不 commit / 不 push**；何时 commit 骨架基线等 CodeArts 发话（流程总指挥）。
- 跨层改动（d.ts / 跨端常量 / module.json5 权限）先走 §5 流程或发消息对齐。

## 9. 维护

本文档由 DevEco Code 维护；结构、命令、分工、契约流程变化时同改动更新，并在 `AgentsConversion/` 通知各 agent。
