# 双车道统一规划（2026-11-12，总指挥合并版）

> 输入：CodeArts MSG252（参考文档 14 点借鉴 + P0/P1/P2 + 七问）、Omp-Native `PLAN_OMPNATIVE_20261112.md`（`925c94a` 入库）、总指挥 `REFERENCE_KDECONN1111_TAKEAWAYS/_LANE_ACTIONS`。
> 基线：`main = 925c94a`（Rust 契约测试 errors 组已入库）。本文是**唯一排期口径**，后续以本文为准。

## 0. 先纠正快照（CodeArts 评审基于 `2dfe44c`，已落后 3 个提交）

| CodeArts 列为 P0 | 现状 |
|---|---|
| P0-1 行内「保存/丢弃」按钮（点不动） | **已完成** `f2c2a64`（行内按钮移除 + `HitTestMode.Block` 根因修复） |
| P0-2 历史行 key 未含方向（收发混组） | **已完成** `fdebf97`（`fileName\|deviceId\|direction` + 「接收/发送」前缀） |
| P0-3 聚合箭头/行点击分离、44vp 热区 | **已完成** `a03fef6`（箭头独立热区）+ `f2c2a64`（行点击只覆盖名字+状态行） |
| P1-3 `expired`/canDispose 过期条目残留 | **已完成** `31b69e2`（迁移时机修正+自愈）/ `ecbee5d`（四态按钮） |
| Rust 契约测试（CodeArts 未列，用户判定严重） | **已完成** `925c94a`（errors 组 + 反向验证 5 项） |

> 请 CodeArts 后续评审先 `git pull` 到最新 main（本次 `925c94a`），否则会重复报已修项。
> 关于 ASCII：`·`/`~` 属**我们自有仓库的中文 UI 文案**，不适用上游 ASCII 红线；ASCII 仅在将来向 KDE 上游提交的代码/提交信息时执行。

## 1. 七问裁决

| # | 问题 | 裁决 |
|---|---|---|
| Q1 | 是否采纳 `kcbridge.d.ts` 冻结的 `KcApi`（20 方法，与现有 19 个 snake_case 导出形状不同） | **采纳，但分期**：P1 走 **CCR-3（只增不减）** + 新增 `KcBridge.ets` 适配层；**不改**现有 `Index.d.ts`/napi 导出（并存过渡）；native 补齐缺失导出（`generate_identity`/`set_on_event`/`set_auto_accept_sec`/`request_pair` 等） |
| Q2 | `defaultEnabled` 语义 | 定为 **UI 默认开关**（ArkTS 实现，`SettingsController` 默认值）；**不做**能力广告过滤；若将来要过滤，另开 CCR |
| Q3 | `canCreateSftpServer` 能力声明 | **不声明**（SFTP 未实现，避免广告不可用能力）；S6 落地后再走 CCR 增加 |
| Q4 | `PacketRouter.handlePair` 配对状态回写归属 | **暂留 ArkTS（展示层）**；配对状态权威仍在 native；桥层阶段 2 下沉 native 时一并迁走 |
| Q5 | 命名规约 `scenes/identities`（P0-4） | **不采纳**：改 identity 字段有兼容风险、收益低；记入「不采用」清单 |
| Q6 | `.kde-ci.yml` / `REUSE.toml` 谁写 | **总指挥写**（`fdebf97` 后的文档批），CodeArts 评审；孵化前必须完成 |
| Q7 | SRP 类型列表转 native 常量（P2-4） | **0.8.x backlog（低优先）**，本批不做 |

## 2. 统一排期

### P0 — 0.8.x 收口（本周）

| ID | 任务 | Owner | 验收 |
|---|---|---|---|
| P0-A | `scenarios/*.json` 契约测试（在 `contract_errors.rs` 同目录新增 `contract_scenarios.rs`） | Omp-Native | 场景 JSON 与路由/事件名一致；反向验证必红；`run.sh` 收编 |
| P0-B | `run.sh` 补 `cargo fmt --check` + `clippy -D warnings` | Omp-Native | 全绿；现有告警清零 |
| P0-C | 「导出」按钮命中真机复验（`Block` 移除后） | 用户点按 + 我取证 | 弹系统保存选择器 |
| P0-D | 文档同步：本文件 + ROADMAP §9 + AGENTS（AI 红线/Assisted-by） | 总指挥 | 入库 |

### P1 — 0.9.0 孵化前

| ID | 任务 | Owner | 说明 |
|---|---|---|---|
| P1-1 | `KcBridge.ets` + `KcApi` 适配（CCR-3） | Omp-ArkTS（适配层）+ Omp-Native（补导出） | 旧 `Index.d.ts` 并存；`contractVersion` 启动校验 |
| P1-2 | `d.ts ↔ napi` 契约门禁脚本 `tools/check-native-contract.py` | Omp-Native | 依赖 P1-1 落地后接线，`run.sh` 收编 |
| P1-3 | `defaultEnabled` → UI 默认开关落地 | Omp-ArkTS | 按 Q2 裁决，不动能力广告 |
| P1-4 | fuzz/异常输入审计（parser/framer/cert/identity 限长） | Omp-Native | 至少 `cargo fuzz` 目标清单 + 一次运行记录 |
| P1-5 | 「单例 + 事件有序」契约化（写入 d.ts 注释 + KcBridge 串行队列） | 两车道 | 事件重排（参考库 R5）我们需自证 |
| P1-6 | `REUSE.toml` + `.kde-ci.yml` + AGENTS AI 红线 + OHOS SDK 许可风险 | 总指挥 | 孵化 issue 里显式写明许可风险 |

