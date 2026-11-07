# 方案 — 平板双面板整治（S2 并行项，Omp-ArkTS 提案 v0.1）

- 日期：2026-11-08（D+1；D+2=11-10 前与 CodeArts 方案汇总给用户拍板）
- 作者：Omp-ArkTS
- 背景（AtomCode MSG179 §3）：「平板同时存在 HdsSideBar 40% 侧栏 + `DevicesTab` 内 sideBySide 30% 分区栏，内容重叠」已确认为遗留问题；
  **下拉刷新必须保留，并移到「发现设备」位置**。未拍板前不动结构。

## 1. 现状（代码级）

| 层 | 结构 | 内容 |
|---|---|---|
| 页面 `HdsSideBar`（平板 40%） | `sideBarPanel()` → `SideBarPanelHost` → `DrawerContentModel`（`DrawerOverlay.ets`） | 已连接设备列表 / 「记住的设备」分区行 / 发现设备列表 / 手动连接 |
| `DevicesTab(sideBySide=true)` 左 rail（内容区 30%） | `sidePanel()`（`DevicesTab.ets:289-340`） | 分组标题 + 已连接设备行 + 三个分区入口（已连接/记住/发现）+ 发现设备列表，外层 `Refresh`（**当前唯一的下拉刷新入口**） |
| `DevicesTab` 右主区 | `Scroll(mainScroller)` → `GlassCard` → `sectionContent()` | 选中设备详情/各分区内容 |

⇒ 两侧渲染的是同一份设备与分区信息（截图为证：`~/WorkSpace2/version-shots/titlebar-passthrough-20261107/paddev.jpeg`），信息架构冗余、宽度浪费。

## 2. 方案 A（推荐）：平板不再渲染 rail

**结构**：`DevicesTab` 在 `sideBySide=true` 时**只渲染主区**（保留 `Scroll(mainScroller)` + 分区标题 + 内容）；
设备/分区选择全部由页面 `HdsSideBar` 承担（`DrawerContentModel` 已有 `onPickSection` / `onOpenDevice`，直连 `deviceController.deviceSection`，无需新交互）。

**下拉刷新落点**：「发现设备」分组——① 侧栏 `DrawerContentModel` 的「发现设备」分组标题行加刷新按钮（点击 → `onRefreshDiscovery()`，等价语义）；
② 侧栏该分组所在 `Scroll` 支持下拉（`Refresh` 包住侧栏滚动体）；③ 主区「发现设备」分区（section 2）在手机/平板都保留下拉刷新（手机已有该分区，行为一致）。

**成本**：`DevicesTab` 删 `sideBySide` 分支（约 30 行）+ 主区宽度自适应；页面把 `onRefreshDiscovery` 透传给 `SideBarPanelHost`（新增 1 个 prop）。
**风险**：低。侧栏收起为迷你栏时无法下拉 ⇒ 由 ① 的刷新按钮兜底。
**对 S7 的影响**：正向——S7（HdsNavigation 直接内容）要求内容面板单一滚动面，A 让平板与手机共用同一形态，S7 的重排面更小。

## 3. 方案 B（备选）：保留 rail，只去重

**结构**：rail 仅保留三个分区入口 + 下拉刷新（`Refresh` 移到分组顶部，语义面向「发现设备」）；删除 rail 内「已连接设备行」与「发现设备列表」两组（页面侧栏已有）。
**成本**：更小（约 15 行删除）。
**缺点**：平板仍是两层导航（页面侧栏 + rail），信息架构重复未根治；rail 仍占 30% 宽度。

## 4. 对比

| 维度 | A 只留主区 | B 保留 rail 去重 |
|---|---|---|
| 信息架构 | 单层（侧栏选，主区看），与手机一致 | 两层，仍有重复入口 |
| 主区宽度 | 100%（平板利用率最高） | 70% |
| 改动量 | ~30 行 + 1 prop | ~15 行 |
| 下拉刷新落点 | 侧栏「发现设备」分组 + 主区分区 2 | rail 顶部（面向发现设备） |
| 对 S7 | 合并改造面 | 需再删一次 rail |
| 风险 | 侧栏收起态需按钮兜底 | 低 |

## 5. 推荐

**方案 A**。理由：一次性消除重复、平板主区拿到全宽、与手机共用一套「侧栏选择 + 主区展示」，且与 S7 的「单一内容面」目标同向。
若用户更倾向最小改动，退 **方案 B**（保留下拉刷新的原始手势位置）。

## 6. 待 CodeArts 方案汇总时一并裁决的点

1. 侧栏「发现设备」刷新交互：下拉 vs 按钮（建议两者都留，按钮兜底迷你态）；
2. 平板迷你侧栏下分区切换入口是否仍完整；
3. 是否需要把「手动连接」也收进侧栏（现状在右上菜单「Add by IP」，两方案都不动）。
