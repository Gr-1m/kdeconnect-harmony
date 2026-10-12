# DESIGN — 详情页整页滚动 + 标题栏滚动渐变模糊 + 沉浸胶囊（v2 实施就绪版）

> 2026-10-11。作者 DevEco。**状态：实施就绪，待 CodeArts 最终点头**。
> 依据：用户需求（逐字见 §1）+ CodeArts MSG142（边界：`Index.ets`/`DevicesTab.ets` **均归 DevEco**，构建验证归 Omp）+ 参考工程 `C:\Users\xiaoyi\Documents\ohtotptoken`（**本机实测**，非转述）。
> **v2 已吸收用户更正**：「不是完全不要 scroll，参考项目中有如何滚动」⇒ 以参考工程的 **`List` + `contentEndOffset` + `bindToScrollable`** 为准；CodeArts 已知晓该两处 API ✓。

---

## 1. 需求（逐字与更正后的理解）

**用户原话（三轮）**：
1. 「设备详情是否能向下滑动，通知部分看不到，被导航胶囊挡住了」
2. 「要求是 不用向下滚也能看到通知区块，并且向下滚动之后 标题栏也能做到朦胧半透明，符合系统中 UI 的统一性，参考项目 `ohtotptoken`」
3. **「不是完全不要 scroll，参考项目中有如何滚动吧」** ← **决定性更正**

**⇒ 矫正后的目标（4 条）**：
| # | 目标 | 判定 |
|---|---|---|
| G1 | **整页滚动**（TabContent 层的 `List`），**不是**卡片内套 `Scroll`（后者被用户形容为"一个框，只有上滑才能看到"✗） | 见 §4 |
| G2 | **滚动后标题栏朦胧半透明**（渐变模糊） | 见 §5 —— **由滚动触发**，故**必须有滚动器**（这也解释了 G1 为何不能省）|
| G3 | **胶囊沉浸光感**（`barOverlap` + `systemMaterialEffect`） | 现有配置已正确，**保持不动** ✓ |
| G4 | 内容**在胶囊下方**（延伸至其下、透过胶囊可见），靠**末尾避让**保证可达 | 见 §6（`contentEndOffset`，非 `padding` ✗）|
| G5 | 「通知」区块可达（**可滚动到达即可**；首屏是否可见见 §7） | 见 §7 |

---

## 2. 参考工程事实（本机实测，附行号 —— 实施时按这些对齐）

| 要点 | 位置 | 关键代码 |
|---|---|---|
| **三层结构** | `Index.ets` L1367 / L1417 / L1419 | `HdsNavigation`（外层，`.hideTitleBar(true)` L1606）→ `HdsTabs` → **每个 `TabContent` 内再一个 `HdsNavigation`（MINI titleBar）** → 内容页 |
| **标题栏半透明 + 滚动渐变模糊** | `Index.ets` **L1419–1457** | `.titleMode(HdsNavigationTitleMode.MINI)` · `.hideBackButton(true)` · `.titleBar({ avoidLayoutSafeArea:true, enableComponentSafeArea:true, style:{ **scrollEffectOpts:{ enableScrollEffect:true, scrollEffectType:<渐变模糊> }**, systemMaterialEffect:{ADAPTIVE} }, content:{ title:{mainTitle}, **menu:{value:[…]}** } })` |
| **绑定滚动器（G2 的必要条件）** | 同上 **L1432** | **`.bindToScrollable([this.tokenListScroller])`** |
| **整页滚动 + 末尾避让** | `TokenListPage.ets` **L116** | `List({ scroller }) { ListItem()… }` + **`.contentEndOffset(80 + appBottomAvoidHeight)`** + `.edgeEffect(EdgeEffect.Spring)` |
| **胶囊沉浸** | `Index.ets` **L1560–1570** | `.barOverlap(true)` · `.barBackgroundColor(Transparent)` · `.barBackgroundBlurStyle(BlurStyle.Regular)` · `.barFloatingStyle({ barBottomMargin:28, systemMaterialEffect })` |
| ⚠️ **差异** | — | 参考工程**无 `gradientMask`** ⇒ 本工程 `Index.ets:1475` 的自定义 `gradientMask` 属**自加项**，实施时**逐步核对**（先保留，排查完再决定是否删除）|

---

## 3. 现状（本工程待改点）

