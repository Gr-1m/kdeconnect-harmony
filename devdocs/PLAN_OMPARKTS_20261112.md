# ArkTS 车道规划（Omp-ArkTS，2026-11-12）

> 依据：AtomCode MSG250（读 `kdeconn1111/` 新材料 → 出本规划）；配套 `devdocs/REFERENCE_KDECONN1111_TAKEAWAYS.md`（项目级）、
> `devdocs/REFERENCE_KDECONN1111_LANE_ACTIONS.md`（车道对照草案，A1–A7/E1 已给方向）。
> 本文件**只写规划，不改代码**；经总指挥复核后再开工。
>
> **证据分级**（采纳 C4，全篇标注）：`[已验证]` 文档/我方实测有证据 · `[代码事实]` 读代码可确认 · `[设计意图]` 规范目标 ·
> `[推断]` 我方映射 · `[计划]` 本文件提出。凡未跑过的验收一律**不写 ✅**（03:§2.8 同口径）。

---

## 1. 我方基线（写规划前的事实锚点，全部 `[代码事实]`）

| 项 | 事实 | 取证方式 |
|---|---|---|
| ArkUI 版本 | **V1 为主体**（21 个 `@Component`），V2 仅 2 个叶子（`components/LogsTab.ets`、`components/DeviceInfoDialog.ets`） | `grep -rl @ComponentV2` |
| 页面规模 | `pages/Index.ets` 2102 行（单页 + 多控制器装配）；`state/PayloadController.ets` 1412 行（最大状态文件） | `wc -l` |
| 状态结构 | `state/*Controller.ets`（`@Observed`）+ 注入回调装配（19 个控制器/辅助类）+ 18 插件 + 20 组件 | 目录清点 |
| 直连 native 的文件 | **5 个**：`entryability/EntryAbility.ets`、`net/PacketRouter.ets`、`pages/Index.ets`、`state/DeviceController.ets`、`state/PayloadController.ets` | `grep -rl libkdeconnect_napi.so` |
| 测试底座①（设备侧） | `entry/src/ohosTest` **12 套 hypium**（含 `PayloadController.test.ets`，文件内已如实登记 2 处覆盖缺口） | `ls entry/src/ohosTest/ets/test` |
| 测试底座②（宿主侧，秒级、无设备） | `tools/arkts-logic-test.sh`（bun 跑同一份 `*.test.ets`，hypium 替身 + ArkUI shim），当前 **76 例全绿**，登记 6 套 | 实跑 `bash tools/arkts-logic-test.sh` |
| 门禁 | `hvigorw --no-daemon assembleHap`（构建即类型检查）+ `entry/src/main/cpp/tests/run.sh`（cargo 测试 + NAPI check + 装配契约检查） | 本会话多次实跑 |
| 已知事故（自建素材，参考库**零覆盖**） | ① V1「稳定 ForEach key + 标量 `@Prop`」⇒ 子组件冻结首帧（进度不动）；② `HitTestMode.Block` ⇒ 屏蔽子节点，按钮点了没反应；③ 启动迁移早于控制器注入（`hostFilesDir` 尚为默认 `''`）⇒ 全部待处置条目误判「已结束」 | MSG229/245/240–242 真机取证 |
| `bridge/` 单一 native 入口 | **不符合**：5 处直接 import（`pages/Index.ets:3-4`、`entryability/EntryAbility.ets:12`、`net/PacketRouter.ets:9`、`state/DeviceController.ets:11`、`state/PayloadController.ets:20-21`），无 `bridge/` 目录 | `grep -rl libkdeconnect_napi.so` |
| V2 迁移资产 | `devdocs/PROPOSAL_STATE_V2_MIGRATION_20261108.md` 已有官方口径 + V1↔V2 映射表 + 混用约束 + 我方 5 个 V1 痛点（含各自当年补丁） | 读文件 |
| 契约流程资产 | `contract/CCR-1.md`（已生效）/`CCR-2.md`：提出 → 总指挥裁决 → 用户批准 → 对侧书面确认 → 同一改动更新 d.ts/errors/08 | 读文件 |

---

## 2. 可参考点清单

### 2A. `docs1111/02·03·04`（状态所有权 / V2 规范 / 后续指导）——ArkTS 可执行/不可执行

