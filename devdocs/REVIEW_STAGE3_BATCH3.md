# REVIEW_STAGE3_BATCH3.md — 阶段 3 批次 3 评审：SettingsController / PluginEventHandlers / Index 接线 + 已提交 4 commit 抽查

> 2026-09-26。评审人 Atomcode（用户指令：评审新改动）。对象：
> - **工作树在途（批次 3，未提交）**：`state/SettingsController.ets`（69 行，新）、`state/PluginEventHandlers.ets`（66 行，新）、`Index.ets` diff（−150/+70，2128→~2048 行）；
> - **已提交 4 commit 抽查**：`6d17cd1`（版本 0.5.0）/ `f12c4e6`（CI 门禁）/ `cd1a7ee`（E2E 工具链接修复）/ `c19231a`（我方 3×P3 整改）。
> **总体结论：通过。无 P0/P1/P2。1×P3（SettingsController 的 systemName 冗余字段）+ 1×建议（批次 3 提交信息标注步骤 7a/7b）。提交前仍差构建 + ohemu 冒烟（运行时验证）。**

## 一、SettingsController（69 行）——通过

- 4 状态（themeMode/language/deviceName/systemName）+ 4 方法 + `SettingEntry` interface + `DEFAULT_DEVICE_NAME` 常量迁出，Index 旧定义 **0 残留**；
- **逐字保真核验（diff 删除侧 vs 新模块 + 注入闭包）**：
  - `applyTheme`：旧「themeMode=mode → getUIContext 取 hostCtx → setColorMode(colorModeOf) → catch 记日志 → persist 时 persistSettings([{themeMode}])」——新模块 34-41 行 + 注入 `applyColorMode`（437-445）+ `persistEntries`（436）**逐字一致**（try/catch 位置从方法内移到注入闭包，语义等价——Context 相关全留在页面侧，分层正确）；
  - `applyLanguage`：同款结构（setLanguage(languageOf)），一致；
  - `renameDevice`：空名/同名早退、persistSettings、log、`native.stop()`(try/catch ignore) + `startNative()`——新模块 52-61 + 注入 `restartNative`（455-461）**逐字一致**；
  - `useSystemDeviceName`：重新读系统名（避免缓存）→ 写 systemName → log → renameDevice——一致（`systemDeviceName(getUIContext().getHostContext())` 经 `getSystemName` 注入留页面侧）；
- **SettingsTab 接线**：6 个 @Prop 值全部改从 `this.settingsController.*` 读取（1949-1955），回调 4 个（rename/useSystem/applyTheme/applyLanguage）全部走 controller（1956-1966）；`@Prop @Watch('onDeviceNameChanged') deviceName` 草稿同步机制未动——**绑定源从 Index 本地 @State 换成 controller 字段后刷新链路成立**（controller 是页面 @State 实例，@Observed 字段变更驱动 SettingsTab 的 @Prop 同步，与 FilesTab 同款已验证机制）；
- aboutToAppear 536-537：`applyTheme(themeMode, false)` + `applyLanguage(language, false)`（persist=false，启动时只应用不重复落盘）——与旧实现一致；
- **P3-1**：`systemName` 字段（24 行）在 controller 里只被 `useSystemDeviceName` 写（65 行），唯一读者是 SettingsTab 的 @Prop（用于显示系统名占位）——功能正确，但它其实是**页面状态**（UI 显示用）而非领域状态，理想归属是留页面 @State 或随 getSystemName 返回值传递。不阻塞，随批次 4 收尾时顺手归位即可。

## 二、PluginEventHandlers（66 行）——通过

- **零状态模块**（类头注释明确「不持状态，batteryItems/runCommands 仍是页面 @State，经注入回调读写」）——分层判断正确，与 MprisController/PayloadController 的「持状态」形成对照，两种范式并存合理；
- 4 方法**逐字保真核验**（diff 删除侧逐条对照）：
  - `onRunCommandList`：`setRunCommandState`（注入闭包 469-472 写 `runCommandDeviceId` + `runCommands` 两字段——旧实现的两行页面写点完整保留）+ log，一致；
  - `onRunCommandOutput`：嵌套 payload 读 `ev.runOutput`（裁定表 #6 语义）+ undefined 早退 + resText 双文案 + toast 格式 `${head} (exit=${code})[: ${text}]` + log——一致（含注释保留）；
  - `onClipboardRequest`：toast + log，一致（「三方应用无权读剪贴板只能提示」注释保留）；
  - `onBattery`：嵌套 payload 读 `ev.battery` + undefined 早退 + 文本格式 `${charge}%${charging ? ' ⚡' : ''}` + exists 判断 + map/concat 更新 + log——一致；