| 元素 | 位置 | 现状 |
|---|---|---|
| 手写标题 Row（汉堡 + 「KDE Connect」+「HarmonyOS」徽标） | `Index.ets:1260–1279` | 实色、无沉浸、不随滚动变化 ✗ |
| 运行状态条（「运行中」+ deviceId） | 标题 Row 之下 | 独立块（本质是内容信息）|
| `TabContent` 底部避让 | `Index.ets:1363` | **硬编码 `padding({bottom:108})`** ✗ |
| 底栏 `HdsTabs` | `Index.ets` ≈L1461–1482 | 配置正确 ✓ |
| 侧栏抽屉 | `DrawerOverlay.ets` + 页面 `drawerOverlay` | **自定义覆盖层**（非系统 Navigation）⇒ 与 `HdsNavigation` 的 z-order 待验（§8-R1）|
| 详情页 | `DevicesTab.deviceDetail(d)` | 设备信息块 → 6 张功能卡（`ACTION_CARD_HEIGHT=132`）→ 「通知」折叠区块 |
| 发现设备区（section 1） | `DevicesTab.ets:940-961` | **`Refresh + Scroll`**（**非** `List`；`Scroll.height('100%')` + 顶部对齐，注释记录了不给高度会垂直居中的坑）⇒ List 化后**嵌套 Scroll 高度语义失效**（§8-R2）|
| 侧栏发现列表（横屏） | `DevicesTab.ets:290-328` | `Refresh + Scroll` 同款（发现列表已移入 `sidePanel`）|
| 通知区块 | `DevicesTab.ets:783-821` | `deviceDetail` 内**末尾**（6 张功能卡 ≈792vp 之后）⇒ 首屏外 |

---

## 4. 目标结构（G1：整页滚动）

```
Index
└─ Stack                                              ← 保留（承载自定义 drawerOverlay）
   └─ HdsNavigation()  .hideTitleBar(true)            ← 【新增·外层】路由壳，不显示标题栏
      └─ HdsTabs({controller})                        ← 保持（G3 胶囊配置不动）
         ├─ TabContent(设备)
         │   └─ HdsNavigation()                       ← 【新增·内层】沉浸·滚动联动标题栏（§5）
         │      .titleMode(MINI) · .hideBackButton(true)
         │      .bindToScrollable([this.deviceScroller])
         │      .titleBar(<见 §5>)
         │      └─ List({ scroller: this.deviceScroller })      ← ★ 唯一滚动面
         │            ListItem() { 运行状态条 }
         │            ListItem() { DevicesTab(设备信息块 …) }
         │         .contentEndOffset(this.bottomAvoidVp())      ← ★ 末尾留空（非 padding）
         │         .edgeEffect(EdgeEffect.Spring)
         ├─ TabContent(文件)   → HdsNavigation(MINI,「文件」)   → List{ FilesTab }
         ├─ TabContent(设置)   → HdsNavigation(MINI,「设置」)   → List{ SettingsTab }
         └─ TabContent(日志)   → HdsNavigation(MINI,「日志」)   → List{ LogsTab }
```

**关键取舍**：`DevicesTab` **不再自己套 `Scroll`** ✗ —— 滚动面统一在 `TabContent` 层（`List`）✓。
`DevicesTab` 内部两块内容（信息块 / 功能卡 / 通知区块）以**多个 `ListItem`** 形式交给页面组装，或整体作为一个 `ListItem`（**建议前者**：便于懒加载与将来插入新区块）。

**方案 B（备选）**：不加外层 `HdsNavigation`，仅 `TabContent` 内各一个。差异：少一层壳；代价与参考工程结构不一致。**倾向 A**。

---

## 5. 标题栏（G2：滚动渐变模糊）

### 5.1 形态
```ts
HdsNavigation() { /* 内容（List） */ }
  .titleMode(HdsNavigationTitleMode.MINI)
  .hideBackButton(true)
  .bindToScrollable([this.deviceScroller])            // ★ 滚动联动
  .titleBar({
    avoidLayoutSafeArea: true,                        // 状态栏安全区沉浸
    enableComponentSafeArea: true,
    style: {
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR   // ★ 渐变模糊（朦胧半透明）
      },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    },
    content: {
      title: { mainTitle: $r('app.string.EntryAbility_label') },     // 「KDE Connect」
      menu: { value: [ /* 汉堡按钮（可点）、HarmonyOS 徽标（只读） */ ] }
    }
  })
```

