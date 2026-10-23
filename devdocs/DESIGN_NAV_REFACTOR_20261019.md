# 0.8.1 UI 改造方案：HdsSideBar → SideBarContainer（v4）

> 2026-10-22 v4。撰写：CodeArts。
> **v4 变更**：① NavPrototype P1'' 已修复（浅色主题文字写死 #e2e8f0）；② MSG156 派单 4 项 Index.ets UI 修复已完成（汉堡 SVG、遮罩点击关闭、平板去多余汉堡、设备页空状态）；③ 双端 ohemu 验证全部通过（AtomCode MSG153）；④ 角色分工更新（AtomCode=总指挥+唯一 commit/push / CodeArts=全权 ArkTS / Omp=纯 Native）；⑤ 工作流变更（Linux 端全闭环）。
> **v3 变更**：基线从 Navigation Split 改为 SideBarContainer（CodeArts MSG161 裁决，依据 AtomCode MSG151 ohemu 实证 + 用户 2026-10-20 确认方向）。
> v2 评审反馈已整合（Omp 7 点 + AtomCode 全文通过）。
> 代码基线：NavPrototype.ets（SideBarContainer 实现）已就绪，P1/P2/P1'' 全部修复。Index.ets 交互修复已完成（MSG156），等待整批提交。

---

## 1. 背景与动机

### 1.1 HdsSideBar 缓存问题（P0，已确认无解）

DevEco MSG159 实测确认：HdsSideBar 会缓存 `sideBarPanelBuilder` 构建出的子树，父级任何重跑都不会重新求值。4 种数据传递机制全部失败：

| 尝试 | 机制 | 结果 |
|---|---|---|
| ① | 页面 builder 闭包直接读 @Observed 控制器 | 页面不重跑 ⇒ 面板停在初始空态 |
| ② | SideBarPanelHost 用 @ObjectLink controller | 父级 builder 子树被缓存 ⇒ 订阅未重建 |
| ③ | 页面 @State 快照 + @Watch | 同上原因 |
| ④ | AppStorage + @StorageLink | 4 个列表键可刷新，但 2 个 @Prop（selectedDeviceId/requestedPairIds）仍被钉死 |

AtomCode MSG148 确认：@StorageLink 是 HdsSideBar 框架下唯一有效绕行，非根解。根解 = 移除 HdsSideBar。

### 1.2 双平台支持（用户 2026-10-14 确认）

- 单一仓库 `kdeconnect-ohos`，一套代码
- 放弃 HDS 组件（HdsSideBar/HdsNavigation/HdsTabs），改用标准 ArkUI
- HarmonyOS 专属能力（ImmersiveMaterial 等）用 try/catch 探测降级
- `build-profile.json5` 定义两个 product：`default`（HarmonyOS）和 `openharmony`

### 1.3 系统应用真机取证（DevEco MSG160）

系统「文件管理」和「设置」的 UI 组件树互相印证：

```
Navigation (Split 模式)
├─ NavBar                        ← Navigation 的栏位内容（非独立组件）
│   ├─ HdsTitleBar               ← 侧栏自己的标题栏
│   └─ List / ListItem
└─ NavDestination                ← 内容
    ├─ HdsTitleBar               ← 内容自己的标题栏
    ├─ Tabs / TabContent
    └─ SymbolGlyph + MaskBlur
```

**关键结论**：系统用 `Navigation` 组织布局，NavBar 是 Navigation 的栏位内容概念（由 Navigation 自动管理），不是可独立调用的 `NavBar()` 子组件。

---

## 2. 当前架构

### 2.1 build() 结构

```
Stack()
└─ HdsSideBar(AUTO)
    ├─ sideBarPanelBuilder → SideBarPanelHost → DrawerOverlay
    └─ contentPanelBuilder → Stack
        ├─ 背景渐变 + 光斑
        ├─ HdsNavigation
        │   └─ HdsTabs
        │       ├─ TabContent(设备/文件/设置/日志)
        │       .barFloatingStyle(悬浮胶囊 + systemMaterialEffect)
        │   .titleBar(HdsNavigationTitleBarOptions)
        │   .bindToScrollable([4个Scroller])
        ├─ 弹窗层
```

### 2.2 数据流（侧栏面板）

```
DeviceController (@Observed)
    ↓ connectedShown() / discoveredShown()
syncSideBarLists()  ← @Watch(drawerOpen) 触发
    ↓ 写入 AppStorage（4个键）
SideBarPanelHost (@StorageLink 订阅 4个键)
    ↓ 传给 DrawerOverlay
    ├─ connectedList / discoveredList / rememberedCount / deviceSection ← 可刷新
    └─ selectedDeviceId / requestedPairIds (@Prop) ← 被缓存钉死，不可刷新
```

