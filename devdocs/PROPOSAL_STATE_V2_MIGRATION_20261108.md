# 提案 — 状态管理 V1→V2 迁移（分阶段试点） v0.1

- 日期：2026-11-08
- 作者：Omp-ArkTS（应所有者要求出具对比与方案）
- 依据：官方《状态管理概述》《状态管理V1和V2混用指导（API 19+）》（本地镜像 `harmonyos-skills/references/harmonyos-guides/arkts-state-management-overview.md`、`arkts-v1-v2-mixusage.md`）
- 现状审计（本仓实测）：**V2 装饰器 0 处**；`@Component` 24 个、`@Observed` 29 个；弹窗为**内联 overlay 组件**（`@CustomDialog` 0 个）；`animateTo` 2 处（`components/DrawerOverlay.ets`、`pages/Index.ets`）；`Index.ets` 页面级 `@State` **30 个**

## 1. 官方口径（决定本提案基调）

| 结论 | 出处 |
|---|---|
| **新应用建议直接用 V2**；已用 V1 且"功能与性能已满足需求"则不必立即迁 | 状态管理概述 |
| V2 优点：数据自身可观察（不依赖 UI 存在）、深度观测**不影响性能**、**属性级精准更新**与数组元素最小化更新、`@Param/@Event` 明确输入输出 | 状态管理概述 |
| V1 缺陷：只能观察第一层、改对象属性/数组元素**冗余更新**、装饰器配合限制多、组件无明确输入输出 | 状态管理概述 |
| ⚠️ **V2 相较 V1 仍有 GAP**，"请开发者慎重选择" | 状态管理概述 |
| ⚠️ `animateTo` 在 V2 部分场景**动画效果异常** | `@Local` 章节 |
| 混用约束：`@ObservedV2` 不能与 V1 装饰器同用；V1 `@Link` 只能被 V1 变量初始化；V1↔V2 传复杂类型必须 `UIUtils.enableV2Compatibility` / `makeV1Observed`，否则**双重代理** | V1-V2 混用指导 |

## 2. 为什么本仓值得迁（不是赶时髦）

`devdocs/arkts-perf/ARKTS_PERF_ROADMAP.md` 已实证三条卡顿，**根因都是 V1 的观测模型**：

| # | 现象 | V1 当年的解法（补丁） | V2 下的原生行为 |
|---|---|---|---|
| 1 | `Index.logText` 页面级 `@State` → 整页重建 | 状态下沉到 `@Observed LogStore` + `@ObjectLink` | 属性级更新，只重建用到该属性的节点 |
| 3 | MPRIS 面板插值时钟每秒整页重建 | 面板局部 `@State` | 同上 |
| 5 | `DevicesTab.onAreaChange` 连续触发 | 150ms 去抖 + 同值不写 | `@Monitor` 只在最终值变化时触发 |

即：**V2 把我们在 V1 下靠手工纪律（下沉/去抖/同值判断）维持的东西变成框架行为**。

## 3. 迁移映射（官方对照表）

| V1 | V2 | 注意 |
|---|---|---|
| `@State` | 无外部初始化 `@Local`；外部初始化一次 `@Param`+`@Once` | `@State` 可外部初始化，`@Local` 不行 |
| `@Prop` | `@Param` | **复杂类型：V1 深拷贝 → V2 引用**（语义变化，需逐处核对是否依赖拷贝隔离） |
| `@Link` | `@Param`+`@Event` | 双向要自己组合 |
| `@ObjectLink` | `@Param` | 直接兼容；`@Observed`→`@ObservedV2`+`@Trace` |
| `@Provide/@Consume` | `@Provider/@Consumer` | 兼容 |
| `@Watch` | `@Monitor` | V2 支持深监听；同一事件多次变化只判最终值 |
| `$$` | `!!` | — |
| `@CustomDialog` | `openCustomDialog` | 本仓未用 `@CustomDialog`，此项无影响 |

## 4. 方案：分阶段试点，不逐组件零散切换

逐组件混用会踩两条红线（`@ObservedV2` 禁与 V1 同用、跨家族复杂类型需 `enableV2Compatibility`），且**当前 codelinter 不可用**（AGENTS「鸿蒙构建要点」：商用 CLT 类型门禁拦截），无法自动查混用 ⇒ 只能靠编译 + 人工清单，风险高。

