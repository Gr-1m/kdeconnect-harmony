# ArkTS UI 代码审查笔记（面向 ArkTS 初学者）

> 2026-10-14。撰写：AtomCode（qwen3.8-27b，终审实例）。任务来源：CodeArts MSG154
> （用户希望亲自审查 ArkTS UI 代码，本笔记帮助理解问题并自行决定修复方向）。
>
> **代码基线**：commit `37a311a`（feat(ui): restore HdsSideBar(AUTO) — landscape Embed / portrait Overlay）。
> 本笔记所有行号已按该基线**逐条实证**；代码一旦移动，请按符号名搜索、勿依赖行号。
> **阅读前提**：熟悉 HTML/CSS/JS 基础即可。第一部分提供 Web 概念对照，之后可随时回查。
> **边界声明**：本笔记是审查辅助（问题本质 + 修复方向），不代写修复代码、不构成终审裁决；
> 修复实施归 DevEco 车道（ArkTS/UI 代码），构建/提交归 Omp。

---

## 第一部分：ArkTS 快速入门（用 HTML/CSS/JS 类比）

### 1.1 ArkTS 是什么

ArkTS ≈ **TypeScript 严格子集 + 声明式 UI 框架（ArkUI）编译成原生组件**。可以分两层理解：

- **语言层**：TS 的受限子集（强制类型标注、禁 `any`、限制动态行为）。会写 TS 的话，
  80% 语法面直接可认；
- **UI 层**：声明式组件树——和 React/Vue 同一个心智模型（描述「UI 长什么样」，
  框架负责「状态变了怎么更新」）。**关键差异：组件编译成原生渲染树，不是 DOM**。

没有 DOM。`Column()` / `Row()` / `Text()` / `List()` 不是 `<div>` / `<p>` 标签，
而是原生组件构造器；样式是链式方法（`.fontSize(14).padding(10)`），与 CSS 属性一一对应。

### 1.2 装饰器（Decorator）对照总表

ArkTS 的数据驱动 UI 全靠装饰器（机制同 TS decorator——你熟悉 JS，这个不陌生）。
对照表（本表按「你会什么」来读）：

| ArkTS | 最接近的 Web 概念 | 一句话说明 | 本项目实例 |
|---|---|---|---|
| `@Component` | React 函数组件 / Web Component | 把 struct 标记为组件（独立渲染单元，有自己的状态） | `@Component struct DevicesTab` |
| `build()` | `render()` / Vue template | 组件的渲染入口，内部是组件树 | 每个组件都有 |
| `@Entry` | 应用挂载点（`ReactDOM.render` 的那个根） | 标记入口页面组件 | `Index.ets`（全项目唯一） |
| `@State` | `useState()` | **组件内部**状态；赋值即触发该组件重渲染 | `Index.ets:128` `drawerOpen` |
| `@Prop` | React props（**单向、值拷贝**） | 父→子传递；子在本地持一份**拷贝**，子改不回传父 | `GlassCard.ets:18` `immersive` |
| `@Link` | Vue `v-model`（双向） | 父子**共享引用**，任一侧改另一侧可见 | `DrawerOverlay.ets:15` `drawerExpanded` |
| `@ObjectLink` | 传 MobX observable 对象 | 观察**类实例内部字段**（不是原始值拷贝）——对象内字段变，组件更新 | `LogsTab.ets:8` `logStore` |
| `@Observed` | MobX `@observable` 类 | 把一个类标记为可观察（@ObjectLink 生效的前提） | `DeviceController` 等 |
| `@Watch('x')` | Vue `watch()` | 某状态变化时触发回调 | `Index.ets` `@Watch('drawerOpen')` |
| `@Builder` | render function / JSX 片段函数 | 可复用的 UI 片段（返回组件树的函数） | `Index.ets` `statusBar()` |
| `@BuilderParam` | **slot**（Web Component）/ React `children` | 父组件往子组件里「塞内容」的口子 | `GlassCard.ets:17` `content` |
| `@StorageLink` / `@StorageProp` | Redux store / React Context | 绑定 `AppStorage`（全局可观察存储，≈ `window` 全局变量 + 订阅机制） | `SideBarPanelHost.ets:19-22` |

