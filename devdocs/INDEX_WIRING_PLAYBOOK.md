# INDEX_WIRING_PLAYBOOK.md — Index.ets 接线指导方案（供总指挥参考）

> 2026-09-26。编写 Atomcode（评审）。依据：ROADMAP 方向 A 步骤 5-9 全貌 + 批次 1/2 实际执行数据 + 历次评审教训。
> **定位**：这不是对某一轮的评审，而是「方向 A 剩余接线怎么走」的操作规范——批次节奏、门槛、不变量、验证分层、风险预案，总指挥可直接照此排期与验收。

## 一、现状基线（2026-09-26 实测，非估算）

| 项 | 值 | 出处 |
|---|---|---|
| Index.ets 行数 | **2598 行**（目标 <1500）；批次 2 接线完成后将达 **~1681 行**（−917/+77 在途 diff） | grep/wc 实测 + 在途 diff |
| 已完成抽取 | DrawerOverlay(304) + PayloadDetailDialog(103) + PairSession(335) + PluginEventBus(83) + 批次1四模块（~350） | ROADMAP 步骤 1-5 ✅ |
| 批次 2 在途 | MprisController(332) + PayloadController(**564**) + MprisDialog(348) + ReceivedFilesDialog(107)，已接线未提交 | 工作树 |
| 剩余 | 批次 3（Settings ~79 + PluginEventHandlers ~97）、批次 4（DeviceController ~466 + DeviceActionController ~145）、步骤 9 收尾 | ROADMAP |

**关键判断：批次 2 落地后，Index.ets 只剩 ~1681 行，距目标仅差 ~180-660 行**——剩余工作量集中在批次 4 的高耦合核心（handleEvent 枢纽），这是方向 A 真正的风险段。

## 二、批次节奏（已验证的「三段式」，照抄即可）

批次 1/2 实际验证过的节奏，每批固定三步：

1. **先建模块**（DevEco）：Controller（@Observed 状态 + 方法 + 注入回调）与 Dialog（@Prop/@ObjectLink + 回调回抛）作为**新文件**先落，`devecocli build` 通过——此时 Index 零改动，零风险；
2. **原子替换接线**（DevEco，MSG63 新分工后由他自做）：旧方法删除 + 旧 UI 内联体删除 + 页面装配注入，**一个 diff 完成**，不可分批（批次 1 曾论证：删旧方法与改转发必须同批，中途必然编译失败）；
3. **代提交 + 验收**（Omp）：`assembleHap` + ohemu 冒烟（首屏截图 + `plugin routes registered: N` + native 日志）+ **参数级保真比对**（对删除的每类调用抽取实参多重集比对 old/new）+ grep 旧符号清零 → commit + push。

**评审卡点（我）**：模块新文件到达即评审设计/接口（批次 2 的 39 个字段/方法名 grep 零 MISS 的做法）；接线 diff 到达后按固定四重点评审——**旧代码清零 / 注入装配正确性 / 生命周期成对 / @ObjectLink 绑定源**。

## 三、不变量冻结清单（任何批次接线不得触碰，改动须总指挥书面裁决）

1. `paired` 只由 `setPairedFlag()` 改写（单一写者）；
2. 配对会话三信号终局（对端拒绝 / disconnected / 超时；awaiting/prompt 期间无关 error 不判失败）；
3. `systemvolume.sinks` 单槽过滤（`deviceId !== this.mprisDeviceId` 则丢弃）；
4. MPRIS `canClaim` 焦点裁决（`listed && (currentPlayer 空 ‖ target===current)`）；
5. payload 终态是发送队列推进的唯一依据（不加 sleep）；
6. `payloadSize>0 ∧ payloadTransferId==0` 不建条目；`safeFileName` 单一来源（PayloadHistory）；
7. 配对验证码与请求帧同一时间戳（v8 协议）；确认/接受帧不带 timestamp；
8. 弹层实底色不用毛玻璃（THICK 整屏重算）；ForEach 键不变→子组件不重建（需 @Observed class + @ObjectLink）。

## 四、每批验收门槛（Omp 提交前必须全绿，缺一不提交）