---

## 3. 目标架构

> **v3 变更**：基线从 Navigation Split + Stack overlay 改为 **SideBarContainer**。
> Navigation Split 方案废弃，理由：① SideBarContainer 是官方专用侧栏容器，内置 Overlay/Embed 响应式 + 系统控制按钮位；② AtomCode MSG151 ohemu 实证 4 项全通过；③ 用户 2026-10-20 确认方向（参考代码为 ResponsiveLayout SidebarView）。
> AtomCode MSG149 Q2（.title()+.menus() 标题栏方案）**对 SideBarContainer 不适用**——SideBarContainer 无 Navigation 标题栏槽位，标题/菜单需按侧栏内自建或系统 controlButton 另行设计。
> Q3/Q4 结论保留，附注"按新基线复核"。

### 3.1 SideBarContainer 结构说明

`SideBarContainer` 是 ArkUI 官方专用侧栏容器组件，内置响应式行为：

- **SideBarContainerType.Overlay**（窄屏）：侧栏浮在主内容之上，可收起/展开
- **SideBarContainerType.Embed**（宽屏）：侧栏与主内容并排，侧栏常驻
- **auto**：根据容器宽度自动切换 Overlay/Embed（通过 `showSideBar` + 断点监听实现）
- **系统控制按钮位**：`controlButton` 属性提供内置侧栏开关按钮

### 3.2 新 build() 结构（基于 NavPrototype.ets）

```
SideBarContainer(SideBarContainerType.Overlay)
├─ sideBarBuilder → Column(侧栏面板)
│   ├─ 背景色 #1e293b（实色，ohemu 实证不透明）
│   ├─ 汉堡按钮 Image(open_sidebar) 40x40 ← 关闭侧栏
│   └─ DrawerOverlay(直接渲染)
├─ contentBuilder → Stack
│   ├─ 背景渐变 + 光斑
│   ├─ Tabs(标准)
│   │   ├─ TabContent(设备/文件/设置/日志)
│   │   .barPosition(End) .barOverlap(true)
│   ├─ 标题栏（自建 Row：汉堡 + 标题 + 菜单）
│   │   ├─ Image(open_sidebar) 40x40 ← 打开侧栏（visibility: !drawerOpen ? Visible : None）
│   │   ├─ Text(currentTabTitle())
│   │   └─ 四点菜单按钮
│   └─ 弹窗层
├─ .showSideBar(drawerOpen)
├─ .autoHide(false)
├─ .sideBarWidth(isSmallScreen ? '80%' : '30%')
└─ .controlButton({ ... }) ← 系统控制按钮位
```

### 3.3 标题栏方案

> **注意**：v2 的 `.title(CustomBuilder)` + `.menus()` 方案基于 Navigation 标题栏槽位，**对 SideBarContainer 不适用**。

SideBarContainer 无 Navigation 标题栏槽位，标题/菜单需在主内容区 Stack 内自建 Row：

```
Row()
├─ Image($r('app.media.open_sidebar')) 40x40 ← 汉堡按钮，onClick → drawerOpen = true
│   .visibility(!drawerOpen ? Visible : None) ← 侧栏打开时隐藏避免重叠
├─ Text(currentTabTitle()) ← 标题文字，随页签切换
└─ SymbolGlyph(dot_grid_2x2) ← 四点菜单，onClick → openTabActions()
```

**已验证项**（AtomCode MSG151/152/153 + CodeArts MSG160/161/162）：
- [x] 标题栏安全区避让正确（statusBar 38.85vp）
- [x] 汉堡按钮改 Image 40x40，对齐 ResponsiveLayout 参考实现
- [x] Overlay 打开态主内容汉堡自动隐藏，不再与侧栏汉堡重叠
- [x] 浅色主题侧栏文字/图标写死 #e2e8f0（P1'' 修复，AtomCode MSG153 验证）
- [x] 侧栏背景实色 #1e293b（P1 修复，双端验证通过）
- [x] Overlay 遮罩点击关闭（P2 修复，双端验证通过）
- [ ] 系统语义色在真机上的效果（待 DevEco 真机验证）

### 3.4 TabBar 方案（回应 Omp 意见 #2）

标准 `Tabs` 替代 `HdsTabs`——**不是无影响替换**，以下差异列为明确的视觉验收项：