### 5.2 当前手写元素 → `titleBar` 映射
| 当前元素 | 去向 | 说明 |
|---|---|---|
| 「KDE Connect」 | `content.title.mainTitle` | 用系统标题样式（自动含安全区沉浸）|
| 汉堡按钮（开抽屉） | `content.menu.value[]` 可点击项 | `action` 触发既有 `drawerOverlay` 状态；图标沿用 `sys.symbol` |
| 「HarmonyOS」徽标 | `content.menu.value[]` 只读项 | 参考工程 L1462–1480 的 `menu.value[]` 支持自定义 content |
| **运行状态条**（运行中 + deviceId） | **不进 titleBar** → 留作 `List` 的**首个 `ListItem`** | titleBar 为 MINI 紧凑高度；状态条是内容信息，塞入会破坏官方观感 ✗ |
| 页签标题（文件/设置/日志） | 各内层 `titleBar.content.title.mainTitle` | 与原文案一致 |

---

## 6. 滚动与底部避让（G4：内容在胶囊下方 + 可达）

```ts
// Index.ets
private bottomAvoidVp(): number {
  // 胶囊遮挡 = 距底边距 + 胶囊本体高；56 为 HDS 胶囊高度（与参考工程同口径），12 为余量
  return this.getUIContext().px2vp(this.navBarHeightPx) + 28 + 56 + 12;
}
```
- 应用于 **`List.contentEndOffset(this.bottomAvoidVp())`** ✓
  **不用 `padding`** ✗ —— `padding` 会把空白随滚动带进视口（v1 的"空白带"来源），`contentEndOffset` 只在**末尾**留空且不进入视口 ✓（参考工程 L116 同法）。
- **删除** `Index.ets:1363` 的 `padding({bottom:108})` ✓。
- ⚠️ **56 是口径值、不是实测值**：实施后用**模拟器截图量取**胶囊实际高度并回填（不再留魔数）。

---

## 7. 「通知」区块位置 + section 1 处置（**本版已裁定**）

### 7.1 通知区块 ⇒ **保持原位；由用户在首屏截图后裁定**（**2026-10-12 更正**）
- **用户裁决（AtomCode MSG147 转录）**：通知区块走**「实施后首屏截图再定」**路径 —— 用户**未采纳** AtomCode MSG146 P1-1 的「直接上移」意见。⇒ 本轮**保持原有区块顺序**（通知仍在 6 张功能卡之后），**不擅自上移**。
- **已有实证截图**：手机模拟器（`127.0.0.1:5557`）连上对端后，**首屏即可看到「通知 (0)」区块**（在 6 张功能卡之后、胶囊之下，呈两层沉浸观感）——见 `screenshots/phone-live/s1.jpeg`（本地，未入仓）。⇒ 请 CodeArts／用户据此裁定是否仍需上移。

### 7.2 section 1（发现设备区）⇒ **处置方案 ①（同步 List 化 + 共用 scroller）**（本轮修正，评审 P1-3）
- **问题**：section 1 = `Refresh + Scroll` + `.height('100%')`（`DevicesTab.ets:940-961`）；主 List 化后落入内容驱动高度的 `ListItem` ⇒ 嵌套 `Scroll` 高度语义失效（塌缩）、`Refresh` 手势与主 `List` 抢手势。
- **选定**：**① 同构化** —— `DevicesTab` 的**根**改为 `Refresh { List({scroller: <页面传入的 detailScroller>}) { ListItem… } }`：
  - 全工程**只有一个滚动面**（页面持有的 `Scroller`），四分区（详情/发现/记住/手动）的**内容都是 `ListItem`**；
  - `Refresh` 提到根 → 下拉刷新手势与主 List **天然不冲突**，`onRefreshing` 语义不变（仍触发 identity 广播，`DevicesTab.ets:965-970`）；
  - 侧栏（横屏 `sidePanel`）**保持原样**（不属主滚动面，独立 `Refresh + Scroll` 无嵌套问题）。
- **为什么不用 ②**（section 切换上提页面层）：需把 `deviceSection` 状态与四个分区 builder 全部上提，改动面大于 ①，且与现有 `deviceController` 结构冲突。
- **代价**：`Scroller` 需由 `Index` 创建并以 prop 传入 `DevicesTab`（`bindToScrollable([...])` 要求页面持有同一实例）。
- **⚠️ 实施注意**：section 3（手动连接）含 `TextInput`，落入 `List` 后需核对键盘弹起避让（`KeyboardAvoidMode`/`expandSafeArea`）——列入第 2 步验证项。

