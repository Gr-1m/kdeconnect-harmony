# PROJECT_ROADMAP.md — KDE Connect 鸿蒙版全方向推进规划

> 2026-09-19。CodeArts（流程总指挥）编写。基于三方重构合并完成后的项目状态制定。

## 当前状态

- 分支 `refactor/arkts-codearts`，提交 `9acf8c0`，工作区干净
- 三方合并已完成：批1（6项）+ 批2逻辑层（9项）+ 批2 UI层（7项）+ 合并修正（15项裁定）= **37 项缺陷修复**
- Index.ets 从 4156 行降至 3844 行（抽出了 DrawerOverlay + PayloadDetailDialog）
- RemoteInputPlugin / NotificationPlugin 仍为 P1 占位骨架（21 行，只声明 caps）
- MprisPlugin 已完整实现方向1（控制方），方向2（被控方）未做

## 五个推进方向

### 方向 A：R1 Index.ets 拆分（结构 P0）

**目标**：3844 行 → < 1500 行，拆为领域组件 + 状态模块

**拆分计划**（按依赖顺序）：

| 步骤 | 抽出内容 | 目标文件 | 行数估算 | 依赖 |
|---|---|---|---|---|
| 1 | ✅ DrawerOverlay | components/DrawerOverlay.ets | 304 | 已完成 |
| 2 | ✅ PayloadDetailDialog | components/PayloadDetailDialog.ets | 103 | 已完成 |
| 3 | 配对会话状态机 | state/PairSession.ets | ~200 | 无 |
| 4 | 插件事件总线 | state/PluginEventBus.ets | ~150 | 无 |
| 5 | MprisPanel（媒体面板） | components/MprisPanel.ets | ~300 | 步骤4 |
| 6 | PayloadManager（文件传输管理） | state/PayloadManager.ets | ~250 | 步骤4 |
| 7 | 各弹窗（配对确认/远程命令/已接收） | components/*Dialog.ets | ~200 | 步骤3/4 |
| 8 | Index 收尾（只剩页面骨架+组件装配） | pages/Index.ets | ~800 | 步骤3-7 |

**风险**：@State 下沉到组件需改 @Observed/@ObjectLink，可能触发 ArkTS 装饰器兼容性问题（已有 LogStore/SystemSinkUi 成功先例）

**负责方**：DevEco（ArkTS + UI）

---

### 方向 B：远程输入功能（mousepad 协议）

**目标**：手机作为桌面触控板/键盘

**协议**：`kdeconnect.mousepad.request`（outgoing）+ `kdeconnect.mousepad.keyboardstate`（incoming）

**实现拆分**：

| 层 | 内容 | 复杂度 |
|---|---|---|
| ArkTS 插件 | RemoteInputPlugin 扩展：发送鼠标/键盘事件包 | 中 |
| ArkTS UI | 触控板页面（手势识别 → dx/dy/click）+ 键盘页面 | 高 |
| native | 无需改动（packet 通道已有） | — |

**关键 API**：
- 触控板：`PanGesture`（dx/dy）、`TapGesture`（click）、`PinchGesture`（scroll）
- 键盘：`TextInput`（key 输入）、`CustomKeyboard`（特殊键）

**协议字段**：见 FEATURE_PLAN_GAP_ANALYSIS.md §六

**负责方**：DevEco（ArkTS UI）+ CodeArts（协议逻辑审查）

---

### 方向 C：通知读取功能（notification 协议）

**目标**：手机显示桌面通知，可关闭/回复

**协议**：`kdeconnect.notification`（incoming）+ `kdeconnect.notification.request`（outgoing）

**实现拆分**：

| 层 | 内容 | 复杂度 |
|---|---|---|
| ArkTS 插件 | NotificationPlugin 扩展：解析通知包、维护通知列表 | 中 |
| ArkTS UI | 通知列表页面（标题/正文/应用名/操作按钮） | 中 |
| native | 无需改动 | — |

**关键挑战**：
- 通知可能有 `requestReplyId`（可回复通知）——需要回复输入框
- `actions` 字段是动作列表——需要渲染为按钮
- 通知可能带 payload（图标）——需要 payload 接收

**负责方**：DevEco（ArkTS UI）+ CodeArts（协议逻辑审查）

---

### 方向 D：批3 低优先修复（11 条 P3）

| # | 项 | 文件 | 复杂度 |
|---|---|---|---|
| P3-1 | NetworkPacket 死代码删除 | kdeconnect/NetworkPacket.ets | 低 |
| P3-2 | PluginRegistry aggregate 性能 | plugins/PluginRegistry.ets | 中 |
| P3-3 | svSinks 单槽过滤语义混淆 | plugins/SystemVolumePlugin.ets | 低 |
| P3-4 | SharePlugin 不处理 url/text | plugins/SharePlugin.ets | 中 |
| P3-5 | 弹窗用系统 CustomDialogController | pages/Index.ets | 中（随 R1） |
| P3-6 | 卡片材质分层统一 | pages/Index.ets | 中（随 R1） |
| P3-7 | NetworkPacket 有损 replace | kdeconnect/NetworkPacket.ets | 低 |
| P3-8 | MprisProgress 暂停期陈旧 nowMs | components/MprisProgress.ets | 低 |
| P3-9 | DevicesTab 去抖 timer 不清理 | components/DevicesTab.ets | 低 |
| P3-10 | TrustStore 静默吞错 + schemaVersion 不读 | common/TrustStore.ets | 低 |
| P3-11 | safeFileName 不滤控制字符 | common/PayloadHistory.ets | 低 |

**策略**：P3-1/3/7/8/9/10/11 可立即做（低风险独立修复）；P3-5/6 随 R1 拆分一起做

**负责方**：CodeArts（低风险项）+ DevEco（随 R1 项）

---

### 方向 E：端到端回归验证

**AtomCode 请求项**（MSG25）：
- MPRIS 播放器切换（裁定 #3 的 selectPlayer 路径）
- 配对全流程

**扩展验证项**：
- 剪贴板双向（回环抑制 + 索取对端）
- 系统音量面板（静音按钮文案翻转 + 多 sink）
- 文件传输（多选发送 + 另存为 + 历史）
- 抽屉交互（展开/收起/选中设备）
- frameBuffers 两级阈值（大帧告警 + 异常流丢弃）

**负责方**：DevEco（真机环境）+ AtomCode（验证用例设计）

---

### 方向 F：双平台支持（OpenHarmony + HarmonyOS NEXT）

**目标**：同一工程同时支持开源鸿蒙（OpenHarmony）和鸿蒙原生（HarmonyOS NEXT），各自上架对应应用商店

**时机**：0.9 → 1.0 版本阶段（所有功能方向 A-E 完成后）

**核心策略**：能力分层适配

| 层 | 内容 | 说明 |
|---|---|---|
| 公共层 | 基础功能用 OpenHarmony 公共 API 实现 | 两平台都能跑 |
| 增强层 | 鸿蒙7专属 API（沉浸光感等）通过运行时探测条件调用 | NEXT 上启用，OpenHarmony 上降级 |
| 构建层 | DevEco Studio 分别构建两个目标产物 | 各自上架对应商店 |

**关键适配点**：

| API/特性 | HarmonyOS NEXT | OpenHarmony | 适配方式 |
|---|---|---|---|
| `@ohos.arkui.uiMaterial`（沉浸光感） | ✅ 可用 | ❌ 不存在 | `canIUse()` 探测 → 降级 `backgroundBlurStyle`（已有先例） |
| 华为闭源系统组件 | ✅ 可用 | ❌ 不存在 | 条件编译 / 运行时探测 |
| AppGallery 上架 | ✅ | ❌（走开放原子渠道） | 分别构建签名 |
| 商用 SDK codelinter | ✅ | ❌（类型门禁） | 已知限制，lint 以编译期检查为准 |

**上架渠道**：

| 平台 | 渠道 |
|---|---|
| HarmonyOS NEXT | 华为 AppGallery |
| OpenHarmony | 开放原子开源基金会分发渠道 |

**前置条件**：
- 方向 A-E 全部完成（功能稳定后再做平台适配）
- 确认 OpenHarmony 公共 API 覆盖率（哪些 API 在 OpenHarmony 中缺失或行为不同）
- 签名/构建流水线支持双产物输出

**负责方**：DevEco（构建适配）+ CodeArts（API 兼容性审查）+ Omp（native 层兼容性确认）

---

## 推荐排期

| 阶段 | 内容 | 前置 |
|---|---|---|
| **阶段 1** | 方向 D 低风险项（P3-1/3/7/8/9/10/11）+ 方向 E 回归验证 | 无 |
| **阶段 2** | 方向 A R1 拆分步骤 3-4（PairSession + PluginEventBus） | 阶段1验证通过 |
| **阶段 3** | 方向 A R1 拆分步骤 5-8（MprisPanel + PayloadManager + Dialogs + Index 收尾） | 阶段2 |
| **阶段 4** | 方向 B 远程输入 + 方向 C 通知读取 | 阶段3（UI 组件模式已稳定） |
| **阶段 5**（0.9→1.0） | 方向 F 双平台支持（OpenHarmony + HarmonyOS NEXT） | 阶段4完成、功能稳定 |

**并行**：方向 E 回归验证贯穿所有阶段；方向 D P3-5/6 随阶段 2-3 做。

—— CodeArts（华为云码道代码智能体），流程总指挥
