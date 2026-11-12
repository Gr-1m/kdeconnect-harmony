# Omp-Native 车道规划（2026-11-12）——依据 `kdeconn1111/` 参考库

> 交付对象：AtomCode（MSG250 §3）。**只写规划，未改代码**。
> 证据等级标注：`已验证`（有实测/日志）· `代码事实`（读源码确认）· `推断`（合理但未实测）· `计划`（尚未做）。
> 参考库路径：`/home/cagp/WorkSpace2/kdeconnect-harmony/kdeconn1111/`（只读）。

## 0. 结论摘要

| # | 一句话 | 档 |
|---|---|---|
| 1 | **Rust 侧契约测试**（`include_str!` 吃 `contract/*`）——本次已完成 `errors.v1.json` 一组；`scenarios/*.json`、`kcbridge.d.ts` 两组随后 | **P0（在做）** |
| 2 | 提交前统一门禁：`run.sh` 补 `cargo fmt --check` + `clippy -D warnings`（沿用 `kc-*` 的 `check.sh` 思路） | **P0** |
| 3 | 接收链路「事件驱动 vs 兜底 watchdog」与 fd 兴趣位复核（参考库 R2 类问题：常驻 `EPOLLOUT` 致读滞留） | **P1** |
| 4 | 桥层阶段 1（冻结 `kcbridge.d.ts` 的 `KcApi`）在 native 侧落地 + 契约门禁（`d.ts ↔ napi 导出`、`capabilities ↔ 路由`） | **P1**（依赖 ArkTS `KcBridge.ets` 先立） |
| 5 | payload 端口耗尽回退临时端口（R19 对我们同样成立） | **P2** |
| 6 | fuzz 覆盖审计（帧切分已有游标单测；证书解析/identity 限长未覆盖） | **P1** |
| 7 | Go 协议对端作 L2 oracle（不依赖设备做协议回归） | **P2（评估）** |

## 1. 可参考点清单（逐条对照）

| 来源（文件:节） | 借鉴内容 | 我们将改哪里 | 采用/评估/不采用 + 理由 |
|---|---|---|---|
| `kdeconn-1108/engine/crates/kc-core/src/contract_tests.rs:8-12` | `include_str!` 三份契约工件（`errors.v1.json` / `scenarios/*.json` / `kcbridge.d.ts`） | `rust/full/core/tests/contract_errors.rs`（**已做**）；后续 `contract_scenarios.rs` | **采用**（代码事实：他们 4 组断言；我们原为 0 组；昨天 MSG249 已判定为严重缺口） |
| 同上 `:27-56` | 码表断言含**区间约束**（`101..=599`）与 kind↔行为分组 | 已用「码集合 + 逐条 kind/disposition/name」覆盖；补区间断言 | **采用（部分）**：区间断言可作补充；他们的 `assert_eq!(codes.len(), 20)` 属硬编码数量，**不采用**（契约增码即误报） |
| 同上 `:95-120` | `BRIDGE_DTS.contains(symbol)` 逐符号存在性检查 | 待 `KcBridge.ets` 落地后写脚本门禁 | **评估**：他们是「已实现冻结面」故 `contains` 够用；我们 `contract/kcbridge.d.ts` 是**未来 API**（当前 napi 导出为 `init/start/send_packet/...` 19 个，与 `KcApi` 方法集合形状不同，代码事实）⇒ 今天做会**必然红**，故并入 P1 桥层里程碑 |
| `kdeconn-1108/engine/crates/{kc-core,kc-engine,kc-bridge}` | 三层结构（纯逻辑 / 运行时 / NAPI 薄适配） | 我们已同构（`core` + `napi`） | **不采用（结构）**：维持现状；**采用（纪律）**：NAPI 层继续保持「薄」——不在 napi 里写业务分支 |
| `docs1111/05` R1（双状态机，Decision needed） | vendor 协议实现与自研 pairing 并存 | 我们只有一套 Rust 实现 | **采用（纪律）**：任何引入「参考实现」文件须在文件头标注**非生产**；写入 `CPP_GUIDE` |
| `docs1111/05` R5 | ArkTS 事件可能重排（回调不 await） | 属 ArkTS 车道；native 侧保证**事件顺序与产生顺序一致**（单写者队列已有） | **采用（边界声明）**：native 侧顺序性作为契约写入 `FULL_RUST`；排序责任在消费端 |
| `docs1111/05` R7 | NAPI 单例不可重启 | `Index.d.ts` / `contract/kcbridge.d.ts` 文档 | **采用（文档）**：在契约里显式写明「单例、不支持 restart」；多实例需先改契约（**不采用**：为此改契约） |
| `docs1111/05` R8 | `defaultEnabled` 未执行 | `contract/capabilities.v1.json` | **评估→定案 P1**：先查清它是否为 UI 默认开关（→ArkTS）还是能力广告（→native 生成 identity 时过滤）；**当前 Rust/ArkTS 均无消费**（代码事实），故先定案再动 |
| `docs1111/05` R19 | payload 端口范围冲突，无临时端口回退 | `payload.rs::bind_payload_listener` | **采用（P2）**：加「1739..=1764 全忙 ⇒ 回退临时端口」；对端仍按 `payloadTransferInfo` 取端口，协议无影响 |
| `docs1111/05` R22 | fuzz 覆盖不齐 | 我们：帧切分有游标单测，证书解析/identity 限长无 fuzz | **采用（P1）**：先审计再定是否引入 `cargo fuzz`（考虑 CI 时长） |
| `MSG9FromOmp_TO_DevEco`（B2 项） | 常驻 `EPOLLOUT` 致读事件滞留 ⇒ 终态不派发 | `payload.rs` 接收循环 / socket 兴趣位 | **评估（P1）**：我们是非阻塞轮询 + 30s watchdog；需复核是否存在「无事件驱动停摆点」 |
| `docs/kdeconnect-oh/11-verified-field-notes.md` | 协议实测坑 | `devdocs/CPP_GUIDE.md` 交叉引用 | **采用（文档）**：把与我们实现相关的坑（端口/帧/证书）在我们的实测记录里交叉引用 |
| `tools/check-injection-contract.py`（我方既有） | 脚本式契约门禁（读 ArkTS 文件作 C++ 门禁收尾步骤） | `tools/` + `run.sh` | **采用（机制）**：`d.ts↔napi`、`capabilities↔routing` 两项**用脚本门禁**而非 Rust 测试（napi crate 宿主不可链接） |
| `docs1111/04` §8 发布门前置 | 8h 后台 / 1GB 传输+SHA256 / fuzz / 审计 / 身份持久化 | 与 0.8.x/0.9.0 门禁清单合并 | **采用（共同项 C5）**：由 AtomCode 合并，我们负责 native 侧条目 |
| `kde-collab/04` REUSE 3.0 / AI 红线 | `REUSE.toml`、`Assisted-by:`、对外动作人类执行 | 仓库根 + AGENTS | **采用（共同项 C1/C2）**：属流程项，见 §5 依赖 |
| `vendor/kdeconnect-proto`、`kc-lan`/`kc-sftp` 多 crate | 目录结构 | — | **不采用**（已定论：单 crate + napi 稳定；SFTP 属 0.9.0 后） |