| # | 来源（文件:节） | 借鉴内容 | 我们将改哪里 | 结论 + 理由 |
|---|---|---|---|---|
| A-1 | 03:§4.1 | **只有单一 `bridge/KcBridge.ets` 可 import native**，其余文件只用 wrapper | 新增 `net/NativeBridge.ets`；收敛现有 5 个直连点 | **采用 → P0-4**。理由：直连 native 是宿主逻辑测试不可用的根因（导入即拉 cdylib 符号），收敛后 `DeviceController`/`PayloadController` 纯逻辑可在宿主秒级回归 |
| A-2 | 03:§4.3 + 02:§12-6 + 04:P0-6 | `onEvent` 分支内 `await` 造成**事件重排**；需串行队列/Promise 链（参考库自认**未解决**） | 审计 `PacketRouter`/`Index` 事件分支的 await（写文件、剪贴板、通知） | **采用（自建解法）→ P0-3**。理由：我方同构风险（接收终态/批次计数曾靠 `started` 重置兜底）；参考库无现成实现可抄 `[代码事实]` |
| A-3 | 03:§4.3/§2.8 | 事件解析**无 `any`**、每 kind 定义 interface、解析失败记录并 `return`、**异常不冒泡** | `net/PacketRouter.ets` + `plugins/*` 的 body 解析 | **采用（增量）→ P1-6**。理由：与新骨架一致、无行为风险；不为此重写现有已工作插件 |
| A-4 | 03:§6（12 条审查清单）+ 03:§5 契约流程 | 「先契约后实现」、契约/实现同一人同一批；审查清单 12 条 | 我方评审模板 + 派单口径 | **已具备**（`contract/CCR-1/2` 与我方"跨层改动先对齐"同构）⇒ 本规划只把**审查清单裁剪落地**（P1-7），不新增流程 |
| A-5 | 02:§9/§10（I3/I10/I11/I12） | 状态唯一写者；能力集/事件形状/deviceId 的单一来源 | 复核 ArkTS 侧是否出现「第二份状态」（已配对表、能力字符串、事件编号） | **评估 → P1-8**。理由：我方控制器不违规（违规的是同状态两份）；已核对「能力集由 native 提供、事件用字符串 type」，无编号复用风险 `[代码事实]`；27 处 `'kdeconnect.xxx'` 属**协议常量**，非能力集硬编码 ⇒ 不重构 |
| A-6 | 03:§4.2 / 02:§9 / 02:§12-10 / 04:P2-2 | V2 单页 + `@Local` + reducer；`store/adapters/ui` 拆分目标；**拆分前先补测试** | V2 迁移路线（P1-1）；拆分仅登记（P2-1） | **部分采用**：迁移口径采用（我方已验 V1→V2 叶子边界）；**拆分以下本轮不做**（见 §5「本轮不做」），理由：先补 P0-2 测试底座，避免「拆分放大回归面」 |
| A-7 | 03:§4.2 | `setInterval` 必须 `aboutToDisappear` 清理；订阅/注销成对 | `pages/Index.ets` 生命周期对称性自审 | **采用 → P1-3 附带**（与 HitTest 回归同批做一次静态自查）|
| A-8 | 03:§3.4 / 04:P2-3 | NAPI 单例：start 仅一次、stop 后不可靠重启；重启须 `SessionHandle`+改契约 | —（属 native 契约） | **不采用（P2 登记）**：我方当前不需 stop/restart；若需，属契约变更，走 native 车道 |
| A-9 | 02:§4.2 事件 kind 编号（3/4/5…） | 事件编号表 | — | **不采用**：我方契约是**字符串** `type`（`connected`/`packetReceived`…），与编号表无对应关系；仅需在合流契约时做差异比对 |
| A-10 | 04:§8 发布候选门 / 完成四级定义 | 门禁清单 + 「只有全部满足才写 ✅」 | 与 native 合并成一张发布门表 | **采用 → P1-5**；理由：诚实口径与我方 devdocs 一致，且能压住「文档写了＝已验证」的漂移 |
| A-11 | 03:§7 | >500 行或改架构的大重构，先写设计说明/任务卡 | `Index.ets` 拆分（P2-1）开工前置 | **采用**：符合我方 PROCESS；`PayloadController` 1412 行的抽离也按此走任务卡（P0-2） |

### 2B. `docs/kdeconnect-oh/06·09` + 参考 `Index.ets`（V2 页面）