| HdsTabs 特性 | 标准 Tabs 替代 | 视觉差异 | 验收标准 |
|---|---|---|---|
| `barFloatingStyle`（悬浮胶囊） | `barOverlap(true)` + padding | 胶囊悬浮感可能丢失 | 真机截图对比 |
| `systemMaterialEffect`（沉浸光感） | `barBackgroundBlurStyle(Regular)` | 材质感降级为普通毛玻璃 | 真机截图对比 |
| `gradientMask` | 移除 | 已修复（本次 commit） | — |
| `HdsTabsController` | `TabsController` | API 等价，无差异 | 编译通过 |
| `adaptToHandedness` | 无替代 | 单手适配丢失 | 非关键 |
| 胶囊尺寸/间距 | 标准 BottomTabBarStyle | 尺寸/间距可能不同 | 真机截图对比 |

**视觉验收项**（DevEco 真机执行）：
1. TabBar 悬浮感：标准 Tabs + barOverlap 是否能模拟悬浮效果
2. TabBar 材质：barBackgroundBlurStyle(Regular) 的毛玻璃效果
3. TabBar 胶囊尺寸：图标 + 文字的尺寸/间距是否可接受
4. 底部避让：bottomAvoidVp() 在标准 Tabs 下是否仍然正确

### 3.5 侧栏方案（SideBarContainer 内置响应式）

> **v3 变更**：不再需要手动实现 Overlay/Split 切换，SideBarContainer 内置响应式。

SideBarContainer 通过 `SideBarContainerType` 自动处理响应式：

- **窄屏（SM 断点）**：`SideBarContainerType.Overlay`，侧栏浮在主内容之上，`showSideBar` 控制显隐
- **宽屏（MD/LG 断点）**：`SideBarContainerType.Embed`，侧栏与主内容并排常驻

侧栏宽度：
- 窄屏：80%（对齐 ResponsiveLayout 参考实现）
- 宽屏：30%（对齐系统应用 NavBar 实测宽度比例）

侧栏背景：实色 `#1e293b`（项目深空色板），ohemu 实证不透明穿透（v2 的 `$r('sys.color.comp_background_secondary')` 在 ohemu 不生效，CodeArts MSG160 已修复）。

**阶段 B 补充**（AtomCode MSG151 P3）：
- 断点旋转监听：`widthBp` 需挂断点变化监听（当前仅 aboutToAppear 检测一次）
- `getDefaultDisplaySync()` 缓存一次读取
- mock 数据接真实 controller

### 3.6 新数据流（侧栏面板）

```
DeviceController (@Observed)
    ↓ connectedShown() / discoveredShown()
DrawerOverlay（直接在 build() 中渲染，每次 build() 重跑都重新求值）
    ├─ connectedList / discoveredList / rememberedCount ← 可刷新 ✓
    ├─ selectedDeviceId / requestedPairIds ← 可刷新 ✓（不再被缓存钉死）
    └─ deviceSection ← 可刷新 ✓
```

**核心收益**：移除 HdsSideBar 缓存层后，DrawerOverlay 的所有 @Prop 都能正常刷新，不再需要 AppStorage 绕行机制。

---

## 4. 渐进式实施策略（回应 Omp 意见 #6）

**不一次性删除旧代码**，分两个阶段：

### 阶段 A：最小原型验证

目标：在保留旧代码的前提下，验证新架构的核心可行性。

1. **新建 `build()` 方法体**（不删除 `sideBarPanel/contentPanel/titleBarOptions/titleBarMenuOptions`）
2. **保留 `SideBarPanelHost.ets`**（不删除，暂不引用）
3. **保留 `syncSideBarLists` 和 AppStorage 写入**（不删除，暂不调用）
4. **保留 `sideConnected/sideDiscovered` @State**（不删除，暂不使用）
5. **保留 `HdsTabsController` 类型**（改为 `TabsController`，但旧代码已不引用）

验证项：
- [ ] `hvigorw assembleHap` 编译通过
- [ ] 四页 Tabs 切换正常
- [ ] 侧栏 overlay 数据刷新正常（selectedDeviceId/requestedPairIds）
- [ ] 标题栏 CustomBuilder 安全区避让正确
- [ ] 横屏 Split 模式侧栏常驻正常
- [ ] 弹窗层不受影响

### 阶段 B：清理废弃代码

阶段 A 验证通过后，删除：
- `sideBarPanel()` builder
- `contentPanel()` builder
- `titleBarOptions()` 方法
- `titleBarMenuOptions()` 方法
- `syncSideBarLists()` / `sameDeviceIds()` / `onDrawerStateChanged()`
- `sideConnected` / `sideDiscovered` @State
- `SideBarPanelHost.ets` 文件
- import 中的 `@kit.UIDesignKit`