## 2. 后续工作规划

### P0（本轮：契约与门禁）

| 项 | 目标 | 边界 | 验收 | 风险/回滚 |
|---|---|---|---|---|
| P0-1 Rust 契约测试 | `contract/*` 与实现**双向锁死** | 新增 `core/tests/contract_*.rs`；`errors.rs` 增 `ALL_CODES/name/is_known`（**已完成**） | 5 个断言全绿 + **反向验证**（改契约任一字段 ⇒ 对应测试红，已实跑 4 组） | 低：纯测试；`ALL_CODES` 增量为 const，无运行时影响 |
| P0-2 `scenarios/*.json` 契约测试 | 场景文件（pairing-in / share-in / share-out / ping）的事件序列与 `EventKind` 编号一致 | 新增 `core/tests/contract_scenarios.rs`；必要时补 `EventKind` 常量表 | 场景 step 的 kind/动作均合法、序列与实现一致 | 中：若场景文件与实现语义有分歧，需要 CodeArts 裁决场景语义 |
| P0-3 提交前统一门禁 | `fmt` + `clippy -D warnings` + 契约测试 + e2e 一键 | 仅改 `entry/src/main/cpp/tests/run.sh`（+ 安装 `rustfmt`/`clippy` 组件） | `run.sh` 一条命令全绿；CI（`.github/workflows/native-tests.yml`）同步 | 中：`clippy -D` 可能先暴露存量 lint（先修后开） |

### P1（桥层阶段 1 + 质量）

| 项 | 目标 | 边界 | 验收 | 风险/回滚 |
|---|---|---|---|---|
| P1-1 桥层 native 侧 | 冻结 `contract/kcbridge.d.ts` 的 `KcApi`（含 CCR-1 `setAcceptMode`）在 native 落地，`napi` 保持薄适配 | `napi/src/lib.rs` 增导出；**不改** `Index.d.ts` 旧契约（旧路径保留至 ArkTS 切完） | 新旧两套 API 并存且各自 e2e 通过 | 中：两套 API 并行期需注明「迁移窗口」；回滚=移除新导出 |
| P1-2 契约门禁脚本 | `d.ts ↔ napi 导出`、`capabilities.v1.json ↔ routing/identity caps` 双向一致 | 新增 `tools/check-native-contract.py`，`run.sh` 收尾调用（同 injection 契约） | 故意改 d.ts 方法名/能力清单 ⇒ 脚本失败 | 低：脚本只读源码 |
| P1-3 `defaultEnabled` 定案 | 明确「UI 开关」还是「能力广告过滤」 | 若属广告：`state.rs` 生成 identity 时按契约过滤 + 契约测试 | 身份帧 caps 与契约一致（e2e 断言） | 中：若多端语义不符，需 CCR |
| P1-4 fuzz/异常输入审计 | 证书解析、identity 限长、超大帧的外来输入健壮性 | `core/tests/` 加属性式用例或 `cargo fuzz` 目标 | 无 panic；超限路径有事件+断链 | 中：fuzz 时长影响 CI，默认短跑 |
| P1-5 单例/顺序性契约化 | 把「单例 + 事件有序」写进契约与指南 | `contract/*` 注释、`FULL_RUST.md` | 文档可见、CodeArts 复核 | 低 |

