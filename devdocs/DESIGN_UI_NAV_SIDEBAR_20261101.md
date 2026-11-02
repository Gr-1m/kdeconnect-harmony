# UI 导航胶囊与侧边栏设计方案

> **日期**：2026-11-01
> **状态**：已实现（2026-11-02，HDS/main；Omp 接手 ArkTS）
> **范围**：Index.ets 页面整体 UI 逻辑——底部导航胶囊 + 各页签独立侧边栏 + 抽屉/推挤双模式
>
> **实现记录（2026-11-02）**：
> - 胶囊按 CodeArts MSG173 指导**恢复 HdsTabs `barFloatingStyle` + `systemMaterialEffect`（ADAPTIVE）**
>   沉浸光感；手机抽屉打开时用 `barBottomMargin=-160` 滑出（不再加 HdsTabs `.animation`），
>   推挤模式常驻。自绘 `bottomCapsule`/`barHeight(0)` 已撤回。
> - 汉堡按钮改为根级固定按钮（zIndex 999），开/关位置不变；标题栏 `padding.start`
>   恒为 64vp（不随抽屉开合变化），标题固定让位；按钮 40×40、`(16, statusBarVp+8)`，与原 backIcon bounds 一致
>   （实测 `[56,164][196,304]`，开关抽屉不变）。已对照平板“文件管理”真机：收起标题右移、展开按钮不动。
> - 手机抽屉外点关闭、根级关闭按钮、抽屉标题 margin 48vp 与标题栏 x=224 对齐、四页签独立抽屉均已实测。
> - 胶囊收起/展开统一走 `setDrawerOpen()` + `animateTo(200ms, EaseInOut)`，HdsTabs `barBottomMargin`
>   平滑位移，沉浸光感材质不变。
> - 手动连接回归：右上角菜单 →「Add by IP」→ `openManualConnectPage()` 切到设备页 section=3，
>   内容区恢复 `manualForm()`（host/port/Connect）。
> - 侧栏设备列表：native `deviceDiscovered/connected/disconnected/deviceLost/pairingRequest`
>   后调用 `syncSideBarLists()`；`DrawerOverlay` 三组数据改 `@Prop`；
>   `sideRememberedList` 渲染真实「记住设备」条目，不再只有计数行。
> - 平板 Embed 胶囊常驻：切页签时 `syncSideBarLists()` **只更新 `sideCurrentTab`，不改变 `drawerOpen`**；
>   展开时侧栏随页签更新，收起时保持收起（用户点汉堡收起后由 `sidebarUserClosed` 忽略 HdsSideBar 内部回写）。

---

## 一、整体架构

```
┌─────────────────────────────────────────────┐
│  Stack (根容器)                              │
│                                             │
│  ┌───────────────────────────────────────┐  │
│  │  HdsSideBar                           │  │
│  │  ┌──────────┬──────────────────────┐  │  │
│  │  │ SideBar  │  ContentPanel        │  │  │
│  │  │ Panel    │  (HdsNavigation +    │  │  │
│  │  │ (各页签  │   HdsTabs 内容)      │  │  │
│  │  │  独立)   │                      │  │  │
│  │  └──────────┴──────────────────────┘  │  │
│  └───────────────────────────────────────┘  │
│                                             │
│  ┌─────┐  (侧边栏按钮, zIndex 999)          │
│  │ ☰  │                                     │
│  └─────┘                                     │
│                                             │
│  ┌───────────────────────────────────────┐  │
│  │  底部导航胶囊 (最高图层, zIndex 1000)  │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

### zIndex 层级分配

| 层级 | zIndex | 内容 |
|------|--------|------|
| 背景渐变/光斑 | 0 | 深空渐变 + radialGradient 光斑 |
| HdsSideBar（侧边栏面板 + 内容面板） | 1 | 主内容区 |
| 抽屉遮罩（竖屏半透明背景） | 2 | `#00000066` |
| 侧边栏开关按钮 | 999 | 左上角固定 |
| **底部导航胶囊** | **1000** | **最高图层，始终可见** |
| 模态弹窗（配对/MPRIS/文件详情等） | 2000 | 覆盖一切 |

---

## 二、底部导航胶囊

### 2.1 图层优先级与可见性