- **事件路由 7 条完整**（375-381）：runcommand.list/output、clipboard.request、battery 四条改指 `pluginHandlers.*`，mpris.playerList/playerUpdate、systemvolume.sinks 三条仍指页面（属批次 4 范围）——注册数保持 7，装配自检 `plugin routes registered: 7` 未破坏。

## 三、Index 接线 diff（−150/+70）——通过

- 旧 4 设置 @State + 4 方法 + `SettingEntry` + 旧 4 事件方法：**0 残留**（grep 全清零）；
- 两新模块注入装配（435-474）12 个闭包逐条核过，全部转调页面既有实现（persistSettings/setColorMode/setLanguage/systemDeviceName/native.stop+startNative/notify.log/toast/resText/commandsOf/batteryItems）——**页面是唯一碰 Context/UI/native 的地方**，分层与批次 1/2 同构；
- `SettingEntry` import 改自 `state/SettingsController`（52 行）——interface 单一来源成立；
- Index 行数 2128→~2048（批次 3 后），方向 A 剩余工作量进一步收敛到批次 4（handleEvent 枢纽）+ 步骤 9 收尾。

## 四、已提交 4 commit 抽查——全部通过

| commit | 内容 | 核查结果 |
|---|---|---|
| `6d17cd1` 版本 0.5.0 | versionName 0.2.0→0.5.0 / versionCode 2→3，commit 消息附阶段核对依据 | ✅ 与 ROADMAP 阶段表一致（阶段 1-2 完成） |
| `f12c4e6` CI 门禁 | `.github/workflows/native-tests.yml` + `.gitcode/` 同构份：`cargo test` + `tests/run.sh`（仅依赖 gcc/g++/make/Rust，无需 OHOS 工具链）+ EMULATOR_NOTES 导入修正 3 处悬挂引用 | ✅ workflow 结构正确（ubuntu-latest，两步 job）；commit 自述本地已验 cargo 24 passed / run.sh exit=0；**孵化 checklist #12（REUSE CI）之外补齐了 native 回归门禁，KDE Review 加分** |
| `cd1a7ee` E2E 工具 | `run_desktop.sh` 链接列表补 `net_stack_link.cpp` + `net_stack_discovery.cpp`（net_stack 拆分后未同步导致的 undefined reference） | ✅ 最小修复，根因正确 |
| `c19231a` 我方 3×P3 整改 | P3-C hilog `%{public}` 掩码 / P3-B DeferredLogFlush 逐行按级 / P3-A signingConfigs 门禁正则 | ✅ **逐条读源验证**：P3-C 已补 `%{public}d`/`%{public}s`（napi_events.cpp:174）；P3-B 已改逐行按级别冲刷（net_log.h:57-69，缓冲格式=级别字符+正文，注释载明原缺陷）；P3-A 验证记录在案（BUILD SUCCESSFUL + run.sh exit=0）。整改与我方评审意见逐条对应，无扩大化改动 |

## 五、结论与提交前置

- **批次 3 通过**：两新模块逐字保真（8 方法逐一对照 diff 删除侧）、注入装配 12 闭包核过、路由 7 条未破坏、SettingsTab 绑定源切换后刷新链路成立（与 FilesTab 同款已验证机制）；
- **P3-1**：`SettingsController.systemName` 属 UI 显示状态而非领域状态，建议批次 4 收尾时归位（不阻塞）；
- **提交前置**（Omp 执行）：`assembleHap` BUILD SUCCESSFUL + ohemu 冒烟（本批无运行时证据）；commit 建议同时标注步骤 7a/7b 与本报告。

—— Atomcode（glm5.3-flash），评审工作负责人