| # | 来源（文件:节） | 借鉴内容 | 落点 | 结论 + 理由 |
|---|---|---|---|---|
| B-1 | 09:§5「logic 层」 | 纯逻辑与设备/Kit 解耦、可脱设备验证 | **已落地**：`tools/arkts-logic-test.{sh,ps1}` + `tools/logic-test/`（同一份用例双跑，当前 76 例 `[已验证]`） | **已采用** ⇒ 本规划只**扩大覆盖**（P0-2） |
| B-2 | 09:§3 闸门命令 | Rust：fmt/clippy/test/deny/audit/fuzz；ArkTS：逻辑测试 + 构建 + **codelinter** | 我方有效门禁 = `tools/arkts-logic-test.sh`（bun）+ `hvigorw assembleHap` + `check-injection-contract.py` + `check-encoding.py`；**codelinter 不可用**（商用 CLT 类型门禁，`AGENTS.md` 已实证 `[已验证]`） | **部分采用**：不引入 codelinter；P0-2/P1-3 把「新增用例 + 静态检查脚本」补进现有门禁 |
| B-3 | 09:§2/§4/§9/§10 | 按路径分车道、`contract/**` 共管走 CCR、关卡退出条件留证据、只写本车道 | **已具备**：`contract/CCR-1.md`（已生效：提出→总指挥裁决→用户批准→对侧书面确认→同一改动改 d.ts/errors/08 `[代码事实]`）、`AGENTS.md` 角色表与防冲突 7 条、sudo 政策 | **已采用**（不新增机制）；本规划的所有 P0/P1 均**不改契约**，故不触发 CCR |
| B-4 | 06:§4.1 | **`bridge/` 是唯一允许 `import native` 的目录** | 我方偏差 **5 处**：`pages/Index.ets:3-4`、`entryability/EntryAbility.ets:12`、`net/PacketRouter.ets:9`、`state/DeviceController.ets:11`、`state/PayloadController.ets:20-21` `[代码事实]` | **采用 → P0-4**（并保留 `EntryAbility` 为例外：Ability 生命周期必须持 native 句柄，注释写明） |
| B-5 | 06:§4.3 | 组件一律 `@ComponentV2`、**禁与 V1 混用**；订阅/注销成对 | 我方 = V1 主体 + V2 叶子（`components/DeviceInfoDialog.ets:13`、`components/LogsTab.ets:9`），且已有落地提案 `devdocs/PROPOSAL_STATE_V2_MIGRATION_20261108.md`（含官方 V1↔V2 映射表与混用约束）`[已验证]` | **采用该提案为迁移蓝本 → P1-1**（本规划不重写映射表；只补「逐页迁移顺序 + 验收矩阵」） |
| B-6 | 06:§8 评审清单 12 项 / 06:§1「补丁味」7 条 | 契约先行、无调用点特判/空 catch/二次字面量/跨层 import | 评审清单与红线 | **采用 → P1-7**（与我方 `INVARIANT_COVERAGE_CHECK.md`、`PLUGIN_ROUTE_INVENTORY.md` 并列） |
| B-7 | 参考 `Index.ets`（1387 行） | ① 状态全部 `@Local`+私有字段；② **回写统一「重建整体后整体赋值」**（`this.devices = [...rest, info]` 等）；③ 事件回调在 `start` 前注册、同步箭头函数调 `async onEvent` **不 await**；④ 生命周期/定时器成对（`aboutToAppear` 建、`aboutToDisappear` 清）；⑤ `PersistentStorage.persistProp` 声明身份键 | ④ 已与我方一致（`Index.ets` `onDidBuild`/`aboutToDisappear`、`MprisProgress` 局部 ticker），无需动作；②③ 与我方相同；① 属 V2 措辞 | **部分采用**：④ 纳入 P1-3 静态自查；②③ 作为**已知同构风险**并入 P0-3（事件重排）；① 见 B-8 |
| B-8 | 参考 `Index.ets` 结构（**全 app 仅 5 个 ets 文件、唯一 `struct`、零子组件**；`@Param/@Event/@Monitor` 全库零命中） | 「单 struct 巨页」写法 | 我方 20 组件 + 19 控制器/辅助类 | **不采用**：反向而行——参考库自认 `Index.ets` 巨石化是缺陷（02:§12-10、R10），其「零子组件」是**未拆分的结果**而非目标；我方按 B-5 提案继续渐进迁移与拆分（P2-1），不收缩到单 struct |
| B-9 | 06:§1 P2/P4、06:§7 | 错误沿 `Result`→NAPI 错误码→`KcException`，禁就地兜底；一张任务卡 = 一个原子变更 | 我方 `errors.v1.json` + `KcException` 解析 + 契约流程同构；提交由总指挥独占 | **已采用**（无动作） |