| # | 门槛 | 说明 |
|---|---|---|
| 1 | `assembleHap` BUILD SUCCESSFUL | 硬性 |
| 2 | ohemu 冒烟 | 首屏截图与接线前一致 + 启动日志（`plugin routes registered: 7` / `native start ok` / 无 SyntaxError） |
| 3 | 参数级保真比对 | 删除的每类调用：old/new 实参多重集一致（MSG68 方法） |
| 4 | 旧符号 grep 清零 | 被删方法名/字段名/内联 UI 特征串在 Index 全 0 |
| 5 | 不变量清单（§三）逐项保持 | 评审签字项 |
| 6 | 我的评审回执 | 每批一个 MSG，无 P0/P1 方放行 |

## 五、验证分层（环境硬约束，写清楚避免把证据用错）

| 层 | 能力 | 能证明什么 | 不能证明什么 |
|---|---|---|---|
| **ohemu**（Linux，零配额签名） | 首屏截图 + 日志 | 模块加载不炸、路由注册、native 栈、无 SyntaxError | **点击级 UI 交互**（无 uinput，2026-09-26 实证已入 AGENTS） |
| **Win10 平板真机** | 交互级 | 配对/弹窗/进度行动态推进等交互 | **装不了 localSign 包**（`9568257 fail to verify pkcs7`，HarmonyOS 平板拒 OpenHarmony 本地签名）⇒ 交互验证仍需华为侧签名/正式签名 |
| **华为云签名配额** | 同上 | 同上 | 月度配额限制（批次 1 曾被 `Provision number exceeds limit` 卡住） |

**排期含义**：批次 3/4 可以**连续推进**（ohemu + 构建门槛足够放行结构改动），但**交互级回归必须攒批**——等签名窗口（配额恢复或 DevEco 正式签名）一次性跑全量交互回归（配对/race/断链/超时/MPRIS 切换/文件传输多选/进度行动态推进），**不要每批等一次真机**（浪费配额窗口，拖慢节奏）。

## 六、批次 2 在途的两个具体问题（总指挥可先裁定，不用等评审回执）

1. **PayloadController 564 行**，超我 MSG35 建议的 400 行阈值——建议发送队列（`pumpSendQueue/onSendPayloadSettled/stageSendJob/forgetSendQueue` 4 方法 + 队列状态）拆出 `state/PayloadSendQueue.ets`，Controller 只持有队列实例。可随本批一并提交，也可批后做（不阻塞）；
2. **6b 进度行刷新链路是本批最大评审专项**：@Observed 只观测顶层属性赋值、`PayloadRow` 是 @Prop 标量拷贝——元素内部字段原地更新时行如何刷新，必须与现状 Index 机制同构。我接线评审会专项核此项（真机交互验证前，靠代码链路推演 + ohemu 日志留痕）。

## 七、批次 3/4 风险预案

- **批次 3（低风险）**：SettingsController / PluginEventHandlers 都是独立块，照 §二 节奏走即可，预计一轮完成；
- **批次 4（真正风险段）**：`handleEvent` 是核心枢纽（connected/disconnected/error 三事件 + 配对/信任/派生列表），与几乎所有 Controller 耦合。预案：
  1. **先出接口设计再动刀**（批次 2 的 DESIGN 先行模式强制化——批次 4 无设计文档不开始）；
  2. DeviceController 预计仍需拆子模块（ROADMAP 已预判「可能需要拆成更小的子模块」）——建议拆 `DeviceListController`（派生列表）+ `TrustController`（信任/证书钉扎），handleEvent 本体留在页面做纯分发（转发给 pairSession + 各 Controller），**不要试图把 handleEvent 整个搬进一个 Controller**（它会变成新的 Index）；
  3. 批次 4 完成后 Index.ets 目标 ~800 行（骨架 + 4 页签装配 + 卡片动作分发 + 生命周期），与 ROADMAP 步骤 9 的 620-800 行吻合；
  4. **P3-5（系统 CustomDialogController）/ P3-6（卡片材质分层）在批次 4 接线时顺带做**（ROADMAP 方向 D 原定「随 R1」，批次 4 就是 R1 的最后一刀，别留到后面）。

## 八、给总指挥的一句话排期建议

**批次 2 验收通过即连排批次 3（低风险快速过）→ 批次 4 先设计文档后动刀 → 步骤 9 收尾（含 P3-5/6）→ 方向 A 收口**。期间交互级回归攒一个华为签名窗口一次性跑完（§五），不等真机则不阻塞结构推进。按此节奏，方向 A 预计 **3-4 个迭代内收口**，为方向 B/C（远程输入/通知读取）腾出阶段 4。

—— Atomcode（glm5.3-flash），评审工作负责人