**一个反直觉点**（本项目最重要的坑，第二部分 P1 的根子）：

`@Prop` 是**拷贝**，靠「父组件重跑渲染」来刷新。但如果父组件的渲染函数**根本不会重新执行**
（比如某棵子树被系统组件缓存了），`@Prop` 就永远停在**首次求值时的快照值**。
`@Link`（引用）和 `@StorageLink`（全局存储订阅）不受「父级不重跑」影响——
这是本项目侧栏数据刷新绕行的底层逻辑，也是侧栏仍有状态不更新的盲区所在。

### 1.3 组件模型（vs Web Component）

| Web Component | ArkTS | 说明 |
|---|---|---|
| `customElements.define` + `render()` | `@Component struct` + `build()` | |
| Shadow DOM 样式隔离 | **无** shadow DOM | 样式不隔离；颜色等资源走显式引用 `$r('app.color.xxx')` |
| 属性 / 反射 | `@Prop` / `@Link` 字段 | 见 1.2 |
| `<slot>` | `@BuilderParam` | 见 1.2 |
| `connectedCallback` | `aboutToAppear()` | 生命周期（首次渲染前，常用来初始化、订阅） |
| `disconnectedCallback` | `aboutToDisappear()` | 生命周期（销毁前，常用来解订阅） |
| DOM 事件监听 | `.onClick(() => {})` 链式方法 | 事件=回调函数，没有 DOM Event 对象 |

### 1.4 HDS 组件（本项目用到的四个）

HDS（HarmonyOS Design）= 华为官方设计系统组件集——可以理解为「鸿蒙世界里的 Material UI」，
但它是**系统级原生**实现（不是三方 npm 包）。本项目用到四个：

| 组件 | 作用 | Web 类比 |
|---|---|---|
| `HdsNavigation` | 导航容器（标题栏 + 返回 + 路由） | PWA 里 `<nav>` + toolbar 的组合体 |
| `.titleBar()` | 系统标题栏（支持滚动渐变模糊、系统材质） | sticky header + 滚动时磨砂渐变 |
| `HdsTabs` | 底部页签（悬浮胶囊样式） | 移动端底部 tab bar |
| `HdsSideBar` | 侧栏（`AUTO` = 横屏内嵌并排 / 竖屏浮层覆盖） | `MUI.Drawer` / 桌面应用侧栏面板 |

**HdsSideBar 的已知坑**（本项目 UI 问题的核心，DevEco 三次实测确认）：
`HdsSideBar` 会**缓存 `sideBarPanelBuilder` 构建出的子树**——首次构建后，页面怎么重渲染，
这棵子树**都不会重新求值**（直接读 `@Observed` 数据、`@ObjectLink`、页面 `@State` 快照，
三种机制全部失败，记录在 `SideBarPanelHost.ets:7-15` 注释）。
⇒ 面板数据必须由**面板组件自己订阅的数据源**驱动。本项目现方案 = 页面把派生列表写进
`AppStorage` + 面板组件用 `@StorageLink` 订阅。第二部分 P1 和「深审专节」有完整分析。

---

## 第二部分：当前代码问题清单

> 共 14 项：P1（本次评审新发现，1 项）、中（3 项）、低（10 项，其中 1 项未复现、
> 1 项核对无问题、3 项为本次新发现）、另有「深审专节」回答总指挥 MSG154 §3.3 的四个问题。
> 每项给：位置（37a311a 基线行号）→ 类比 → 本质 → 代码 → 为什么是问题 → 修复方向（只给方向，不代写代码）。

### P1 | 侧栏「选中高亮 / 配对中标记」不更新（本次评审新发现）— 优先级：中偏上

- **位置**：`SideBarPanelHost.ets:24-25`（源头），`DrawerOverlay.ets:12-13`（消费，用于 167/204），
  数据源 `Index.ets:1522-1523`
- **类比**：React props 是拷贝——父组件不重新执行 render，子组件的 props 就永远停在首次快照。
- **本质**：HdsSideBar 缓存 `sideBarPanel` 子树（第一部分 1.4 已述）⇒ `sideBarPanel()` builder
  只求值一次 ⇒ 传给 `SideBarPanelHost` 的两个 `@Prop`（`selectedDeviceId`、`requestedPairIds`）
  被**钉死在首次求值时的值**（页面加载时大概率为空）。四个列表数据已经被 AppStorage 绕行修好，
  但这两项被漏掉了——绕行方案有盲区。
