# REVIEW_ARKTS_STAGE3_20260926.md — 阶段 3 ArkTS 拆分整体逻辑评审（AtomCode）

> 2026-09-26。评审对象：远端 `dev/zcodeinit`（`5d3d41c`）上的阶段 3 ArkTS 改动——批次 1（`8fbf0c1` + `6c45fbf` 接线 + `e51c7ca` 遮罩修复）、批次 2（`133b3de`）、批次 3（`c8f7aea`）。
> 范围：`entry/src/main/ets` 共 12 文件，**+2277 / −1916**，Index.ets 从巨石页（约 4100 行）拆到 2128 行。
> 口径：**整体逻辑性**——状态分层、数据流向、层间契约、不变量保持；非补丁式逐行。
> 方法：匿名 HTTPS 临时克隆逐提交读 diff（本机无 gitcode SSH 私钥，本地工作区未动）。

## 1. 总体架构判断：✅ 通过——这是一次真正的结构性重构，不是搬代码

三条全局证据：

1. **统一且自洽的分层范式**：全部 6 个新模块（PairSession / NotificationHelper / NetworkWatcher / MprisController / PayloadController / SettingsController + PluginEventHandlers）遵循同一套契约——**领域状态归 @Observed controller；平台能力（Context/IO/UI/toast/持久化）一律注入回调；模块不 import 页面、不反向持有页面状态**。这不是逐批次各自发明，而是同一设计决定贯穿三批（各文件头注释均明示「与 PairSession 同一套范式」），说明拆分有统一架构蓝图（CodeArts MSG62 / DESIGN_BATCH2）而非边拆边定。
2. **数据流向单向且无环**：页面 @State 持 controller 实例 → Dialog 组件以 @ObjectLink 读 controller（`MprisDialog`/`ReceivedFilesDialog` 已核实）→ controller 经注入回调回调页面能力（notify/pluginsFor/actionGate…），装配集中在 Index.ets 的 `registerPluginEvents`/批次 2 装配段**一处**。native 只被 PayloadController 直接 import（NAPI 不需要 Context，合理破例并写明理由）。
3. **不变量被当作契约显式继承**：MprisController 头注释固化 4 条不变量（面板关着不写状态、插值时钟留在子组件、sinks 单槽过滤、发包口径）；PayloadController 固化 4 条（终态唯一驱动队列、size>0∧id==0 不建条目、safeFileName 单一来源、断连 failInflightReceives 兜底）。关键渲染优化（Mpris 面板关闭时丢弃周期推送、Progress ticker 子组件化）**在搬运中保持原位**——这是最容易在重构中退化成「图省事退回页面级 ticker」的点，没有退。

## 2. 逐领域核对

### 批次 1（低风险独立模块）
- **NotificationHelper**：状态（LogStore/节流定时器/idleness）归本类；与 UI 强耦合两点（resText/showToast）注入；`noticeKey` 留页面、经 `setNoticeKey` 回调告知——**依赖方向正确**（Helper 不反向持页面状态）。`logTabVisible` 注入省 CPU，非正确性依赖，边界意识清楚。
- **NetworkWatcher**：历史坑（多网卡连发 netAvailable 扎堆主线程）以头注释 + 3s 限频 gate 注入保留——**教训变成了契约**，后人不会无意回退。
- **PairConfirmDialog 遮罩修复**（e51c7ca）：按 CodeArts MSG63 §2 裁决关闭误触路径，属行为修正非拆分内容，独立成提交、可回溯——提交纪律好。

### 批次 2（MPRIS/音量 + payload 两个领域模块）
- **MprisController**（24 方法逐字搬运）：`isPanelFor` 门控同时护住 `setList`/`setSnapshot` 两个写入口，前后台分离语义集中一处而非散落判断；`svDeviceId` 单槽过滤保留（防切换面板串数据——对应 EXP_LESSONS systemvolume 的实测教训）。
- **PayloadController**（27 方法逐字搬运）：发送队列状态（sendQueue/sendBusyId/inflight/计数）整体迁入；`connectedDeviceIds` 注入而非自己读页面状态——failInflightReceives 兜底所需的最小信息面。
- 「逐字保真、零语义变更」的自述经抽查（状态转换/镜像方法）属实。

### 批次 3（SettingsController + PluginEventHandlers）
- 状态归 controller、动作走注入回调；`persistSettings` 留页面（controller 经注入依赖它）**避免 controller→page→controller 循环**；`systemName` 归位建议已在案（随批次 4 收尾，DevEco 车道）。
- PluginEventHandlers 无状态、纯转发——插件事件到 UI 的唯一收敛点，路由面（eventBus.on 5 条）在 Index 集中注册。

## 3. 风险与遗留（均非阻塞）

| # | 事项 | 定级 | 说明 |
|---|---|---|---|
| 1 | Index.ets 仍有 2128 行、残留大量 @State（连接/发现/记住的设备、抽屉、横竖屏等） | 建议 | 拆分未完成部分属批次 4 范围；注意「设备三列表」与 PairSession 的关联度高，拆出时需整体设计而非按行数机械分摊 |
| 2 | 注入回调的默认空实现（`() => {}`）意味着**漏装配不会报错、只会静默失效** | 建议 | 现装配集中一处尚可控；批次 4 若模块继续增多，可考虑装配完成后一次性自检（如 debug 断言关键回调非默认值），把「漏注入」从运行期静默变显式 |
| 3 | 「逐字保真」依赖搬运纪律，控制器内仍有个别直连平台 API（PayloadController 的 fileIo/picker/权限申请） | 记录 | 与其头注释「不碰 I/O」表述略有张力——文件选择器/权限本就属该领域职责，可接受；但批次 4 定范式时应明确「领域 I/O 可留、宿主能力必注入」的边界定义，避免两种口径并存 |
| 4 | systemName 归位（P3-1，已有决议） | 已跟踪 | 随批次 4 收尾 |

## 4. 结论

**阶段 3 ArkTS 拆分整体逻辑通过**：同一范式贯穿三批、依赖单向无环、历史教训固化为头注释不变量、关键性能语义（面板门控/ticker/sinks 过滤）搬运未退化。遗留 4 条均为批次 4 应纳入设计的建议项，无 P0/P1/P2。批次 1/2/3 此前各有独立评审报告，本轮为架构层复核，结论一致。

—— Atomcode（glm5.3-flash），2026-09-26
