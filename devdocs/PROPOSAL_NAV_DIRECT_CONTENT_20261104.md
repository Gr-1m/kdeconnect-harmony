# 方案评审：HdsNavigation 直接子内容 + 独立底部胶囊

> 2026-11-04。提案：Omp。状态：**待 AtomCode / CodeArts 评审，未实施**。
> 目标：复现系统设置页「内容从标题栏下方穿过、滚动时被沉浸模糊」的效果。

## 1. 现状与证据

当前结构：

```
Stack
└─ HdsSideBar
   └─ contentPanel: HdsNavigation
      └─ HdsTabs
         ├─ TabContent(设备/文件/设置/日志)
         └─ barFloatingStyle（底部胶囊）
```

dumpLayout（5559，日志页）：

```
标题栏 "日志"    y=180..287
Tabs             y=332..2760
TabContent/List  y=332..2564
```

结论：`HdsNavigation` 为 titleBar 预留了高度，`HdsTabs` 的内容区从标题栏**下方**才开始，
标题栏后面没有内容，`IMMERSIVE_GRADIENT_BLUR`/`systemMaterialEffect` 只能作用于标题栏自身，
无法产生系统设置那种「内容从标题栏下方透出并被模糊」的效果。

已验证无效：
- `titleMode(FREE)`：仅标题变大，内容仍从下方开始；
- `ignoreLayoutSafeArea`：不改变 HdsTabs 内容起点；
- 根级自绘 overlay 标题栏：自定义组件不在 HDS 材质作用域，模糊退化成黑底，已回滚。

## 2. 目标结构（提案）

```
Stack
└─ HdsSideBar
   └─ contentPanel: HdsNavigation
      ├─ 当前页内容（Scroll/List 直接子内容，内容可延伸到标题栏下方）
      └─ （标题栏由 HdsNavigation 绘制，覆盖内容）
└─ 独立底部胶囊（root Stack 顶部）
```

关键变化：

1. **不再用 HdsTabs 包裹四个页面**；`HdsNavigation` 的直接子内容按 `currentTab` 切换为对应页面。
2. 底部胶囊从 HdsTabs 中拆出，独立固定在根 Stack 底部（与当前自绘方案类似）。
3. 四个页面各自保留 Scroller；切页签只切换内容组件，不重建页面状态。

## 3. 必须先裁决的两个问题

### Q1：底部胶囊如何保留沉浸光感？

| 方案 | 说明 | 风险 |
|---|---|---|
| A. 保留一个 `HdsTabs`/`Tabs` 仅作为底栏 | 若 HdsTabs 仅用于 bar、内容为空/透明，需验证是否仍能进入材质作用域 | 组件语义扭曲，可能仍占内容区 |
| B. 标准 `Tabs(barPosition:End)` + `CommonModifier` + `systemMaterial` | `devdocs/ARKTS_GUIDE.md` 记录的 OpenHarmony 路线，可做「一个胶囊 + 材质」 | 仍需承载 TabContent，内容与标题栏关系要实测 |
| C. 根级自绘胶囊 + `backgroundBlurStyle` | 最稳定、已实现过 | **没有 HDS 沉浸光感**，与用户刚确认的材质效果冲突 |
| D. 根级自绘 + `uiMaterial` | 自定义组件不在官方作用域，实测材质失效 | 不可行 |

**Omp 建议**：优先验证 B（标准 Tabs 直接作为 HdsNavigation 子内容），若内容仍无法穿过标题栏，
再评估 A；C 只作为降级，不作为主方案。

### Q2：切页签与滚动状态

- HdsNavigation 直接子内容只能有一个根节点；需要 `if/else` 或 `Stack` + `visibility` 切换四页。
- 每个页面 Scroller 保留；切页时不重建数据（沿用现有四个 Scroller/控制器）。
- 返回键、抽屉、底部胶囊隐藏逻辑不变。

## 4. 实施草案（评审通过后）

1. 抽出 `PageHost`：按 `currentTab` 渲染设备/文件/设置/日志内容，作为 HdsNavigation 直接子内容；
2. 移除 HdsTabs 内容容器；保留/改造底部胶囊（按 Q1 裁决）；
3. 内容顶部不再留 56vp，让 List/Scroll 从标题栏下方开始，标题栏覆盖；
4. 修正四页签的 `contentEndOffset` 与底部胶囊避让；
5. 三端冒烟：手机 Overlay / 平板 Embed / 折叠屏；日志滚动看标题栏模糊；四页签切换；抽屉开合；手动连接页。

## 5. 风险

- 四页内容从 HdsTabs 移出后，分页切换、Scroller 绑定、HdsNavigation 标题栏滚动联动都要重测；
- 底部胶囊材质若无法保留，会回退到用户已否定的毛玻璃；
- 平板 `sideBySide` 下侧栏 + 内容布局需保持；
- 改动面大，建议单独分支/单独提交，不与 0.8.3 收口混在一起。

## 6. 请评审

- **AtomCode**：批准是否进入实施；分支/版本落点；是否要求先做最小原型（仅日志页）验证 Q1/Q2。
- **CodeArts**：底部胶囊材质方案（A/B/C）选择；PageHost/Scroller 接线建议；对四页签状态影响。

## 7. 零重构开关实验（2026-11-05，5559 实测）

在**不改结构**的前提下，只切换 `titleBarOptions` 的 `avoidLayoutSafeArea` / `enableComponentSafeArea`，日志页 dumpLayout：

| avoidLayoutSafeArea | enableComponentSafeArea | 标题文字 bounds | Tabs/List 顶部 | 结果 |
|---|---|---|---|---|
| true | true（基线） | `[224,180][407,287]` | `y=332` | 正常，但内容不进入标题区 |
| false | true | `[224,137][407,151]` | `y=196` | 标题栏塌到窗口顶部，标题被压成 14px 高 |
| true | false | 标题同塌到顶部 | `y=137` | 内容进入标题区，但标题/状态栏重叠 |
| false | false | 标题塌到顶部 | `y=137` | 同 `true/false` |

结论：

- `enableComponentSafeArea:false` 可以把内容顶到 `y=137`（标题下方穿越），但**标题栏本身会塌到窗口顶部**，与状态栏/日志首行重叠。
- 单独设 `avoidLayoutSafeArea:false` 也不能保住标题栏位置；`enableComponentSafeArea:true` 只多留 59px，标题仍塌。
- **没有任何纯开关组合能同时满足“标题栏位置正常 + 内容从标题栏下方穿过”**。
- 因此 AtomCode 要求的零重构实验结论为：**失败**；必须进入日志页最小原型（PageHost + 直接子内容 + 标题栏覆盖），不能靠 titleBarOptions 开关完成。

证据：`~/.local/share/verify-shots/navflag_20261105/`（`log_00.json`、`log_01.json`、`log_10.json`、`log_comp.json`、`log_comp.jpeg`、`log_under_title.jpeg`）。

—— Omp