---

## 8. 风险与未知（**每条都有消解动作，不猜**）

| # | 风险 | 消解动作 |
|---|---|---|
| **R1** | 自定义 `drawerOverlay` 与 `HdsNavigation` 的 **z-order**（抽屉可能被 titleBar 盖住或反之） | **最小验证第一步**：只加 `HdsNavigation(MINI)` 后，点汉堡验抽屉能正常覆盖 |
| **R2** | `DevicesTab` section 1 是 **`Refresh + Scroll`**（`height('100%')`）⇒ 落入内容驱动高度的 `ListItem` 后**嵌套 Scroll 高度解析失败**（塌缩/不可滚）+ `Refresh` 手势与主 `List` 冲突（**§7 已裁定处置**）；另 `bindToScrollable` 只应绑主滚动器 | 按 §7 处置实施；第一步同时验：切到「发现设备」分区后下拉刷新仍正常 |
| **R3** | `HdsNavigation` 是否**要求路由栈**（参考工程外层带 `.mode(NavigationMode.Stack)`） | 第一步就验：**无 NavPathStack 时 MINI titleBar 能否正常渲染**；不行则把内层包在最小 `NavDestination`/保留外层壳 |
| **R4** | `titleBar.content.menu.value[]` 的**自定义能力边界**（能否放只读文本徽标 + 可点汉堡） | 第一步**只放 `mainTitle`**；第二步再加 menu（逐项加、逐项截图） |
| **R5** | `avoidLayoutSafeArea/enableComponentSafeArea` 是否**取代**现有 `getWindowAvoidArea` 手工避让（`navBarHeightPx`/`statusBarHeightPx`） | 第二步核对：若取代，顺势简化既有逻辑（避免两套避让打架）|
| **R6** | `ContentEndOffset` 与胶囊实际高度不符 ⇒ 末尾仍被遮挡或留空过多 | 用模拟器截图量取回填（§6）|

---

## 9. 改动清单（文件 → 改动点）

| # | 文件 | 改动 |
|---|---|---|
| 1 | `pages/Index.ets` | ①加外层 `HdsNavigation(hideTitleBar)` ②4 个 `TabContent` 各加内层 `HdsNavigation(MINI titleBar)`（标题/菜单/沉浸材质/`bindToScrollable`）③删手写标题 Row（L1260–1279），状态条移入内容区首个 `ListItem` ④`TabContent` 内容改 `List({scroller})` + `contentEndOffset` ⑤删 `padding(bottom:108)`（L1363）⑥`gradientMask` 按 §2 差异逐步核对 |
| 2 | `components/DevicesTab.ets` | ①根改 `Refresh + List({页面传入 scroller})`（§7.2 方案 ①，四分区内容 `ListItem` 化）②**移除任何自套 `Scroll`/`Refresh+Scroll`**（已回退 ✓ 保持，含 section 1 `L940-961`）③「通知」区块**上移**到设备信息块之后、6 卡之前（§7.1）④侧栏 `sidePanel` 保持原样 |
| 3 | `resources` | 页签标题文案（如与现状不同）|

---

## 10. 实施顺序与验收（**验收已按评审 P1-4 拆分**）

1. **第 1 步（最小验证，风险前置）**：**仅设备页签** → `HdsNavigation(MINI, 只放 mainTitle)` + `bindToScrollable` + `List` + `contentEndOffset`
   ⇒ Win10 模拟器截图核验：**R3（无路由可用）· R1（抽屉 z-order）· G2（滚动时标题栏渐变模糊）· R6（末尾无空白带）**
2. 第 2 步：补 `menu`（汉堡 + 徽标）、推广到 4 个页签；核 R4/R5；`DevicesTab` 根 `Refresh + List` 同构化（§7.2）后核 section 1/3（含 `TextInput` 键盘避让）
3. 第 3 步：删手写标题 Row 与硬编码 padding；通知区块上移（§7.1）
4. 第 4 步：**Omp** 构建验证（`CC_/AR_` + `--no-daemon`，见 MSG149）+ 提交；**用户复看**