---

## 5. 改动清单

### 5.1 阶段 A — NavPrototype.ets（已完成）

NavPrototype.ets 原型已就绪，基于 SideBarContainer 实现：

| # | 内容 | 状态 |
|---|---|---|
| 1 | SideBarContainer(Overlay) + sideBarBuilder + contentBuilder | ✅ 完成 |
| 2 | 响应式断点检测（SM → Overlay, MD/LG → Embed） | ✅ 完成 |
| 3 | 侧栏 DrawerOverlay 直接渲染 | ✅ 完成 |
| 4 | 主内容区 Tabs + 标题栏自建 Row | ✅ 完成 |
| 5 | 汉堡按钮 Image(open_sidebar) 40x40 | ✅ 完成（MSG160 修复） |
| 6 | 侧栏实色背景 #1e293b | ✅ 完成（MSG160 修复 P1） |
| 7 | 主内容汉堡 visibility 控制 | ✅ 完成（MSG160 修复 P2） |
| 8 | 安全区换算（statusBar/navBar） | ✅ 完成（AtomCode MSG151 验证） |
| 9 | 浅色主题文字/图标写死 #e2e8f0 | ✅ 完成（P1'' 修复，AtomCode MSG153 验证） |

### 5.2 阶段 A — Index.ets 接线（待阶段 B）

> **注意**：MSG156 的 4 项交互修复已在当前 Index.ets 上完成（汉堡 SVG、遮罩点击关闭、平板去多余汉堡、设备页空状态），但这些是在 **HdsSideBar 框架内** 的修复，不是 SideBarContainer 接线。

阶段 A 验证通过后，将 NavPrototype 的 SideBarContainer 架构接线到 Index.ets：

| # | 位置 | 改动 |
|---|---|---|
| 1 | :10 import | 移除 `@kit.UIDesignKit` 整行 |
| 2 | :165 | `HdsTabsController` → `TabsController` |
| 3 | :143 | 移除 `@Watch('onDrawerStateChanged')` |
| 4 | :192-193 | 移除 `syncSideBarLists()` 调用 |
| 5 | :1844-1868 | 重写 `build()`（SideBarContainer + Tabs + 标题栏 + 弹窗） |

### 5.3 阶段 B — 清理（阶段 A 验证通过后）

| # | 位置 | 改动 |
|---|---|---|
| 7 | :1238-1255 | 删除 `titleBarMenuOptions()` |
| 8 | :1318-1386 | 删除 `titleBarOptions()` |
| 9 | :1516-1540 | 删除 `sideBarPanel()` builder |
| 10 | :1542-1842 | 删除 `contentPanel()` builder |
| 11 | :1159-1199 | 删除 `syncSideBarLists/sameDeviceIds/onDrawerStateChanged`（保留 `closeDrawer`） |
| 12 | :140-141 | 删除 `sideConnected/sideDiscovered` @State |
| 13 | — | 删除 `SideBarPanelHost.ets` 文件 |
| 14 | — | 删除 `NavPrototype.ets`（接线完成后） |

### 5.3 不变的部分

- `aboutToAppear()` 主体（仅移除 `syncSideBarLists()` 调用）
- `deviceTabView/filesTabView/settingsTabView/logsTabView` builders
- `statusBar()` builder
- `tabIconModifier()` / `tabIcon()`
- `bottomAvoidVp()`
- `initImmersiveMaterial()`（卡片仍用 uiMaterial 探测）
- 所有弹窗组件
- 所有 state/ 目录下的控制器
- 所有 components/ 目录下的其他组件
- `DrawerOverlay.ets`（保持不变，直接在 build() 中渲染）

---

## 6. 损失的能力与视觉验收

| 损失 | 影响 | 降级方案 | 验收方式 |
|---|---|---|---|
| 标题栏滚动渐变模糊 | 标题栏不再随滚动产生模糊渐变 | 标题栏固定 `backgroundBlurStyle` | 真机截图 |
| 标题栏沉浸光感材质 | 标题栏不再有沉浸光感效果 | `backgroundBlurStyle(Regular)` | 真机截图 |
| TabBar 悬浮胶囊材质 | TabBar 不再有沉浸光感胶囊 | `barBackgroundBlurStyle(Regular)` | 真机截图对比 |
| TabBar 胶囊尺寸/间距 | 标准 BottomTabBarStyle 尺寸可能不同 | 调整 fontSize/padding | 真机截图对比 |
| `bindToScrollable` | 标题栏不再与滚动联动 | 无（标准 Navigation 不支持） | — |
| `dynamicHideTitleBar` | 标题栏不能上滑隐藏 | 无（标准 Navigation 不支持） | — |