导航胶囊位于**最高图层**（zIndex 1000），但**并非始终可见**——其可见性受侧边栏状态控制：

| 侧边栏状态 | 模式 | 导航胶囊可见性 | 原因 |
|-----------|------|---------------|------|
| 收起 | 抽屉模式 | **可见** | 用户需要切换页签 |
| 展开 | 抽屉模式 | **隐藏**（滑出屏幕底部） | 侧边栏覆盖内容区，用户无法切换页签；隐藏胶囊省去侧边栏面板内容随页签切换的更新开销 |
| 常驻 | 推挤模式 | **可见** | 侧边栏不遮挡内容区，用户仍需切换页签 |

**隐藏/显示动画**：`setDrawerOpen()` 用 `animateTo(200ms, EaseInOut)` 改变 `drawerOpen`，
HdsTabs 胶囊通过 `barBottomMargin` 平滑滑出/滑入屏幕底部；沉浸光感材质保持。

**核心收益**：手机抽屉模式下侧边栏展开时隐藏胶囊 ⇒ 用户无法切换页签 ⇒ 面板只需在打开时读取当前页签。
平板 Embed 胶囊常驻，仍保留 `sideCurrentTab` 同步：展开时侧栏随页签更新，收起时只更新内容、不自动展开。

**实现方案**：保留 `HdsTabs.barFloatingStyle` + `systemMaterialEffect`；手机抽屉开合通过
`setDrawerOpen()` 的 `animateTo` 改变 `barBottomMargin`，不再自绘底部胶囊。

### 2.2 胶囊样式

| 项 | 说明 |
|----|------|
| 页签 | 设备 / 文件 / 设置 / 日志（开发期保留） |
| 图标 | `sys.symbol.house` / `sys.symbol.folder` / `sys.symbol.gearshape` / `sys.symbol.text_alignleft` |
| 选中态 | 图标高亮 + 文字强调色 |
| 未选中态 | 图标/文字次要色 |
| 材质 | 沉浸光感 `systemMaterialEffect`（ADAPTIVE），不支持时降级 `BlurStyle.Regular` |
| 底部避让 | `navBarHeightPx + 28vp` |

### 2.3 页签切换逻辑

- 点击胶囊项 → `currentTab` 更新 → `HdsTabs` 控制器 `changeIndex(index)` 同步内容
- 切换页签时自动关闭抽屉（竖屏模式下）
- 切换到设备页时触发一次 UDP 发现广播
- 切换到日志页时刷新日志缓冲

---

## 三、侧边栏系统

### 3.1 侧边栏容器行为（两种模式）

| 模式 | 触发条件 | 行为 | 侧边栏宽度 |
|------|---------|------|-----------|
| **抽屉模式** | 竖屏手机（`!sideBySide`） | 侧边栏从左侧滑入，**覆盖**内容区，背后半透明遮罩 | 80% 屏宽（上限 360vp） |
| **推挤模式** | 折叠屏/横屏平板（`sideBySide`） | 侧边栏**常驻**左侧，内容区被**推到右侧**缩小 | 40% 屏宽（夹在 180–340vp） |

**判定逻辑**（已有，保持不变）：
```
isWide = vpWidth >= 600
isLandscape = vpWidth > vpHeight
sideBySide = isWide && isLandscape
```

- 旋屏/折叠状态变化时通过 `onAreaChange` 实时重算
- 从抽屉模式 → 推挤模式：侧边栏自动打开（常驻），无需手动点击
- 从推挤模式 → 抽屉模式：侧边栏自动关闭

### 3.2 侧边栏开关按钮与标题栏避让

| 属性 | 值 |
|------|-----|
| 位置 | `position({ x: 10vp, y: statusBarHeightPx + 10vp })`——**固定不变** |
| zIndex | 999 |
| 关闭态图标 | `sys.symbol.close_sidebar`（≡） |
| 打开态图标 | `sys.symbol.open_sidebar`（←） |
| 可见性 | **所有页面可见**（含日志页） |

点击切换 `drawerOpen` 状态。

**标题栏文字避让规则**：

侧边栏按钮位于标题栏左侧，与标题文字存在空间冲突。避让策略：