### P2 — 孵化后 / 评估

| ID | 任务 | Owner |
|---|---|---|
| P2-1 | payload 端口耗尽回退临时端口（参考库 R19） | Omp-Native |
| P2-2 | Go 协议对端纳入 `tools/protocol-peer/` 作 L2 oracle | Omp-Native（+我） |
| P2-3 | SFTP（S6） | Omp-Native |
| P2-4 | SRP 类型列表 → native 常量 | Omp-Native（低优先） |
| P2-5 | V2 迁移收尾：V3 `animateTo` 复验 + V4 逐页推广 | Omp-ArkTS |

## 3. 明确不做（本周期）

- 多 crate 拆分（`kc-lan`/`kc-sftp`）、`vendor` 双状态机、NAPI 会话化、参考库四套文档体系；
- 命名规约 `scenes/identities`（Q5）；
- 能力广告过滤（Q2 若需要另开 CCR）；
- 0.9.0 前不做 V4 全量迁移（只做 V3 复验）。

## 4. 依赖与风险

1. **P1-1 是 P1-2 的前置**，且要一次 CCR-3 定稿 `KcApi` 方法表；
2. **P1-3/P1-5 与孵化材料冻结冲突**：孵化申请前两周冻结契约与对外口径；
3. **P0-A/P0-B 必须在 0.8.x 收口前完成**（契约测试是防漂移底线）；
4. ArkTS 侧规划文档（`PLAN_OMPARKTS_20261112.md`）**待交付**——若与本文冲突，以本文裁决为准，其可作细化。

## 5. ArkTS 车道规划并入（`devdocs/PLAN_OMPARKTS_20261112.md`，2026-11-12 收）

ArkTS 规划的基线事实与我们一致（V1 主体 + 2 个 V2 叶子；`Index` 2102 行；5 个文件直连 native；
12 套 hypium + 宿主 bun 逻辑测试 76 例；门禁 = hvigorw + run.sh）。**采纳其 P0/P1 任务，并做两处合并调整**：

| ArkTS 规划项 | 并入方式 |
|---|---|
| **P0-1** 剥离 9 条 `KDC perm` | 保留，**阻塞条件不变**：需真机完成一次「撤销图片和视频 → 收 png」的负向复验（MSG234 §5）；未验前不剥 |
| **P0-2** 决策逻辑下沉 + 双通道测试（`PayloadLogic` + 宿主 76 例通道 + ohosTest 同源） | 采纳，列为 **P0-A2**（ArkTS 车道 0.8.x 首要项） |
| **P0-3** `onEvent` 分支串行化复评 | 采纳，列 **P0-A3**；与统一规划 P1-5（单例/事件有序契约化）合并实施：先 ArkTS 侧串行队列，再写入契约注释 |
| **P0-4** native 依赖收敛为单一桥 | **与统一规划 P1-1 合并**：直接落 `KcBridge.ets`（阶段 A 收敛现有 19 个 snake_case 导出 → 阶段 B 适配 CCR-3 的 `KcApi`），避免两次搬迁 |
| P1-1 V2 逐页迁移 / P1-2 装配完成断言 / P1-3 命中回归+静态检查 / P1-4 证据分级 / P1-5 发布门 / P1-6 类型化解析 / P1-7 派单口径 / P1-8 状态唯一写者 / P1-9「打开所在位置」评估 | 全部采纳，编号沿用 ArkTS 规划（P1-x），与本文 §2 的 P1 同档 |
| P2-1~P2-4（store 拆分、插件注册表、批量接收 UI、NAPI 会话化） | 与本文「不做清单」一致：本轮不做，仅登记 |

**冲突裁决**：
1. 「单一桥」只做**一次**（合并 P0-4 与 P1-1），阶段 A 用现有导出、阶段 B 接 `KcApi`；两阶段都不得改 `contract/`（阶段 B 走 CCR-3）。
2. V2 逐页迁移（P1-1）必须排在 P0-A2/P0-A4 之后，否则抽离成果会被迁移重写。
3. ArkTS 侧 P0 不阻塞 native 侧 P0（scenarios 契约测试、run.sh 补 fmt/clippy），两车道可并行。

**backlog 处置确认**（与 ArkTS 规划 §4 一致）：§8.2 的 canDispose / sandboxOnly / terminalIds 三项 **关闭**；
`.transfer_seq` 崩溃窗口 **保留不修**；诊断剥离 **仅剩 9 条 `KDC perm`（待真机负向分支）**；
§8.3「打开文件管理/所在位置」→ **P1-9 评估**（先探文件管理器 bundle 可行性，不可行则以「展示保存位置 + 引导」交付）。