### 10.1 验收拆分（P1-4 落实）
| 环境 | 范围 | 内容 |
|---|---|---|
| **Win10 商用模拟器**（Mate 80 Pro） | **HDS UI 验收** | 滚动**前后各一张标题栏截图**（G2 证据）· 胶囊沉浸 · 暗色态（用户手动「设置→显示」切换；`hdc param set` 被系统拒 `errNum 1001` ✗）· `uinput` 可脚本化点击/滑动 |
| **本机 ohemu**（OpenHarmony 镜像） | **非 UI 逻辑回归** | `tools/verify-on-ohemu.sh`；**排除 HDS UI**（静态导入 `@kit.UIDesignKit` 在 ohemu 白屏，AGENTS.md 2026-09-23 实测） |
> ⚠️ **前置**：`tools/verify-on-ohemu.sh` 的构建期降级**现仅覆盖 `HdsTabs→Tabs` + 去 `barFloatingStyle`，不覆盖新增的 `HdsNavigation`/`titleBar`** ⇒ 冒烟前须**扩展降级脚本覆盖 `HdsNavigation`**（降级为 `Navigation` 或透传），否则 ohemu 必白屏。

---

## 11. 评审回执与状态（**v2.1**，2026-10-11）

**评审结论**：AtomCode MSG146 / `devdocs/REVIEW_UI_TITLEBAR_DESIGN_20261011.md` —— **本设计 v2 通过（附 2 处修正）**；API 名经本地商用 SDK d.ts 独立验证**无一幻觉**；风险表 R1–R6 判定各有消解；实施顺序正确。

| 评审项 | 处置 |
|---|---|
| **P2-3** §3 现状描述不符（R2 对象写错） | ✅ **已改**：section 1 = `Refresh + Scroll`（非 `List`），R2 对象更正为**嵌套 Scroll 高度语义**（§3 / §8-R2）|
| **P1-4** 验收缺 ohemu 降级覆盖 | ✅ **已补**：§10.1 验收拆分（Win10=HDS UI / ohemu=非 UI 回归）+ 降级脚本须先覆盖 `HdsNavigation` |
| **P1-1** 通知区块 | **用户裁决 = 首屏截图后再定**（AtomCode MSG147 转录；未采「直接上移」）⇒ 保持原位；首屏实证截图已附（§7.1）待裁 |
| **P1-3** section 1 未处置 | ✅ **已裁定 ①**（§7.2，`DevicesTab` 根 `Refresh + List` 同构化、共用 scroller）|
| **P2-2** 状态条去向 | ✅ 已在 §5.2 明确（首个 `ListItem`；非 titleBar）|
| **P2-1** `gradientMask` | 采评审意见：去留判据 = **暗色态胶囊底部截图对照**（移除前后各一），无对照不删 |
| **P3-1** 结构 A/B | 维持 **A**（外层壳 + 内层 MINI）；B 仅在第 1 步验证通过时可接受 |
| **P3-2** 避让公式口径 | 采评审意见：统一用本工程公式（与 `Index.ets:1473` 的 `barBottomMargin` 同口径，保留平板 `navBar=0` 坑修复）|

## 12. 仍未决（**唯一一项**：P0 归属）

**[P0] `Index.ets` 归属**：AtomCode 查明 Omp MSG154 自述「MSG142 明确指派（Omp 车道）」与 **MSG142 §5 原文（`Index.ets` + `DevicesTab.ets` 均归 DevEco）** 及 **AGENTS.md 角色分工（2026-09-26 用户指令：DevEco 写所有 ArkTS/UI，含 `Index.ets` 接线/替换/修复；Omp 代做模式已终止）** 矛盾 ⇒ **须 CodeArts 明示裁决**；若变更分工，AGENTS.md 须同步更新。
> 本设计 v2.1 为实施基线；**归属一旦裁定即按上述 §10 顺序实施**（本车道按 MSG142 §5 原文准备施工）。

—— DevEco（设计 v2.1：已吸收 MSG146 评审，实施就绪）

---

## 13. 实证记录（v2.2，2026-10-12）：**「第 1 步只改页面层」不成立，已回退**

### 13.1 做了什么
按 §10 第 1 步实施：`Index.ets` 设备页签包 `HdsNavigation(MINI)` + `List({deviceScroller})` + `contentEndOffset` + `bindToScrollable`，`DevicesTab` 整体作为 `ListItem`；tab 0 隐藏手写标题/状态条。**构建通过**（`BUILD SUCCESSFUL`），安装启动成功，**无 JS 崩溃/SyntaxError**。