### 2C. 项目级 takeaways 中归属 ArkTS 的条目（A1–A7）

| # | 来源 | 结论 |
|---|---|---|
| C-A1 | LANE_ACTIONS A1（事件重排） | **吸收 → P0-3** |
| C-A2 | LANE_ACTIONS A2（`Index.ets` 巨石化） | **吸收为纪律**：新功能进 controller/组件，**不再往 Index 堆业务分支**；拆分登记 P2-1 |
| C-A3 | LANE_ACTIONS A3（ArkTS 无自动测试） | **部分纠正**：我方**有** 12 套 hypium + 宿主 76 例通道 `[代码事实]`；真实缺口是 **0.8.x 新增纯逻辑零覆盖** → **吸收 → P0-2** |
| C-A4 | LANE_ACTIONS A4（弹窗按钮四态） | **已完成**（MSG244/247）；仅保留「不回退」回归项 → P0-2 测试 |
| C-A5 | LANE_ACTIONS A5（启动迁移时机） | **已完成并自愈**（MSG242）；**推广为通用护栏** → P1-2 |
| C-A6 | LANE_ACTIONS A6（多文件选择 UI） | **无动作**（我方发送多选已通）；「批量接收全部保存」登记 P2-3 |
| C-A7 | LANE_ACTIONS A7（任务卡模板） | **吸收 → P1-7**（大改动派单附 目标/边界/契约/不变式/验收/风险） |
| C-C4 | TAKEAWAYS §6.1/§6.2（证据分级/风险登记） | **吸收 → P1-4**（本文件即按此写；roadmap 新增条目按 ID+严重度+状态+证据登记） |

---

## 3. 后续工作规划（P0/P1/P2）

> 任务卡字段沿用 04:§3 模板：目标 / 边界 / 契约 / 不变式 / 步骤 / 验收 / 风险·回滚。

### P0 —— 正确性/一致性（先做）

#### 任务：P0-1 剥离临时权限诊断（9 条 `KDC perm …`）

- **目标**：主工作区不留临时 hilog 诊断；真机取证完成后一次性剥离。
- **边界**：只删 `state/PayloadController.ets`（`KDC perm timeout/race …`）与 `pages/Index.ets`（`KDC perm request start/result/not granted -> jump to settings/request failed/no host context`）中的 `console.info`；**保留**真错误日志与用户可见 toast。不动行为。
- **契约**：不改。
- **不变式**：无新增。
- **步骤**：① 等真机跑完「撤销『图片和视频』→ 收 png」一次（MSG234 §5 判据）并回报；② `grep -c "KDC perm"` 归零；③ 门禁。
- **验收**：[ ] `hvigorw assembleHap` ✅；[ ] `run.sh` ✅；[ ] `grep -rn "KDC perm" entry/src/main/ets` = 0；[ ] 真机日志确认降级路径仍以 toast 呈现。
- **风险/回滚**：剥离后若真机再复现「不弹框/不降级」将失去一行级取证 ⇒ **阻塞条件**：负向分支未在真机通过前**不剥离**。回滚 = `git revert` 单提交。

#### 任务：P0-2 决策逻辑下沉 + 双通道测试覆盖（防 MSG240/241/245 类回归）