| 侧边栏状态 | 标题栏行为 |
|-----------|-----------|
| **收起** | 标题文字左侧留出按钮宽度 + 间距（约 44vp）的 padding，确保文字不被按钮遮挡 |
| **展开** | 标题文字无需避让（侧边栏面板已覆盖标题栏区域，标题不可见或被遮挡属于预期行为） |

实现方式：`HdsNavigation` 的 `titleBarOptions` 中，标题区域的左 padding 根据 `drawerOpen` 动态调整：
- `drawerOpen === false`：标题左 padding = 44vp（按钮 30vp + 间距 14vp）
- `drawerOpen === true`：标题左 padding = 0vp（无需避让）

### 3.3 各页签侧边栏内容

#### 设备页侧边栏（`DrawerOverlay`）

三个菜单项（按指定顺序）：

| section | 菜单项 | 内容 |
|---------|--------|------|
| 0 | **已连接** | 已连接设备列表（含展开/收起折叠），每行：设备图标 + 名称 + ID + 配对状态标签 |
| 1 | **记住设备** | 已配对但当前离线的设备列表 |
| 2 | **发现设备** | 局域网发现到的未配对设备列表，每行有「配对」按钮 |

**与当前实现的差异**：
- 当前有 4 个 section（已连接/发现/记住/手动连接），需**去掉「手动连接」**（移到设备内容页内；
  入口 = 右上角菜单「Add by IP」→ `openManualConnectPage()` → 设备页 section=3）
- 当前顺序是「已连接 → 发现 → 记住」，改为「已连接 → 记住设备 → 发现设备」
- section 编号重新映射：0=已连接, 1=记住设备, 2=发现设备

**点击行为**：
- 点击已连接设备行 → 选中该设备（`selectedDeviceId`），内容区跳转设备详情，抽屉关闭（竖屏）
- 点击记住设备行 → 选中该设备，内容区显示该设备信息（离线状态），抽屉关闭（竖屏）
- 点击发现设备行「配对」按钮 → 发起配对请求，抽屉关闭（竖屏）
- 点击 section 菜单项 → 切换 `deviceSection`，内容区相应切换分区，抽屉关闭（竖屏）

#### 文件页侧边栏（`FilesDrawerContent`）

两个开关：

| 开关 | 说明 | 默认值 |
|------|------|--------|
| **接收通知** | 是否接收对端发来的文件接收通知 | ON（当前禁用，待功能实现后启用） |
| **自动保存** | 接收到的文件是否自动保存到默认目录 | OFF（当前禁用，待功能实现后启用） |

开关下方显示「即将推出」提示。当前实现已符合要求。

#### 设置页侧边栏（`SettingsDrawerContent`）

两个菜单项：

| section | 菜单项 | 图标 | 内容区显示 |
|---------|--------|------|-----------|
| 1 | **设备信息** | `sys.symbol.info_circle` | 应用名/版本/设备ID/协议版本/端口/运行状态 |
| 2 | **关于** | `sys.symbol.questionmark_circle` | 仓库地址/版本号 |

默认内容区（不选中侧边栏菜单时）显示主设置页：设备名/主题/语言。

点击侧边栏菜单切换到对应分区；关闭侧边栏回到默认主设置页。

#### 日志页侧边栏

**无功能**。打开侧边栏时只显示「KDE Connect」标题，无菜单项、无交互。侧边栏按钮在日志页仍然可见（可点击打开），但面板内容为空。

---

## 四、内容区与侧边栏的联动

### 4.1 状态管理

**页面级 @State**：

| 状态 | 类型 | 说明 |
|------|------|------|
| `currentTab` | `number` | 当前页签（0-3） |
| `drawerOpen` | `boolean` | 侧边栏是否打开 |
| `sideBySide` | `boolean` | 是否横屏宽屏（推挤模式） |
| `drawerSectionByTab` | `number[]` | 每个页签各自选中的侧边栏 section `[0, 0, 0, 0]` |

**AppStorage（供 SideBarPanelHost 通过 @StorageLink 订阅）**：

| Key | 说明 |
|-----|------|
| `sideConnectedList` | 已连接设备列表 |
| `sideDiscoveredList` | 发现设备列表 |
| `sideRememberedCount` | 记住设备数量 |
| `sideDeviceSection` | 设备页当前 section |
| `sideSettingsSection` | 设置页当前 section |