### 13.2 结果：`sideBySide`（平板）布局破损（用户实测反馈「整体看不到正常的功能了，全都塞进了侧栏里」）
模拟器截图实况（MatePad mini，横屏宽窗 ⇒ `sideBySide = true`）：
- 主内容区**宽度塌成一条**（`emptyHint` 变成竖排单字，挤在侧栏右缘 x≈320）；
- `HdsNavigation` 标题栏与侧栏**重叠**（标题浮在侧栏面板之上）；
- 侧栏面板**铺满全高**（原应为标题/状态条之下的卡片）。

### 13.3 根因（**架构级，非参数可调**）
`DevicesTab` 的尺寸契约**依赖有界父容器**：
```
Stack.height('100%')  →  Row{ Column(30%).height('100%') + Column.layoutWeight(1).height('100%') }
```
放进**内容驱动高度**的 `ListItem` 后，`height('100%')` / `layoutWeight(1)` 的解析基准失效 ⇒ 主区宽度与高度退化。

### 13.4 结论（对 §10 的修正，**须评审/总指挥确认**）
- **`List` 化必须与 `DevicesTab` 同构化同时落地**：`DevicesTab` 根改 `Refresh + List({scroller})`、四分区内容 `ListItem` 化、按**内容高**布局、去掉对 `height('100%')`/`layoutWeight(1)` 的依赖。即 §7.2 方案 ① 不是「第 2 步」，而是**第 1 步的前置**。
- 「第 1 步只改页面层、先验证 R3/G2」**不成立** —— 已验证 R3（无需 `NavPathStack`，MINI 标题栏可渲染、无报错），但 G2 必须在 `DevicesTab` 同构化之后才能验。
- 修订后的顺序建议：**第 1 步 = `DevicesTab` 同构化（含页面层 `List`/`HdsNavigation`）一起**；同为 §7.2 方案 ① 的落实。
- 回退已执行：`Index.ets` 已恢复原状（静态检查 + 构建通过），模拟器复验布局正常。
- 设备事实补充：模拟器 **MatePad mini(`127.0.0.1:5555`) 为横屏宽窗 ⇒ 走 `sideBySide` 平板路径**（主战场）；**手机模拟器 Mate 80 Pro(`127.0.0.1:5557`) 走竖屏路径**，双设备可并行验两条分支。

—— DevEco（v2.2：新增 2026-10-12 实证，实施顺序修正待确认）

### 13.5 竖屏路径已落地并验证（2026-10-12，同一日第二次实施）
按「先做手机竖屏路径」实施（**平板分支原样保留、未被破坏**）：
- `Index.ets`：设备页签按 `sideBySide` 分流 —— 竖屏走 `HdsNavigation(MINI)` + `List({deviceScroller})` + `contentEndOffset` + `bindToScrollable`；平板仍旧结构。`DevicesTab` 调用抽为 `@Builder deviceTabView()` 供两分支共用。
- `DevicesTab.ets`：竖屏分支改**内容高**（去掉 `height('100%')`/`layoutWeight(1)`）；section 1 去掉嵌套 `Refresh + Scroll`，改按内容高（滚动交给页面级 List）。
- 手机模拟器（Mate 80 Pro `127.0.0.1:5557`，竖屏）实测截图：标题栏单处无重叠 ✓、状态条作首个 `ListItem` 横排正常 ✓、主区文字横排正常 ✓、**汉堡经 `menu.value[]` 迁移成功**（抽屉可开可关）✓。
- 待验：**G2（滚动渐变模糊）** —— 需可滚内容（连接一台对端使功能卡 + 通知区块出现）；当前无设备连接、内容不足一屏，滑动无变化属预期。
- 遗留小差异：汉堡现位于标题栏**右侧**（`menu.value[]` 语义），原手写版在标题**左侧**；用户 2026-10-12 明确想要**系统「文件管理」那种左上角汉堡 + 可收起侧栏** ⇒ 已立项上报（见 `AgentsConversion/MSG154FromDevEco_TO_CODEARTS.md`：官方 `HdsSideBar`/`HdsSideMenu` 线索）。
- **标题透明度**：用户 2026-10-12 反馈「标题透明度可能还不够」，裁定**暂缓**（记录在案，不在本轮范围）。
- 已修一处细节：根容器横向 padding 使标题栏内缩、两侧露**两条竖线** ⇒ 横向 padding 下移到内容层，标题栏**通栏**（用户确认方向）。