---

## 7. 风险与缓解

| 风险 | 缓解 |
|---|---|
| `.title(CustomBuilder)` 安全区避让不正确 | 阶段 A 先验证；备选 `.title(ResourceStr)` + `.menus()` |
| `.title(CustomBuilder)` 系统语义色不生效 | 阶段 A 先验证；备选用硬编码颜色 + `@StorageProp('statusBarHeightPx')` 手动避让 |
| 标准 Tabs 悬浮胶囊观感差距大 | 阶段 A 真机截图对比；视觉打磨留到 0.8.2 |
| 侧栏 overlay 动画不如 HdsSideBar 流畅 | 用 `animateTo` 实现淡入/滑动动画 |
| DrawerOverlay `@Link drawerExpanded` 引用绑定 | 用 `$drawerExpanded` 语法确保双向绑定 |
| 横屏 Split 模式与竖屏 Overlay 切换 | `isLandscape` @State 驱动条件渲染 |
| 回退需要可对照基线 | 阶段 A 保留旧代码；阶段 B 才清理 |

---

## 8. 基线同步

- NavPrototype.ets（SideBarContainer 实现）已就绪，P1/P2/P1'' 全部修复（CodeArts MSG160 + P1'' 修复）
- AtomCode MSG151 ohemu 验证 4 项通过（响应式结构/设备列表/Tab 栏/安全区）
- AtomCode MSG153 双端全量验证：P1/P2 修复双端确认 + P1'' 新发现并已修复
- **NavPrototype 原型验证阶段完成**，所有已知问题已修复
- **Index.ets MSG156 交互修复已完成**（汉堡 SVG、遮罩点击关闭、平板去多余汉堡、设备页空状态），构建通过，等待 AtomCode 双端复验 + 整批提交
- **阶段 A 接线前**：等 AtomCode 复验 MSG156 修复通过并整批提交
- **阶段 A 接线后**：构建验证通过再提交，提交时附构建号

---

## 9. 评审反馈整合

### Omp 7 点意见回应

| # | 意见 | 回应 |
|---|---|---|
| 1 | NavBar 不是独立组件 API | §3.1 已修正：NavBar 是 Navigation 的栏位概念，不是独立组件；方案不使用 NavBar/NavDestination 路由结构 |
| 2 | HdsTabs → 标准 Tabs 不是无影响替换 | §3.4 已明确列为视觉验收项，附对比表和验收标准 |
| 3 | 横屏需求未实现 | §3.5 已添加横屏 Split 模式方案（侧栏 30% + 内容 70%） |
| 4 | 标题和菜单方案待验证 | §3.3 已标注为 P1 待验证项，附备选方案 |
| 5 | 侧栏 Row 布局描述不充分 | §3.5 已详细描述 Overlay 和 Split 两种模式，含遮罩/返回键/状态保留 |
| 6 | 过早删除绕行机制 | §4 已改为渐进式实施：阶段 A 保留旧代码，阶段 B 才清理 |
| 7 | 文档基线需要同步 | §8 已说明：等 Omp push 后固定基线 |

### AtomCode 评审

- MSG149：全文通过，附两前置条件（横屏 Split 批准 + oh-package.json5 修复）+ 四问结论
- MSG151：ohemu 验证 4 项通过 + P1 侧栏透明 + P2 汉堡重叠 + 方向差异建议 SideBarContainer 转正
- **方向裁决**（CodeArts MSG161）：SideBarContainer 转正，Navigation Split 废弃
- MSG149 Q2（.title()+.menus() 标题栏方案）对 SideBarContainer 不适用，已留痕
- **MSG156 派单**（AtomCode → CodeArts）：Index.ets 4 项交互修复 + NavPrototype P1''，全部完成（CodeArts MSG168）
- **角色分工**（2026-10-21 用户指令 + AtomCode MSG154）：AtomCode=总指挥+唯一 commit/push / CodeArts=全权 ArkTS / Omp=纯 Native / DevEco 暂停
- **工作流**（2026-10-22 用户指令 + AtomCode MSG157）：常规开发循环全部 Linux 端闭环（改码→构建→ohemu 双端→commit/push），不再经 Win10

---

—— CodeArts（glm-5.2-sft-harmony），2026-10-22 v4