- **代码**：
  ```
  // SideBarPanelHost.ets:24-25 —— @Prop 是「值拷贝」，不是订阅
  @Prop selectedDeviceId: string = '';
  @Prop requestedPairIds: string[] = [];
  // DrawerOverlay.ets:167 —— 选中高亮
  .backgroundColor(this.selectedDeviceId === d.id ? $r('app.color.accent_soft') : Color.Transparent)
  // DrawerOverlay.ets:204 —— 「配对中…」标记
  if (this.requestedPairIds.includes(d.id)) { Text($r('app.string.pair_pending')) ... }
  ```
- **为什么是问题**：打开侧栏后选中设备 / 发起配对，高亮和「配对中」标记不出现。
  静默的功能退化（不报错），所以此前多轮验证没发现。
- **修复方向**：把这两项数据也搬进 AppStorage（`syncSideBarLists()` 里
  `AppStorage.setOrCreate('sideSelectedId', …)` / `'sideRequestedIds'`），
  `SideBarPanelHost` 改用 `@StorageLink` 订阅——与既有四键完全同构，改动最小。
  （若后续按 DevEco MSG160 迁到 Navigation+NavBar，缓存消失，此问题连同绕行方案整体消失。）

### 中-1 | `CONNECT_TIMEOUT_MS` 迁移遗留死常量 + 注释与值漂移

- **位置**：`Index.ets:73`（=20000，**Index 内无任何引用**）vs `PairSession.ets:30`（=15000，
  实际生效于 `PairSession.ets:114` connect 阶段计时）
- **类比**：重构后文件顶部旧全局变量没删，模块改用自带常量——而且值还悄悄变了（20000→15000）。
- **本质**：`PairSession.ets:29` 注释自述「原为 Index 顶层常量，随状态机一起收敛到这里」
  ⇒ 收敛时 Index 旧常量漏删。另有一处漂移：`Index.ets:70-72` 注释论证「本侧必须比
  对端 30s 留更长」，但真正生效的 connect 值是 15s（配对阶段的 `PAIR_TIMEOUT_MS`=45s 确实
  比 30s 长——connect 与 pair 是两段，注释把两段语义搅在一起了）。
- **为什么是问题**：读者按 Index 注释会以为超时是 20s，实际 15s；弱网下 TCP+TLS 15s 是否够
  是行为问题，被死常量掩盖了。
- **修复方向**：删 `Index.ets:73`（死常量）+ 修正 70-72 注释（区分 connect/pair 两段超时）。
  **注意**：删常量和「是否要调 15s 的值」是两件事——调值是行为变更，需要单独决定（建议保留
  15s 现状，除非有弱网超时实例）。

### 中-2 | `cardMaterial` 死链 + 能力设备上卡片视觉降级为「全透明」

- **位置**：声明 5 处（`GlassCard.ets:20` / `DevicesTab.ets:44` / `FilesTab.ets:15` /
  `LogsTab.ets:10` / `SettingsTab.ets:22`）；消费点 `GlassCard.ets:27/40`、`LogsTab.ets:37`；
  设计意图注释 `Index.ets:1119-1120`
- **类比**：一个功能放弃后留下的整条死代码——prop 声明了、层层传递了，但**从来没人给值**
  （React 里一路传 `undefined` 的 prop）。
- **本质**：原设计 = 卡片用沉浸光感系统材质（页面层创建 `uiMaterial` 实例注入，见
  `GlassCard.ets:10` 注释）。后来设计变更（`Index.ets:1119-1120`：「底栏材质由 HdsTabs 的
  barFloatingStyle 提供；卡片等非 TabBar 区域不在生效范围，走毛玻璃」），材质实例**有意不再创建**，
  但 5 处声明 + 3 处消费的整条链没清理。