- **目标**：`detailActionMode` / `batchCounts` / 历史过期判定 / 文件名清洗等**纯决策**可在宿主秒级回归；真机只用于「不可自动化」的场景。
- **边界**：新增 `model/PayloadLogic.ets`（或 `common/PayloadLogic.ets`，无 `@kit.*`、无 native import）；`PayloadController` 改为**调用**该模块（保持对外行为不变）；新增 `entry/src/ohosTest/ets/test/PayloadLogic.test.ets` 并在 `tools/logic-test/run.ts` 注册（宿主通道）。**不改** UI、不改 native、不改契约。
- **契约**：不改。
- **不变式**：新增「弹窗按钮策略 = f(方向, 状态, settled, expired)」单一决策源（避免 UI 各处再判一次）。
- **步骤**：① 列函数清单与迁移边界（`detailActionMode`/`canDispose`/`batchCounts`/`fileExistsFor` 判定/`compactTimeTextOf`/`sanitizeFileName`）；② 抽离 + 控制器委托；③ 用例：四态按钮矩阵（含 expired/非接收）、批次派生计数（多批/迟到预告/失败计入）、过期迁移（文件在/不在/自愈）、文件名清洗（路径穿越/超长/空名）；④ 宿主跑一遍、设备侧 hypium 跑一遍。
- **验收**：[ ] `bash tools/arkts-logic-test.sh` 新增用例全绿（目标 ≥25 例）；[ ] `run.sh` ✅；[ ] 设备侧 `ohosTest` 同源用例通过；[ ] 真机：文件页四态行为不回退（沿用既有 dump 口径）。
- **风险/回滚**：抽离期间行为漂移 ⇒ 以「同源用例双跑」为安全网；回滚 = 保留 `PayloadLogic` 但控制器内联，或 revert。

#### 任务：P0-3 `onEvent` 分支串行化复评

- **目标**：需要保序的事件（payload 终态、批次计数、剪贴板、通知动作）按到达顺序处理；不需要顺序的显式注明。
- **边界**：`net/PacketRouter.ets`、`pages/Index.ets` 事件入口、`state/DeviceController.ets` 分发；必要时加单写者队列/Promise 链。**不改** native 事件语义。
- **契约**：不改（事件形状不变）。
- **不变式**：新增「同一设备的事件按到达序进入 reducer」；沿用「接收终态是队列推进唯一依据」。
- **步骤**：① 标注每个分支是否有 `await` 及是否需要保序；② 对需要保序者串行化；③ 造乱序事件用例（先把 `finished` 再 `progress` 等）断言终态/计数正确。
- **验收**：[ ] 用例（宿主或设备侧）覆盖乱序；[ ] 真机收多文件批次计数与状态无回退。
- **风险/回滚**：串行化引入延迟 ⇒ 只对「状态一致性强相关」的分支串行；其余保持并行并注释。

#### 任务：P0-4 native 依赖收敛为单一桥（前置：P0-2）

- **目标**：仅 `net/NativeBridge.ets` import `libkdeconnect_napi.so`；其余文件经 wrapper（类型化）访问。
- **边界**：新增/改写薄 wrapper；5 个直连文件改 import；**不改** native 导出与契约。
- **契约**：不改（wrapper 只做类型与错误映射）。
- **不变式**：保持「native 单例、start 仅一次」语义（决策卡 A-8 已定不引会话化）。
- **步骤**：① 列出各文件用到的 native 符号（`init/start/connect/sendPayload/keepPayload/cancelPayload/...`）；② 生成 wrapper（含 `KC_E<code>` 风格错误映射）；③ 替换调用点；④ 宿主通道加一个「wrapper 接口面」断言（导出名与 d.ts 对齐）。
- **验收**：[ ] `grep -rl libkdeconnect_napi.so entry/src/main/ets` 只剩 bridge（EntryAbility 如确需，单列例外并注明理由）；[ ] 门禁 + 宿主逻辑测试；[ ] 真机冒烟（连接/收发 1 张图）。
- **风险/回滚**：wrapper 抽象层过薄会变成噪音 ⇒ 只做「类型 + 错误 + 单例持有」，不加业务逻辑；回滚 = 逐文件回退 import。

### P1 —— 稳定性与发布前