| 阶段 | 范围 | 内容 | 验收 |
|---|---|---|---|
| **V0 规则冻结**（0 代码） | 文档 | 在 `ARKTS_GUIDE` 写明：新组件按"基本类型进 / 回调出"（如 `DeviceInfoDialog`），为将来迁移留路；V1/V2 混用需 `enableV2Compatibility/makeV1Observed` 并登记 | 文档评审 |
| **V1 叶子对照**（1 组件） | `components/DeviceInfoDialog.ets` | 改写为 `@ComponentV2`+`@Param`+`@Event`（父仍是 V1 `@Component`） | 编译零 error；弹窗开关/文案/遮罩/`zIndex` 行为一致（5555+5559 截图）；**不传复杂类型 ⇒ 免 enableV2Compatibility** |
| **V2 页面试点**（1 页） | `components/LogsTab.ets` + 其宿主接线 | 把日志数据搬 `@ObservedV2 class LogStore` + `@Trace text`，`LogsTab` 用 `@Local/@Param`；消除"日志页可见时整页重建" | ① `assembleHap` 零 error；② 复用既有 `KDC logflush #n` 计数验证：仅 `LogsTab` 重建、页面计数不增；③ 日志内容/滚动/清空行为一致 |
| **V3 风险复验**（必做） | `animateTo` 两处 | 抽屉开合（`DrawerOverlay`/`setDrawerOpen` 200ms）+ `HdsTabs.animationDuration(300)` 在 V2 试点后的动画逐帧对照（录屏抽帧或连续截图） | 无"动画失效/闪跳"（官方已知异常场景） |
| **V4 逐页推广** | 其余页面 | 每页一次性整页迁（同页禁止 V1/V2 混存），每页跑 V2 的复验清单 | 同上 + 真机截图 |

**回退**：每阶段单文件/单页提交，`git revert` 即可回 V1；V1 与 V2 组件可共存（只要不违反混用约束）。

## 5. 明确不做（本轮）

1. 不动 `state/` 下的 `@Observed` 业务类（`DeviceController`/`PayloadController`/`PairSession`…）——它们被 V1 组件用 `@ObjectLink` 订阅，属跨家族大改，留到 V4 之后；
2. 不引入 `AppStorageV2`/`PersistenceV2`（当前 `AppStorage` 用于绕 `HdsSideBar` 缓存，改造面大且与本次目标无关）；
3. 不为迁移而迁移纯展示组件（如 `GlassCard`），除非它落在试点页里。

## 6. 风险表

| 风险 | 影响 | 缓解 |
|---|---|---|
| `animateTo` 在 V2 场景异常（官方已知） | 抽屉/胶囊动画 | V3 专项复验；异常则把动画宿主组件保持 V1，只迁数据层 |
| `@Prop`→`@Param` 由深拷贝变引用 | 子组件改输入对象会影响父级 | 迁移时逐处核对；需要拷贝隔离的显式 `JSON.parse(JSON.stringify(...))` 或保持 V1 |
| codelinter 不可用 | 混用/严格模式错误只能靠编译发现 | V1/V2 边界在文档登记；每阶段 `assembleHap` 零 error 作为硬门禁 |
| V2 仍有 GAP（官方自述） | 个别 API 行为与 V1 不同 | 试点页先跑通再推广；遇 GAP 记录后暂停该页 |
| 与 S2/桥层改造并行的文件冲突 | 合并冲突 | V1/V2 试点文件（`LogsTab`/`DeviceInfoDialog`）与 S2 文件（`PayloadController`/`FilesTab`）不重叠 |

## 7. 需裁决项

1. 是否启动 V1/V2 试点（V1 叶子对照 + V2 页面试点各 1），还是整体推迟到桥层迁移（见另案）之后；
2. 若启动，试点页选 `LogsTab`（有实测重建数据可对照）是否认可；
3. 迁移成功标准里，"重建次数不增"是否作为硬指标（可复用既有 `KDC logflush` 遥测）。

—— Omp-ArkTS（不 commit/push）