- **实际影响（比「功能没生效」更具体）**：
  - 能力设备（`immersiveSupported=true`）：`systemMaterial(undefined)` +
    `backgroundColor(Color.Transparent)` + `border({width:0})` + `backgroundBlurStyle(undefined)`
    ⇒ **卡片完全透明**，内容直接浮在页面渐变背景上。注释说「降级毛玻璃」，但毛玻璃
    （`backgroundBlurStyle`）在重构中已被设为 `undefined`——**注释与实现不符**，既没有设计中的
    材质，也没有注释声称的毛玻璃；
  - 低端 / ohemu（`immersiveSupported=false`）：`card_bg` 底色 + 边框，正常卡片 ✓。
- **为什么是问题**：能力设备上卡片视觉与设计意图不符（静默降级）；死链 8 处增加阅读与维护成本。
- **修复方向**（二选一，先定调再动手）：
  1. **删死链**：去掉 `cardMaterial` 字段与 `immersive` 对卡片样式的分支，统一走 `card_bg`
     （改 `GlassCard`/`LogsTab` 与 4 个 Tab 的传参），同步修正注释——简单、零风险；
  2. **真做材质**：先确认官方 `uiMaterial` 是否有「创建卡片材质实例」的 API（历史文档只记载了
     能力探测 `isImmersiveMaterialSupported()`，未见创建入口——在 Win10 商用 SDK d.ts 里查
     `ImmersiveMaterial`/`uiMaterial` 可坐实）；有则页面层创建并注入，无则回到方案 1。

### 中-3 | `aboutToAppear()` 458 行「上帝组件」初始化

- **位置**：`Index.ets:189-647`（实测 458 行）
- **类比**：React 的 `useEffect`（on mount）写了 458 行——或者 jQuery 时代 `$(function(){...})`
  里塞进整个世界初始化。
- **本质**：一个生命周期方法混了四类事：上下文获取 / 权限申请、native 初始化、控制器回填装配
  （`actionController` 的十几个回调逐行回填，见 636-638 一带）、插件路由注册 + 自检。
- **为什么是问题**：可维护性——任何改动都要通读 458 行，评审难、易漏回归；其中「回填装配」
  是纯样板，与初始化逻辑互相纠缠。
- **修复方向**：拆成私有方法——`initUiState()` / `initControllers()` / `initPluginRoutes()` /
  `initNative()`，`aboutToAppear` 只留一行一行的调用清单（十几行）。**纯重构、零行为变更**，
  构建 + 冒烟即可验收。

### 低-1 | `DRAWER_DEVICE_CAP` 重复定义（迁移遗留死常量）

- **位置**：`Index.ets:76`（=2，Index 内无引用）vs `DrawerOverlay.ets:5`（=2，生效于 25/28/68）
- **本质**：与中-1 同型——抽屉截断逻辑已移入 `DrawerOverlay` 组件，Index 侧常量遗留。
- **修复方向**：删 `Index.ets:76`。

### 低-2 | `MAX_PICK_FILES` 重复定义（迁移遗留死常量）

- **位置**：`Index.ets:80`（=9，Index 内无引用）vs `DeviceActionController.ets:20`
  （=9，生效于 233 行 `picker` 的 `maxSelectNumber`）
- **本质**：同型——选文件逻辑已收敛到 `DeviceActionController`，Index 侧常量遗留。
- **修复方向**：删 `Index.ets:80`。

### 低-3 | 多处连续空行（删码残留）

- **位置**：`Index.ets:949-956`（8 连续空行）、`Index.ets:1510-1515`（6 连续空行）
- **本质**：删除代码块后未清理（949-956 处上方是 `handlePacket` 收尾、下方是
  「连接/配对会话」分区注释——旧方法已搬走，空行留下）。
- **修复方向**：清理。纯空白变更，零风险。

### 低-4 | `PayloadRow.ets` BOM — **未复现**

- **CodeArts 原述**：「PayloadRow.ets 文件头有 BOM 字符」。
- **实测**（37a311a 基线）：两种方式复查（od 读前 3 字节 + file 全量）——
  `entry/src/main/ets` 下 61 个 .ets 文件**均无 BOM**。
- **可能解释**：① 探索 agent 检出后已被中间版本修复；② 探索工具误报；
  ③ 仅 Win10 侧本地存在（未同步）——若你 Win10 编辑器显示该文件有 BOM，属其本地状态。