| ID | 任务 | 目标/边界要点 | 验收 |
|---|---|---|---|
| P1-1 | **V2 逐页迁移**（以 `devdocs/PROPOSAL_STATE_V2_MIGRATION_20261108.md` 为蓝本，本规划只补「逐页顺序 + 验收矩阵」） | 整页一次迁、同页禁混用；页内 `@Local`、叶子 `@Require @Param`+`@Event`、跨页 `@ObservedV2` store；**不改**页面布局与行为 | [ ] KDC builds 计数不增（现有对照口径）；[ ] 真机截图逐页对照；[ ] 宿主逻辑测试全绿 |
| P1-2 | **注入完成断言（通用护栏）** | `Index` 装配末尾置 `wiringDone`；任何启动期迁移/后台任务依赖未就绪则**跳过并重试**（P0-2 的判定函数同时给出 `hostFilesDir` 空值护栏） | [ ] 用例：未装配时迁移跳过且不写盘；[ ] 真机冷启日志无「误判已结束」 |
| P1-3 | **UI 命中回归清单 + 静态自查** | 规则：`hitTestBehavior(HitTestMode.Block)` 只允许挂在**带 onClick 的容器**上，容器内不得放可点组件；`setInterval` 必须 `aboutToDisappear` 清理 | [ ] `tools/` 增静态检查脚本（可 grep 级）并入门禁；[ ] 全仓自查无违例；[ ] 真机复验「导出」「取消」可点 |
| P1-4 | **证据分级与风险登记（采纳 C4）** | devdocs 新条目按 `证据等级` + `ID/严重度(S1–S4)/状态(Open·Decision needed·Mitigated·Verify)/证据` 登记 | [ ] `ROADMAP_FUNCTIONAL_*` 与 `KNOWN_ISSUES.md` 用新格式登记本轮条目 |
| P1-5 | **发布门表合并（ArkTS 侧项）** | 通知允许/拒绝两路径、1GB 传输 UI（进度/内存/失败恢复）、8h 后台前台恢复、升级不丢 deviceId（UI 侧展示校验）| [ ] 与 native 门表合并成一张清单，逐项留证据 |
| P1-6 | **事件解析类型化（增量）** | 新插件/新分支：无 `any`、每 body 一 interface、解析失败记录+`return`、异常不冒泡 | [ ] 新增插件按此写；[ ] 老插件不重写 |
| P1-7 | **派单/评审口径落地** | 大改动附任务卡六段；评审用 03:§6 的 12 条清单（我方裁剪版） | [ ] `devdocs/PROCESS.md` 增一节 |
| P1-8 | **状态唯一写者复核** | 复核是否存在「第二份已配对表/能力缓存」；事件字符串 type 与 contract 对齐 | [ ] 复核结论写入 `devdocs/PLATFORM_INVARIANTS*.md` 或 roadmap |
| P1-9 | **「打开所在位置」评估**（roadmap §8.3） | 先探文件管理器 bundle 可行性（大概率不可行）；不可行则以「保存位置展示 + 引导文件 App」交付；**不改**已有「打开文件」（`startAbility viewData`） | [ ] 评估结论 + 若可行给出最小实现；[ ] 不可行则在详情弹窗展示路径 |

### P2 —— 扩展与架构（本轮不做，仅登记）

| ID | 任务 | 说明 |
|---|---|---|
| P2-1 | `store/adapters/ui` 拆分 | 先补测试（P0-2）再拆；`Index.ets` 减负，插件解析/系统 Kit 移出页面 |
| P2-2 | 插件注册表自动化（对应参考 P2-4） | 一份 `PluginDecl[]` 同时生成能力/路由/UI 注册 |
| P2-3 | 批量接收「全部保存」UI | 与 native 批量语义对齐后评估 |
| P2-4 | NAPI 会话化 | 属契约变更（native 车道），我方只登记 |

---

## 4. 与现有 backlog 合并去重

| 来源条目 | 处置 | 说明 |
|---|---|---|
| roadmap §8.2「跨会话未处置条目仍显示保存/丢弃」 | **关闭** | MSG231 `canDispose` → MSG243/247 四态细化，真机已验 |
| roadmap §8.2「failed 重建未带 `sandboxOnly`」 | **关闭** | MSG227/228 已补 |
| roadmap §8.2「`terminalIds` 无上限」 | **关闭（改为删除该状态）** | MSG242 用 `batchCounts()` 派生计数取代计数器，字段已删 |
| roadmap §8.2「native `.transfer_seq` 崩溃窗口」 | **保留** | 裁决为接受现状（native 车道） |
| roadmap §8.2「诊断剥离 10 条」 | **保留 → P0-1** | `KDC diag`/`KDC-DIAG` 已于 MSG228 剥离；剩 **9 条 `KDC perm`**（MSG234 新增，待真机验后剥） |
| roadmap §8.3「打开文件管理/所在位置」 | **吸收 → P1-9**（新增，0.8.x 评估） | 先探文件管理器 bundle 可行性；不可行则以「展示保存位置 + 引导」交付 |
| 我方未完成项：MSG234 负向分支真机复验 | **保留（阻塞 P0-1）** | 判据见 MSG234 §5 |
| 我方未完成项：行内「导出/取消」点击真机复验 | **保留 → P1-3** | MSG246 已修命中模式，待真机点一次 |
| 我方未完成项：V2 迁移复核 | **吸收 → P1-1** | LANE_ACTIONS E1 已定口径（整页迁、禁混用） |

