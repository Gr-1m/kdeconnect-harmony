# kdeconn1111 参考库 → 双车道待参考/待改动清单（2026-11-11）

> 用途：把 `kdeconn1111/` 新增文档（`docs1111/` 当前进度与风险、`docs/kde-collab/` KDE 协作套件、`docs/kdeconnect-oh/` 治理层）里**与两条车道直接相关**的条目挑出来，作为后续开工时的对照表。
> 配套：`devdocs/REFERENCE_KDECONN1111_TAKEAWAYS.md`（项目级借鉴结论）；本文件只列「谁、在哪、要做什么」。

## A. Omp-ArkTS（`ets/**`、资源、页面）

| # | 参考点（来源） | 现状 | 建议动作 |
|---|---|---|---|
| A1 | ArkTS 事件回调 `onEvent` 是 async、回调不 await ⇒ 事件重排（`docs1111/05` R5） | 我们 `PacketRouter` 逐事件分发；插件回调逐个隔离异常，但**未验证是否严格串行** | 复核 `PacketRouter`/`Index` 事件处理：需要保序的事件（payload 终态、clipboard、通知动作）加串行队列或在 reducer 里只更新状态 |
| A2 | 单页 reducer 过大（他们 `Index.ets` ~1400 行，R10） | 我们 `Index.ets` 已很大（多 controller 已拆出） | 后续新功能优先加到 controller/组件，**不要再往 Index 堆业务分支**；可参照他们的 `store/adapters` 拆分路线 |
| A3 | ArkTS 无自动测试（R11） | 我们同样只有 injection contract 检查 | 新增纯逻辑（如 `detailActionMode`、批次计数、历史迁移）补最小单测或脚本化断言 |
| A4 | 详情弹窗按钮按状态细化（我们 MSG240–245 已做） | 四态已实现；行内按钮待移除（MSG245） | 与他们的「过期条目只有关闭」思路一致；注意**不要**回退成「已保存也显示丢弃」 |
| A5 | 历史/缓存迁移时机（我们 `31b69e2` 修的坑：迁移早于 `hostFilesDir` 注入） | 已修 + 自愈 | 后续任何「启动期迁移」都要排在 controller 注入之后，并加「依赖未就绪则跳过」护栏（可参照他们的 R20 身份持久化失败路径思路） |
| A6 | 多文件选择 UI（他们 P0-4：native 已通、UI 未接） | 我们已有发送多选（S1 完成） | 无动作；若要支持批量接收的「全部保存」，参照其批量 UI 设计 |
| A7 | 任务卡模板 / 完成四级定义（`docs1111/04` §3/§8） | 我们派单是消息制 | 可选：大改动派单时附「边界/契约/不变式/验收」四段，减少返工 |

## B. Omp-Native（`cpp/rust/**`）

| # | 参考点（来源） | 现状 | 建议动作 |
|---|---|---|---|
| B1 | **双实现陷阱**：他们 `kc-core::pairing` 完整但生产走 vendored `Link.pair_state`（R1，Decision needed） | 我们 C++ 已删，只有一套 Rust 实现 ✅ | 维护纪律：**不要**再引入第二套状态机；若未来引入参考实现，文件头必须标明「非生产」 |
| B2 | payload 常驻 `EPOLLOUT` 导致读事件滞留 ⇒ 终态不派发（`MSG9FromOmp_TO_DevEco` 的 native 修复） | 我们 Rust 用 tokio/自有循环；已有 30s 无进展 watchdog | 复核我们 receive 路径是否存在「无事件驱动」停摆点（watchdog 是兜底，不是驱动）；顺带确认 fd 注册只挂需要的兴趣位 |
| B3 | 失败/取消清理半成品（R4） | 我们 `payload.rs::finish()` 已 `remove_file(spool)` ✅ | 无动作；新增传输路径沿用「成功才 rename、失败删除」 |
| B4 | 批量发送无 per-device 队列（R6） | 我们已有单写者发送队列 ✅ | 无动作 |
| B5 | payload 端口无 ephemeral 回退（R19） | 我们仅 `1739..=TCP_PORT_MAX` 顺序试 | backlog：端口耗尽时回退临时端口（与对端协商仍用 `payloadTransferInfo`） |
| B6 | NAPI 单例不可重启（R7） | 我们同样是全局单例（`Index.d.ts` 契约） | 至少在契约文档写明「单例、不支持 restart」；测试如要多实例需先改契约 |
| B7 | `defaultEnabled` 未执行（R8） | 我们 `contract/capabilities.v1.json` 有字段，Rust/ArkTS 均无消费 | 定案：若只是 UI 默认开关→ArkTS 实现；若影响能力广告→生成 identity 时过滤 + 契约测试 |
| B8 | fuzz 覆盖（他们 parser/framer 已跑、SFTP/cert 未做，R22） | 我们覆盖情况未核对 | 复核 `cargo fuzz`/单元模糊测试覆盖：帧切分（已有游标单测）、证书解析、identity 字段限长 |
| B9 | `check.sh` 一键门禁（fmt+clippy+tests+contract） | 我们有 `entry/src/main/cpp/tests/run.sh` | 可补 `cargo fmt --check` / `clippy -D warnings` 进 run.sh，作为提交前统一门禁 |
| B10 | Go 协议对端（`docs/kdetestpeer-golang/`，L2 oracle，含 SAS KAT） | 我们靠模拟器/真机快照取证 | 评估纳入 `tools/protocol-peer/`，用于协议回归（不依赖设备） |

## C. 两车道共同（流程/合规/文档）

| # | 参考点（来源） | 建议动作 |
|---|---|---|
| C1 | **KDE 上游 AI 红线**（`kde-collab/05`）：MR 描述/评审回复人类独占、`git push`/建 MR 人类独占、`Assisted-by:` 而非 `Co-authored-by:`、MR 模板 `Used AI:` | 0.9.0 孵化前写入仓库 AGENTS：**对外动作人类执行**；自有仓库的 `Co-Authored-By: AtomCode` 不用于上游 |
| C2 | REUSE 3.0（`kde-collab/04`）：每文件 SPDX 或 `REUSE.toml` 覆盖 | 我们缺 `REUSE.toml`（JSON/图片/生成物需 annotations）；补一次全仓 `reuse lint` |
| C3 | OHOS 专有 SDK 与 GPL 链接/分发边界未评估（`kde-collab/04` §6） | Incubation issue 显式写明，请 sponsor 协助法务意见 |
| C4 | 证据分级（已验证/历史验证/代码事实/推断/计划）与风险登记表（ID+S1–S4+状态+证据） | 采纳到 `devdocs/`：新风险按行登记，未验证一律标 ⚠ |
| C5 | 发布门前置（他们 `docs1111/04` §8）：8h 后台、1GB 传输+SHA256、通知允许/拒绝两路径、SFTP multi-root、fuzz/审计、身份持久化 | 与我们 0.8.4/0.9.0 门禁合并成一张清单，逐项打勾 |
| C6 | 文档维护规则：代码行为变更必须同步 `01`（进度/证据）与 `05`（风险） | 我们对应 `devdocs/ROADMAP_FUNCTIONAL_*` + 本文件；改动当次更新 |

## D. 明确不做/暂缓

- **不在 0.9.0 前做**：全量 `store/adapters` 拆分（A2）、NAPI 会话化（B6）、SFTP 相关（他们强项，我们 backlog 的 S6）。
- **不照搬**：他们的 `kc-*` 多 crate 目录结构（我们单 crate + napi 已稳定）；他们的 `docs/` 四套文档体系（我们保持现有 devdocs 结构）。