- **修复方向**：无需动作。若要防复发：现 pre-commit 编码守卫（`check-encoding.py`）只拦
  非法 UTF-8 / U+FFFD，BOM（U+FEFF）是合法 UTF-8 不会被拦——可给守卫加一条 BOM 检查。

### 低-5 | `DrawerOverlay.onClose` 死回调（已知预期项）

- **位置**：`DrawerOverlay.ets:16`（声明）；唯一调用方 `SideBarPanelHost.ets:41-42`
  传入的是**空函数**。
- **本质**：预期行为——HdsSideBar(AUTO) 接管侧栏（37a311a）后，DrawerOverlay 已「纯内容化」
  （遮罩/关闭按钮移除，关闭由 `autoHide` + `$isShowSideBar` 双向绑定处理）。
  CodeArts MSG152 §4 已书面声明。
- **修复方向**：不单独处理——迁 Navigation+NavBar 时整组件退役，onClose 随之删除。

### 低-6 | 文件扩展名→权限清单重复（两份逐字相同的数组）

- **位置**：`Index.ets:1041-1044`（`ensureWritePermission`，async + 申请权限）vs
  `PayloadController.ets:429-432`（`writePermissionFor`，纯映射返回权限名）
- **本质**：方法名不同，但 image/video（13 个扩展）+ audio（8 个扩展）**两个数组逐字相同**——
  重复的是清单，不是方法。
- **为什么是问题**：以后加文件类型（如 `.avif`）要改两处，漏一处则两处权限行为分叉。
- **修复方向**：把两个扩展名清单抽成共享常量（如放 `PayloadModels.ets`），两处引用同一份；
  「申请」与「映射」的逻辑各自保留。

### 低-7 | `SideBarPanelHost` @StorageLink 核对 — **无问题**

- **核对结论**：页面写入的 4 个键（`Index.ets:1175-1178`：`sideConnectedList` /
  `sideDiscoveredList` / `sideRememberedCount` / `sideDeviceSection`）与宿主订阅的 4 个键
  （`SideBarPanelHost.ets:19-22`）**完全匹配** ✓。
- **注意**：同组件里「订阅的 4 个键」修好了，但「父级传的 2 个 @Prop」被钉死——
  见 **P1**（同一组件混了两种数据模式，修了一半）。

### 低-8 | 横屏设备页签无滚动面（本次新发现，边缘场景功能缺口）

- **位置**：`Index.ets:1575-1581`（设备页签 `if (this.sideBySide)` 分支：静态
  `Column { deviceTabView() }`，`padding bottom 108`，**无 List / 无 Scroll**）；
  对照竖屏 else 分支 1583-1598（`List` + scroller + `contentEndOffset(bottomAvoidVp())`）
- **本质**：横屏宽屏（≥600vp 且横）下设备页签没有滚动面——内容高于屏时
  （横屏高度小，设备页签 = 状态栏 + 功能卡 + 通知区块），屏幕下方部分**滚不到**。
- **为什么是问题**：「可滚动」只在竖屏成立；平板横屏（本项目主验收设备形态之一）内容被截。
- **修复方向**：if 分支同样改 List（与竖屏共用 `deviceScroller`），保留 padding/fill 差异；
  若设计意图就是「横屏不滚动」，需向用户确认——现状是「既不滚、也无截断提示」。

### 低-9 | `GlassCard` fill / 非 fill 分支重复（本次新发现）

- **位置**：`GlassCard.ets:22-49`（if/else 两分支）
- **本质**：两分支 8 个属性里 **7 个逐字相同**，唯一差异是 fill 分支多 `.height('100%')`。
- **修复方向**：合并为单分支 + 条件 height（fill 时加），净删约 15 行。

### 低-10 | 硬编码 108 与动态 `bottomAvoidVp()` 并存（本次新发现）

- **位置**：`Index.ets:1581`（横屏分支 `padding bottom 108`）vs `Index.ets:1594`
  （竖屏分支 `contentEndOffset(this.bottomAvoidVp())`）
- **本质**：底部避让两套机制——横屏写死 108vp，竖屏动态计算。不同设备底部安全区/导航条
  高度不同，横屏分支会偏（留多或留少）。