> **注意**：`sideCurrentTab` **保留**。手机抽屉模式下胶囊隐藏，面板在打开时确定；平板 Embed 胶囊常驻，
> 切页签时必须写回 `sideCurrentTab`，否则缓存侧栏停留在旧页签（2026-11-02 实测修复）。

### 4.2 侧边栏内容切换

`SideBarPanelHost` 根据 `currentTab` 渲染对应组件。

**实现口径**：

- 手机抽屉模式：胶囊隐藏，无法切页签；面板在打开时读取 `sideCurrentTab` 即可。
- 平板 Embed：胶囊常驻，用户切页签时 `onChange` 调 `syncSideBarLists()` 写回 `sideCurrentTab`；
  **不改变 `drawerOpen`**。展开时侧栏即时更新；收起时保持收起，重新打开时显示新页签内容。
- `SideBarPanelHost` 通过 `@StorageLink('sideCurrentTab')` 订阅，保证缓存的侧栏子树也能更新。

| currentTab | 组件 | 内容 |
|-----------|------|------|
| 0（设备） | `DrawerOverlay` | 已连接 / 记住设备 / 发现设备 |
| 1（文件） | `FilesDrawerContent` | 两个开关 |
| 2（设置） | `SettingsDrawerContent` | 设备信息 / 关于 |
| 3（日志） | 空面板（仅标题） | 无功能 |

### 4.3 内容区分区切换

- **设备页**：`deviceSection` 驱动内容区显示哪个分区（已连接设备详情 / 记住设备列表 / 发现设备列表）
- **设置页**：`settingsSection` 驱动内容区显示哪个分区（主设置 / 设备信息 / 关于）
- **文件页/日志页**：侧边栏不切换内容区分区

### 4.4 抽屉模式交互流程

```
用户点击侧边栏按钮
  → drawerOpen = true
  → 导航胶囊滑出屏幕底部（200ms 动画）
  → syncSideBarLists() 同步最新数据到 AppStorage
  → HdsSideBar 展开侧边栏面板（覆盖在内容之上）
  → 半透明遮罩出现（#00000066）

用户点击遮罩区域
  → drawerOpen = false
  → 导航胶囊滑回屏幕底部（200ms 动画）
  → 侧边栏收起

用户点击侧边栏内某项
  → 更新对应 section 状态
  → 内容区切换分区
  → drawerOpen = false（竖屏自动关闭抽屉）
  → 导航胶囊滑回

用户按返回键
  → if drawerOpen: 关闭抽屉 + 胶囊滑回，不退出页面
```

### 4.5 推挤模式交互流程

```
横屏宽屏进入
  → sideBySide = true
  → 侧边栏常驻左侧（40% 宽度）
  → 内容区占右侧 60%
  → drawerOpen 默认为 true（常驻）
  → 无遮罩

用户点击侧边栏内某项
  → 更新对应 section 状态
  → 内容区切换分区
  → 抽屉不关闭（常驻状态）

旋屏回到竖屏
  → sideBySide = false
  → drawerOpen = false（自动关闭）
  → 回到抽屉模式
```

---

## 五、视觉层次示意

### 竖屏手机（抽屉模式）

```
正常状态（侧边栏收起）：
┌──────────────────────┐
│ ☰  KDE Connect    ⋮  │ ← 标题栏（文字左让 44vp）
├──────────────────────┤
│                      │
│    内容区域           │
│    (当前页签内容)     │
│                      │
├──────────────────────┤
│  [设备][文件][设置][日志] │ ← 导航胶囊可见
└──────────────────────┘

侧边栏展开：
┌──────────────────────┐
│ ←  ┌─────────┐       │
│    │ 侧边栏   │ ░░░  │ ← 侧边栏覆盖内容 + 遮罩
│    │ 面板     │ ░░░  │
│    │ (80%)    │ ░░░  │
│    │          │ ░░░  │
│    └─────────┘       │
│                      │ ← 导航胶囊已滑出屏幕（隐藏）
└──────────────────────┘
```

### 横屏平板/折叠屏（推挤模式）