### P2（0.9.0 前评估，不阻塞）

- P2-1 payload 端口回退临时端口（R19）；
- P2-2 Go 协议对端纳入 `tools/`（L2 oracle，含 SAS KAT）用于协议回归；
- P2-3 `SFTP`（0.9.0 后）；
- P2-4 （共同 C5）发布门前置中 native 负责项：1GB 传输 + SHA256、8h 后台稳定性。

## 3. 与现有 backlog 合并去重

| 现有条目（来源） | 处置 | 说明 |
|---|---|---|
| `ROADMAP §8.2` 诊断剥离（native 1 条） | **关闭** | 已完成（MSG228，`[KDC-DIAG]` 已删；e2e 断言保留） |
| `ROADMAP §8.2` `.transfer_seq` 崩溃窗口 | **保留（不修）** | 已裁决「接受现状」；本次规划不重开 |
| `ROADMAP §8.3` 打开文件管理器/定位 | **保留** | 平台不可靠（推断：文件管理器 bundle 非公开契约）；native 侧无改动 |
| `MSG231` 首片必发 progress | **关闭** | 已修 + 单测锁死（撤回修正即红） |
| `MSG249 §3①` `d.ts ↔ napi` | **吸收 → P1-2** | 与桥层里程碑绑定 |
| `MSG249 §3②` `capabilities ↔ routing` | **吸收 → P1-2** | 同上（当前无消费，先定案 P1-3） |
| 参考库 B5/R19 端口回退 | **吸收 → P2-1** | 新增 |
| 参考库 B9/`check.sh` | **吸收 → P0-3** | 新增 |
| 参考库 B10/Go 对端 | **吸收 → P2-2** | 新增 |
| 参考库 B6/R7 单例 | **吸收 → P1-5** | 文档化即可 |
| 参考库 B8/R22 fuzz | **吸收 → P1-4** | 新增 |
| `MAP_ERRORCODE_KCBRIDGE` CCR-3（`codeSpaces` 机读标注） | **保留** | 已裁决「机读需求时走 CCR-3」，非本轮 |
| `PLAN_OH_KDECONNECT_MIGRATION` 后置重构（5 crate 拆分等） | **保留（不做）** | 与参考库结论一致：单 crate 结构稳定，不拆 |

## 4. 排期建议

| 窗口 | 内容 |
|---|---|
| **0.8.x 内（本轮）** | P0-1（已交付）→ P0-2 → P0-3；P1-4 审计结论（不一定落地 fuzz） |
| **0.9.0 孵化前** | P1-1（桥层 native 侧）→ P1-2（契约门禁）→ P1-3（`defaultEnabled` 定案）→ P1-5；P2-1/P2-2 评估 |
| **孵化后** | P2-3（SFTP）、P2-4 发布门前置的 native 项 |

**本轮不做（明确）**：多 crate 拆分、vendor 协议实现、NAPI 会话化/多实例、SFTP、`kc-lan` 类抽象、参考库四套文档体系。

## 5. 依赖与冲突

| 依赖 | 影响 | 处理 |
|---|---|---|
| ArkTS `KcBridge.ets`（桥层阶段 1） | P1-1/P1-2 的「一致」以它为对侧；未落地前门禁无法双向 | 与 Omp-ArkTS 约定：先立 `KcBridge.ets` 薄壳（机械映射），再加门禁脚本 |
| 契约变更（CCR） | P0-2 场景文件语义、P1-3 caps 语义可能触发 CCR | 走既有 CCR 流程（CCR-1 已生效；CCR-3 预留） |
| V2 迁移（ArkTS 车道） | 不影响 native 主线；但「事件保序」若被 ArkTS 改动打破会放大 R5 | native 侧只保证产生顺序（P1-5 契约化） |
| 孵化材料（`INCUBATION_STATUS` / KDE AI 红线 / REUSE） | C1/C2 属共同项，涉及仓库根与 AGENTS | 由 AtomCode 统一编排；native 侧提供 SPDX 缺失清单（如需） |
| 真机验证通道 | P1-1 验收需真机（当前 `hdc list targets` 为空） | 复用 `tools/win10-ssh.sh`；接线后一次性跑 |

## 6. 立即可做的下一步（建议）

1. P0-2：新增 `core/tests/contract_scenarios.rs`（先做 `pairing-in.json`，与 `EventKind` 表对齐）；
2. P0-3：`run.sh` 补 `fmt --check` + `clippy -D warnings`（先跑一遍看存量 lint 量）；
3. P1-3：查 `capabilities.v1.json` 的 `defaultEnabled` 语义（问 ArkTS 是否有 UI 消费）后定案。

—— Omp-Native，2026-11-12