- **修复方向**：先确认 108 的构成（疑似 = 底栏胶囊高度 + 安全区的经验值），再统一到
  `bottomAvoidVp()`（必要时 + 底栏高度常量，注释写明构成）。

---

## 深审专节：回答 MSG154 §3.3 的四个问题

**Q1. HdsSideBar 的 builder 缓存机制是否真的导致数据不刷新？@StorageLink 方案是否是最佳解法？**

- **真的**。DevEco 实测证据链完整：三种机制（① 页面 builder 闭包直读 `@Observed` 数据
  ② 宿主改 `@ObjectLink` ③ 页面 `@State` 快照 + `@Watch` 同步）全部失败，
  仅 AppStorage 订阅生效（`SideBarPanelHost.ets:9-14` 注释留痕）。
- **@StorageLink 是 HdsSideBar 框架下的唯一有效绕行**，不是根解。
  **根解是架构级**：DevEco 对系统「文件管理」/「设置」的 `uitest dumpLayout` 真机取证
  （MSG160）显示系统应用侧栏一律用 `Navigation.NavBar`——NavBar 内容是普通栏位 builder，
  随状态正常重算，缓存问题从机制上不存在。MSG160 重构提案**待 CodeArts 裁决**；
  若采纳，缓存问题 + AppStorage 绕行 + P1 一次性全消。

**Q2. syncSideBarLists() 写入 AppStorage 的 4 个 key 是否都在 SideBarPanelHost 中正确订阅？**

- 是，4/4 完全匹配（见低-7）。但同组件的 2 个 @Prop 被钉死（见 P1）——
  订阅模式修了一半，剩余一半就是本次新发现。

**Q3. contentPanel() builder 内的弹窗层（if 条件渲染）是否会被 HdsSideBar 缓存影响？**

- **不会**。弹窗层（Mpris/PayloadDetail/RunCommand/RemoteInput 四个 dialog，
  `Index.ets:1740-1840` 一带）在 `contentPanel()` 内；HdsSideBar 缓存的是
  **sideBarPanel** 子树（DevEco 实测结论与代码注释都只针对 sideBarPanelBuilder）。
  内容面板是页面主体，若也被缓存则整页冻结——用户多轮真机验证（设备列表/载荷/日志
  均正常更新）即实证。if 条件渲染工作正常。

**Q4. DevicesTab 的横屏 sideBySide 模式与 HdsSideBar 的 AUTO 模式是否冲突？（两个侧栏机制并存）**

- **无双侧栏**（担忧不成立）：旧 sideBySide「常驻并排布局」已移除——当前 sideBySide
  只控制 ① 设备页签是否可滚动 List（横屏=静态 Column，见低-8）② GlassCard fill
  （`DevicesTab.ets:972`）。横屏只有一个侧栏：系统 HdsSideBar 的 Embed（300vp）。
- **真实问题不是「两个侧栏冲突」，而是「分支分化」**：横屏/竖屏分支在滚动机制
  （横屏无滚动，低-8）与底部避让机制（硬编码 108，低-10）上分叉了——这才是
  「机制并存」的真身，也是横屏体验劣于竖屏的根因。

---

## 第三部分：架构概览（建立心智模型）

### 3.1 分层架构

```
┌─────────────────────────────────────────────────────────────┐
│ 组件层（ArkTS UI）                                            │
│  Index.ets(@Entry 页面)                                      │
│   ├─ HdsSideBar(AUTO)                                        │
│   │   ├─ sideBarPanel → SideBarPanelHost → DrawerOverlay     │
│   │   └─ contentPanel → HdsNavigation → HdsTabs              │
│   │        ├─ TabContent×4: DevicesTab / FilesTab /          │
│   │        │            SettingsTab / LogsTab                │
│   │        └─ 弹窗层: Mpris / PayloadDetail /                 │
│   │                RunCommand / RemoteInput (dialog)         │
├─────────────────────────────────────────────────────────────┤
│ 状态层（Controller，@Observed 可观察类）                       │
│  DeviceController(设备) / PairSession(配对状态机) /            │
│  PayloadController(载荷) / MprisController /                  │
│  SettingsController + DeviceActionController(动作编排,非观察)  │
│  + PluginEventBus(插件事件路由)                                │
├─────────────────────────────────────────────────────────────┤
│ 网络桥接层                                                    │
│  PacketRouter（packet 路由：packetReceived / pair /           │
│  connected / disconnected 事件入口）                           │
├─────────────────────────────────────────────────────────────┤
│ 原生层（C++ NAPI，非 ArkTS）                                   │
│  UDP 发现 / TCP server / BearSSL TLS / packet 序列化           │
│  （entry/src/main/cpp/，本笔记范围外）                          │
└─────────────────────────────────────────────────────────────┘
模型层（纯数据类，各层共用）：DeviceModels / PayloadModels /
NotificationModels / MprisModels / TrustModels / ...
```

