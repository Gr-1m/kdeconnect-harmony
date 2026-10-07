# REVIEW_INDEX_ETS_20260926.md — Index.ets（2128 行）全量评审 + 接线分块改动建议（AtomCode）

> 2026-09-26。对象：远端 `dev/zcodeinit`（`5d3d41c`）`entry/src/main/ets/pages/Index.ets` 全量（约 2128 行）。
> 口径：整体逻辑性——状态归属、事件流、生命周期、层间契约；并给出批次 4 的**接线分块改动建议**（拆分蓝图）。

## 一、现状结构（逐段通读后归块）

| 块 | 大致范围 | 内容 |
|---|---|---|
| A 生命周期/引导 | L178–287, L486–550 | aboutToAppear（Preferences 装载 + 证书自举 + native.init + 插件注册 + RouterCallbacks + pairSession 接线 + eventBus 装配 + 模块注入）、onPageShow、applySettingsIfReady、aboutToDisappear（**native.stop 在此，即 KI-1**） |
| B native 会话/信任 | L591–682, L747–1130 | startNative、persistSettings/persistTrust、handlePaired/handleUnpaired/setPairedFlag、computePairCode、requestPairWith、unpairDevice、manualConnect、isTrusted |
| C 事件分发 | L681–792, L868–1063 | loadPlugins、onPluginEvent、handleEvent（deviceDiscovered/connected/disconnected/deviceLost/error 分支，约 200 行） |
| D UI 动作/卡片 | L1130–1317 | onClipboardPasteResult、runCardAction、onDeviceAction、runCommand、openDeviceDetail、syncSelectedDevice |
| E 文件/平台 I/O | L1317–1527 | ensureKdcDir、pickSaveTarget/pickDownloadTarget、ensureWritePermission、persistPayloadHistory、pickAndSendFile、stageSendJob |
| F 布局/渲染 | L551–590, L1285–1300, L1527–1770 | detectScreenWidth/onRootArea、switchTab、initImmersiveMaterial、tabIcon、menuButton、drawer 三方法、三列表投影（connectedShown/discoveredShown/offlineKnownShown） |
| G build() | L1771–2128 | 背景 + 标题 + 状态条 + 4 Tab（DevicesTab/FilesTab/SettingsTab/LogsTab）+ 4 弹窗（PairConfirm/Mpris/RunCommand/ReceivedFiles）+ 底栏 |

## 二、全量评审结论：✅ 分块质量整体良好，残留职责 5 类

**做得对的（拆分成果真实）**：
1. **单一写者纪律贯穿**：paired 状态只有 `setPairedFlag` 一个写者（handlePaired/handleUnpaired 都收口到它，注释明示 MSG50 §3）；handleUnpaired 里还留下旧双实现的尸检注释（守卫恒假的根因）——历史教训已文档化；
2. **渲染写放大防御系统化**：handleEvent 各分支统一「内容没变不写 @State」口径（deviceDiscovered 去重比对、deviceLost 幂等、connected 先 filter 再 concat）——对应 THREAD_BLOCK_3S/6S 实测根因，属整体设计而非散点补丁；
3. **信任装载与写入的竞态有显式治理**：`trustLoaded`/`pendingKnown` 队列——「启动即连接」时 rememberKnown 拿空表 persist 会截断已知设备（实测丢过条目），现在是先排队、装载完补记；
4. **断链清账完备**：disconnected 分支按清单逐模块清（payload failInflight → batteryItems → pluginHost.unloadForDevice → mpris.forget → forgetSendQueue → pairSession.onDisconnected → syncSelectedDevice）——每一步都有评审条件编号溯源（P2/P3/MSG132 §2 等）；
5. **装配集中**：模块注入（notify/netWatcher/pairSession/mprisController/payloadController 的回调）全部在 aboutToAppear 一次完成，与阶段 3 契约一致。

**残留职责（批次 4 的拆分对象）**：aboutToAppear 承担 5 类初始化（设置装载/信任装载/证书自举/native 启动/插件+路由装配）；handleEvent 200 行事件分发 + 清账清单；文件 I/O 三件套（picker/权限/staging）；UI 动作分发（onDeviceAction 的 key→行为大分支）；断链清账清单内嵌在事件分支里。

**问题点（均非阻塞）**：
- `handleEvent` 的 disconnected 清账清单是**隐性契约**——新增领域（未来插件）必须记得来这里挂一行，漏挂即泄漏；应升级为显式 teardown 注册表（见建议 ⑤）；
- `catch (e) { /* Preferences load failed */ }` 静默吞掉整个装载失败——设置/信任全部回默认值但无日志，与「绝不静默丢弃」的 eventBus 兜底口径不一致；
- `native.stop()` 在 aboutToDisappear（KI-1 已立案，归属 DevEco + CodeArts 裁决，此处不重复展开）。