> 另：`MSG250` 要求「先把手上的 P0 做完再纳入规划」——本车道视角的当前 P0 即 **P0-1（待真机）**，
> 不阻塞其余 P0；P0-2/P0-3/P0-4 可在不动 native 的前提下并行推进。

---

## 5. 排期建议

| 档位 | 内容 | 理由 |
|---|---|---|
| **0.8.x 内** | P0-2（逻辑下沉+双通道测试）、P0-4（native 桥收敛）、P0-3（事件串行复评）、P1-2（注入断言）、P1-3（命中回归+静态脚本）、P1-4（证据分级）；P0-1 待真机后立刻做 | 都是「不改变用户可见行为」的稳定性/正确性投入，且为后续 V2 迁移与拆分铺路 |
| **0.9.0 孵化前** | P1-1（V2 逐页迁移）、P1-5（发布门表合并）、P1-7（派单/评审口径）、P1-8（状态唯一写者复核）、P1-9（打开所在位置：评估先行） | 与孵化材料（REUSE/AI 红线/风险登记）同批，避免二次改动同一批文件 |
| **孵化后** | P2-1..P2-4 | 属架构改造，需先有测试底座与稳定契约 |

**本轮不做（明确清单）**：`Index.ets` 全量 `store/adapters` 拆分（P2-1）、NAPI 会话化（P2-4）、批量接收 UI（P2-3）、
插件注册表自动化（P2-2）、能力字符串集中化重构（A-5 判定为非问题）、事件 kind 编号对齐（A-9 不适用）。

---

## 6. 依赖与冲突

| 类型 | 内容 | 处置 |
|---|---|---|
| 跨车道（契约） | P0-2/P0-4/P0-3 均**不改** `contract/*` 与 native 导出 ⇒ 无 native 阻塞 | 若 P0-3 需要 native 侧事件顺序保证，再发 `TO_OMPNATIVE` 对齐 |
| 跨车道（归属） | ArkTS owner = CodeArts（角色表）；本规划经总指挥复核后按 owner 分派 | 我只在被指派分支内执行；`exp/*` 实验分支不入 main |
| 与 V2 迁移的时间冲突 | V2 逐页迁移会大改 `Index.ets`/组件 ⇒ **P0-2/P0-4 必须先做**（否则抽离成果被重写覆盖） | 排期顺序已体现 |
| 与孵化材料冲突 | 证据分级/风险登记（P1-4）与孵化 checklist 更新同批，避免重复改 devdocs | 由总指挥合并窗口 |
| 平台限制 | 「打开所在位置」无公开契约（roadmap §8.3） | P1-9：先评估，不承诺 |
| 参考库结论等级 | 参考文档自述「描述 kdeconn-1108 当前代码」，且其 R1/R4/文档漂移等**自身未修** ⇒ 不可当正确实现照抄 | 已在上表逐条标注 `[代码事实]/[设计意图]` |

---

## 7. 附：V1↔V2 术语对照与「无参考素材、须自建」清单

**术语对照**（避免 reviewer 把 V2 词当可执行指令）：

| 参考库（V2） | 我方（V1） |
|---|---|
| `@ComponentV2` + `@Local` | `@Component` + `@State` |
| `@Param` / `@Event` | `@Prop` / 回调成员（`onXxx: () => void`） |
| `@ObservedV2` + `@Trace` | `@Observed` + `@ObjectLink` |
| `reducer`/`upsertDevice` | `*Controller` 方法 + `@ObjectLink controller` |
| `store/` + `adapters/` + `ui/` | `state/` + `plugins/` + `components/` |

**须自建（参考库零素材）**：① V1 ForEach key/`@Prop` 冻结类问题；② `HitTestMode.Block` 命中规则；
③ 控制器注入顺序陷阱与「装配完成」护栏；④ ArkUI 侧真机取证配方（本会话已积累：注入 prefs 造态 + `uitest dumpLayout` + hilog 判据）。

—— Omp-ArkTS（2026-11-12）