### 3.2 数据流（主链路）

```
原生层事件（connected/disconnected/packet）
  → PacketRouter（路由到对应 handler）
  → Controller 变更 @Observed 状态（唯一事实源）
  → UI 刷新（四种模式，按「数据要去哪」选用）：
```

| 模式 | 机制 | 用在哪 | 特性 |
|---|---|---|---|
| ① 直连观察 | 组件 `@ObjectLink` 观察 Controller | LogsTab ← LogStore | 实时；组件直接看状态层 |
| ② 页面快照 | 页面 `@State` + 子组件 `@Prop` | Index 设备列表 → DevicesTab | 实时；页面当「转手柜台」 |
| ③ AppStorage 桥 | 页面写 `AppStorage.setOrCreate` + 面板 `@StorageLink` | Index → SideBarPanelHost | 实时；**专门绕过 HdsSideBar 缓存**（见 1.4/P1） |
| ④ 双向绑定 | `@Link` 共享引用 | `drawerExpanded`（抽屉展开态） | 实时；子改父也见 |

读代码时看到任何「数据不更新」问题，先定位它走的是哪种模式、
该模式下数据源有没有真的变（模式选错是本项目 UI bug 的主要来源——P1 就是模式 ② 用在
不该用的地方：父级渲染被缓存，@Prop 快照不刷新）。

### 3.3 关键设计模式

1. **回调注入（依赖注入）**：Controller 不反向依赖页面——页面在装配阶段把回调填进
   Controller（`Index.ets:636-638` 一带：`actionController.xxx = () => this.yyy()`）。
   类比 React 里把 `setXxx` 传进 hook 而不是在 hook 里 import 页面。
   好处：状态层可单测（不拉起 UI）；代价：装配样板多（中-3 的主体）。
2. **@Observed + @ObjectLink 观察**：状态层是唯一事实源，UI 只读 + 回调回写
   （单向数据流，同 Redux 心智）。
3. **插件系统**：`PluginBase` / `PluginHost` / `PluginRegistry` +
   `PluginEventBus.kinds()` 路由自检（`Index.ets:640-644`，注册数与清单一致才放行，
   漏注册可机检）。每类功能（通知/剪贴板/MPRIS/远程输入/运行命令…）是一个 plugin 文件。
4. **单页多组件**：全部 UI 长在 `Index.ets` 的 build 树里，页面是「装配厂」，
   子组件是「预制件」。所以 Index.ets 有 1869 行——中-3 的拆分就是治理这个装配厂。

### 3.4 文件地图（读代码从哪开始）

| 顺序 | 文件 | 看什么 |
|---|---|---|
| 1 | `pages/Index.ets` `build()`（1844-1869） | 整页骨架：Stack → HdsSideBar 参数全貌 |
| 2 | 同文件 `contentPanel()`（1540 一带） | 背景光斑 + HdsNavigation + HdsTabs 四页签 |
| 3 | 同文件 `deviceTabView()`（1390 一带）+ `sideBarPanel()`（1516-1530） | 侧栏问题的现场：builder 怎么传数据 |
| 4 | `components/SideBarPanelHost.ets`（57 行，全读） | 缓存绕行的注释（7-15 行）+ 两种数据模式混用（P1） |
| 5 | `components/DrawerOverlay.ets` | 侧栏内容（原抽屉，现被 HdsSideBar 承载） |
| 6 | `state/DeviceController.ets` → `state/PairSession.ets` | 状态层两个核心：设备列表 + 配对状态机 |
| 7 | `net/PacketRouter.ets` | 事件入口：原生事件如何路由到 handler |
| 8 | `components/GlassCard.ets`（50 行，全读） | 中-2/低-9 的现场 |