## 三、接线分块改动建议（批次 4 拆分蓝图）

沿用阶段 3 范式（@Observed controller 持领域状态、平台能力注入、装配集中一处），按「内聚度」而非「行数」分 5 块，**顺序即建议实施顺序**（风险从低到高）：

### ① `state/NativeSessionController`（信任 + 证书 + native 生命周期）——建议先做
- **迁入**：deviceId/certPem/keyPem/router/pluginRegistry/pluginHost 持有；handlePaired/handleUnpaired/setPairedFlag/persistTrust/computePairCode/requestPairWith/unpairDevice/manualConnect/isTrusted；
- **注入**：notify、payloadController.failInflightReceives（断链清账经回调）、UI 副作用（paired 成功提示/选中跳转）经 `onPairedUi` 回调；
- **要点**：trustedDevices/rememberedDevices 是**领域状态**应随迁（页面 UI 读它经 @ObjectLink/投影）；`trustLoaded/pendingKnown` 竞态治理整体随迁，勿拆散；
- **收益**：KI-1 修复（native.stop 挪到 Ability onDestroy）落点就在这里——拆出后 stop 的归属自然清晰。

### ② `state/DeviceRegistry`（设备三列表 + 发现/连接事件）——建议第二
- **迁入**：connectedDevices/discoveredDevices/rememberedDevices、handleEvent 的 deviceDiscovered/connected/disconnected/deviceLost 分支、三列表投影（connectedShown/discoveredShown/offlineKnownShown）、rememberKnown/syncSelectedDevice/isPairedId/liveIds；
- **要点**：①「内容没变不写 @State」的写放大防御必须随迁（这是该模块的存在理由）；② 断链清账中「清自己列表」的部分随迁，**跨模块清账**（payload/mpris/pluginHost）不要搬进来——见 ⑤ 的 teardown 注册表；③ 与 PairSession 关联度高，PairSession 的 connectToPeer/disconnect 副作用经它走，蓝图上两者并列但 PairSession 已拆好，只需对齐接口。

### ③ `common/FilePortal`（文件平台 I/O）——建议第三，纯机械
- **迁入**：ensureKdcDir/pickSaveTarget/pickDownloadTarget/ensureWritePermission/persistPayloadHistory/clearPayloadHistory/stageSendJob（pickAndSendFile 的编排留页面或随 FilesTab 接线）；
- **要点**：这是「领域 I/O 可留、宿主能力必注入」边界讨论（MSG110 建议 3）的试金石——picker/权限/目录属领域 I/O，可直连 Kit；ctx 经一次注入。

### ④ `state/UiActionsController`（卡片动作分发 + 限频）——建议第四
- **迁入**：actionGateMs/actionGate/pruneActionGate、cardBusyKey/releaseCard、runCardAction/onDeviceAction 的 key→行为分发；
- **要点**：onDeviceAction 大分支里每个 case 只是「调某 controller 的方法 + toast」，拆出后 Index 只剩装配；限频器目前被 NetworkWatcher/MprisController 双向注入复用，抽出后成为独立公共件，注入关系反而变直。

### ⑤ `state/TeardownRegistry`（断链清账显式化）——建议与 ② 同步做，成本最小
- **形态**：页面（或 controller）提供 `onDisconnect(id, reason)` 多播注册点；payload/mpris/pluginHandlers/battery/DeviceRegistry 各自注册自己的清账；handleEvent 的 disconnected 分支收敛为一行 `teardown.run(did)`；
- **收益**：把「新增领域必须记得来 disconnected 挂清账」的隐性契约变显式——这是全文件唯一仍在生长的隐性耦合点；改造同时天然覆盖 ①② 的断链路径。

### 实施约束（对全部 5 块）
- 每块一提交、逐块「搬运后 build + ohemu 冒烟」（对齐批次 3 前置）；先做 ⑤+①（KI-1 依赖 ①），③ 纯机械可穿插；② 与 ⑤ 同步；④ 最后；
- 拆完后 Index.ets 预期剩 ~600–800 行：build() + 装配 + onPageShow/applySettingsIfReady + 跨模块胶水——这是页面的正当职责，不必追求归零；
- 装配自检（MSG110 建议 2）建议随 ⑤ 一起落：注册表 + 注入集中后，debug 断言「关键回调非默认值」有了天然落点。

—— Atomcode（glm5.3-flash），2026-09-26