```
┌──────────────────────────────────────┐
│ ☰  KDE Connect                   ⋮  │
├──────────┬───────────────────────────┤
│          │                           │
│ 侧边栏    │    内容区域                │
│ 面板      │    (当前页签内容)          │
│ (40%)    │                           │
│ 常驻      │                           │
│          │                           │
├──────────┴───────────────────────────┤
│      [设备][文件][设置][日志]         │ ← 导航胶囊
└──────────────────────────────────────┘
```

---

## 六、需要调整的关键点（与当前代码的差异）

| # | 当前实现 | 需要改为 | 原因 |
|---|---------|---------|------|
| 1 | 导航胶囊在 `HdsTabs.barFloatingStyle` 内（contentPanel 子层） | 提取到根 Stack 顶层，zIndex 1000；抽屉模式下侧边栏展开时滑出隐藏 | 确保胶囊是最高图层；隐藏后省去面板内容随页签切换的更新开销 |
| 2 | 设备侧边栏有 4 个 section（含手动连接） | 改为 3 个：已连接/记住设备/发现设备 | 对齐需求 |
| 3 | 设备侧边栏顺序：已连接→发现→记住 | 改为：已连接→记住设备→发现设备 | 对齐需求 |
| 4 | 侧边栏按钮在日志页隐藏（`currentTab !== 3`） | 所有页面都可见 | 日志侧边栏虽无功能但按钮存在 |
| 5 | 设置页 section 0 是主设置，侧边栏只管 section 1/2 | 保持，确认联动：侧边栏选中→内容切换；关闭侧边栏→回默认 | 确保逻辑清晰 |
| 6 | 标题栏文字与侧边栏按钮无避让 | 标题 `padding.start` 恒 64vp，开/关不移动 | 防止按钮遮挡且标题不跳 |
| 7 | `sideCurrentTab` AppStorage 同步 | **保留**；平板切页签写回，侧栏随页签更新 | Embed 胶囊常驻，必须同步 |

---

## 七、数据流总结

```
用户操作                     状态变更                    UI 响应
────────                     ────────                    ────────
点击胶囊项          → currentTab 更新         → 手机：抽屉关闭；平板：只更新侧栏内容，不改变展开状态
点击侧边栏按钮      → drawerOpen = true       → 手机：侧栏展开 + 胶囊滑出隐藏；标题 padding 恒 64vp
点击侧边栏按钮      → drawerOpen = false      → 手机：侧栏收起 + 胶囊滑回；标题 padding 恒 64vp
点击侧边栏菜单项    → drawerSectionByTab 更新 → 内容区分区切换 + 竖屏下抽屉关闭
旋屏/折叠状态变化   → sideBySide 更新         → 侧边栏模式切换（抽屉↔推挤）
点击已连接设备行    → selectedDeviceId 更新   → 内容区跳转设备详情 + 竖屏下抽屉关闭
点击配对按钮        → pairSession 启动        → 配对确认弹窗
```

---

## 八、涉及文件清单

| 文件 | 改动类型 | 说明 |
|------|---------|------|
| `entry/src/main/ets/pages/Index.ets` | 已实现 | HdsTabs `barFloatingStyle` 沉浸光感；手机抽屉开时 `barBottomMargin=-160` 滑出；固定汉堡 + `padding.start=64`；平板切页只写回 `sideCurrentTab`、不改变 `drawerOpen`；section 映射 |
| `entry/src/main/ets/components/DrawerOverlay.ets` | 已实现 | 去掉手动连接 section；调整菜单顺序 |
| `entry/src/main/ets/components/SideBarPanelHost.ets` | 已实现 | `@StorageLink sideCurrentTab` 订阅；日志页空面板；section 编号适配 |
| `entry/src/main/ets/components/FilesDrawerContent.ets` | 不变 | 已符合要求 |
| `entry/src/main/ets/components/SettingsDrawerContent.ets` | 不变 | 已符合要求 |
| `entry/src/main/ets/components/DevicesTab.ets` | 修改 | section 编号适配（0=已连接, 1=记住, 2=发现） |
| `entry/src/main/ets/components/SettingsTab.ets` | 修改 | section 编号适配 |
| `entry/src/main/ets/state/DeviceController.ets` | 修改 | `deviceSection` 语义调整 |