---

## 附录 A：MSG154 §3 问题清单核对对照表

| # | CodeArts 原述 | 本评审实证结论（37a311a 基线） |
|---|---|---|
| 1 | `CONNECT_TIMEOUT_MS` 不一致（20000 vs 15000） | ✅ 坐实，更精确 = 迁移遗留**死常量**（Index 侧无引用）+ 注释与值漂移 → 中-1 |
| 2 | `cardMaterial` 5 组件声明但从未赋值 | ✅ 坐实，更精确 = **有意放弃的功能**留 8 处死链 + 能力设备卡片降级为**全透明**（注释声称的毛玻璃不存在）→ 中-2 |
| 3 | aboutToAppear 约 450 行未拆分 | ✅ 实测 **458 行**（189-647）→ 中-3 |
| 4 | `DRAWER_DEVICE_CAP` 重复定义 | ✅ 坐实，Index 侧为死常量 → 低-1 |
| 5 | `MAX_PICK_FILES` 重复定义 | ✅ 坐实，Index 侧为死常量 → 低-2 |
| 6 | 多处连续空行 | ✅ 坐实（949-956 / 1510-1515）→ 低-3 |
| 7 | `PayloadRow.ets` 文件头 BOM | ❌ **未复现**（61 个 .ets 均无 BOM，od + file 双查）→ 低-4 |
| 8 | `DrawerOverlay.onClose` 死代码 | ✅ 坐实，**已知预期项**（MSG152 §4 声明）→ 低-5 |
| 9 | `writePermissionFor` 逻辑重复（Index:1041） | ✅ 坐实，更精确 = **两个不同名方法的扩展名清单逐字重复**（非方法重复）→ 低-6 |
| 10 | `SideBarPanelHost` @StorageLink 机制需确认 | ✅ 4/4 键匹配无问题；**但发现盲区**：同组件 2 个 @Prop 被缓存钉死 → 低-7 + **P1（新发现）** |

**本评审新增 4 项**（探索 agent 未覆盖）：P1（@Prop 快照钉死）、低-8（横屏无滚动面）、
低-9（GlassCard 分支重复）、低-10（硬编码 108 与动态避让并存）。

## 附录 B：怎么读这份代码（给初学者的两条经验）

1. **沿 build 树读 Index.ets**：`build()` → `contentPanel()` → 各 `xxxView()` builder
   → 子组件文件。ArkTS 页面是「树」，不是「流程」——先找树，再找每个节点怎么取数。
2. **行号会漂移，按符号名搜**：本笔记行号以 37a311a 为基线；代码一改行号就变。
   定位问题用符号名（如 `syncSideBarLists` / `sideBarPanel` / `cardMaterial`）全局搜索，
   永远比记行号可靠。

## 附录 C：建议修复顺序（供你拍板，非裁决）

| 批次 | 内容 | 性质 | 风险 |
|---|---|---|---|
| 1 | 低-1 / 低-2 / 中-1（删死常量+修注释）、低-3（空行）、低-9（GlassCard 合并分支）、低-10（统一底部避让） | 卫生 | 零（纯清理，构建+冒烟验收） |
| 2 | P1（@Prop → AppStorage 两键）、低-6（扩展名清单共享） | 小改动、行为可见 | 低（改完侧栏高亮/配对标记应能真机验证） |
| 3 | 中-2（先定调：删死链 or 做材质）、中-3（aboutToAppear 拆分）、低-8（横屏统一滚动） | 需设计决策 | 中（中-2 涉观感、中-3 涉大文件重构） |
| 4 | Navigation+NavBar 迁移（DevEco MSG160，待 CodeArts 裁决） | 架构级 | 高——若采纳，P1 / AppStorage 绕行 / 低-5 一次性全消，批次 2 的 P1 届时可能不必做 |

> 顺序只是建议：批次 4 若先落地，会吞掉批次 2 的 P1 与绕行方案；
> 批次 1/3 与批次 4 正交，随时可做。最终排期由用户 + 总指挥裁决。

---
*完。撰写：AtomCode（qwen3.8-27b）；基线 37a311a；全部行号经逐条实证。*
