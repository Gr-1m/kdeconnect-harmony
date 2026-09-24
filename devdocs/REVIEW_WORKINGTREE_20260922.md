# REVIEW_WORKINGTREE_20260922.md — 工作区全量改动深度评审（AtomCode）

> 2026-09-22。范围：工作区未提交改动 vs HEAD `39902ba`（64 文件，+7715 / -2157，约 600 KB diff）。
> 工具：code_review deep 档（4 维度中 2 维完成，security/performance 维度工具超时未跑完——见 §4 局限）。
> 参照：kdeconnect-android / kdeconnect-kde 协议逻辑（AGENTS.md 跨端常量）、ohtotptoken UI 范式（HDS 组件 / ComponentV2 / lazy import / 资源化尺寸）。

## 1. 结论

**总体质量良好，未发现 P0 级问题**。发现 P1 × 1、P2 × 2、P3 × 2，全部可低成本整改；不构成里程碑验收阻塞（P1 除外，须在下次 commit 前修）。

## 2. 问题清单

### P1-1 `.stignore` 丢失 `.git` 排除项（双机协作风险）

- 位置：`.stignore:1-17`（现文件已无 `.git` 行）。
- 事实：AGENTS.md「共享目录的版本标记（2026-09-14 起）」明确 **`.git` 不同步**（Syncthing 搬不动活着的 git 仓库，会产生冲突副本、破坏单写者不变式）；PROCESS.md §9.3 也把 `.git` 列为 `.stignore` 独有排除项。当前文件删除了唯一强制该约束的机制。
- 失效模式：下一轮 Syncthing 同步即开始传播 `.git/`，`.git` 内出现 `*.sync-conflict-*`，甚至两机并发写 refs/index 损坏历史——正是 2026-09-13 事故同类。
- **整改**：~~立即在 `.stignore` 恢复 `.git` 一行~~ **✅ 已修复（2026-09-22 用户授权，`.git` 已恢复为第 2 行）**。⚠️ 若 Win10 侧 Syncthing 已跑过至少一轮，先检查 Win10 侧 `.git` 是否已出现冲突副本，由用户裁决处理。

### P2-3 / P3-4 侧栏已连接行徽章恒显「已配对」（UI 状态错报）

- 位置：`entry/src/main/ets/components/DevicesTab.ets:205-211`（`sideDeviceRow` 的 `if (connected)` 分支）。
- 事实：该分支无条件渲染 `$r('app.string.remembered_hint')`，而该资源值为「已配对」/ "Paired"（base/zh_CN string.json 已核实）。但本改动集的三态模型明确允许「已连接未配对」设备停留在已连接列表——同一 diff 里 `discoveredRow`/`connectedRow` 都用 `isPaired(d.id)` 区分 `remembered_hint`/`remembered_unpaired`，唯独侧栏漏了。这正是本改动集声称修复的「对端解除配对后本侧仍显示已配对」同类 bug。
- **整改**：~~`if (connected)` 分支按 `this.isPaired(d.id)` 条件渲染~~ **✅ 已修复（2026-09-22）**：已改为条件渲染 `remembered_hint`/`remembered_unpaired`（fontColor 同步区分 `dot_remembered`/`text_muted`），与 connectedRow 逻辑对齐；中性「已连接」chip（`connected_hint`）降为可选优化。待 Win10 侧下次构建验证。

### P3-5 新 payload NAPI 导出静默吞参（与 F1 约定不一致）

- 位置：`entry/src/main/cpp/net/napi_exports.cpp:261-279`（`JsSendPayload`/`JsKeepPayload`/`JsDiscardPayload`/`JsCancelPayload`/`JsSetCapabilities` 等）。
- 事实：本改动集在 `napiGetString`/`napiGetInt` 中确立了「取参失败 → 抛 TypeError，JS 侧立即可见」的 F1 约定，但 WP-1b 新导出在参数缺失/类型不符时静默返回 `0`/`false`（如 `if (argc >= 4) {…}` 无 else 抛错分支）。后果：JS 侧参数写错会被吞成「sendPayload 返回 0」，发送队列丢文件时无法区分「对端拒绝」与「调用方传参错误」。
- **整改**：~~复用 `throwFieldTypeError`/`napiGetString` helper~~ **✅ 已修复（2026-09-22，ZCode 侧同步落地，经本机核实）**：新增 `requireArgc`/`jsGetStringStrict`/`jsGetDoubleStrict`，全部 9 个导出（sendPayload/keepPayload/discardPayload/cancelPayload/setCapabilities/getPeerCertificate/getPairVerificationCode/setTrustedCertificate/removeTrustedCertificate）失败路径均抛 TypeError，覆盖超出评审建议范围。

## 3. 与参考端的核对结论（抽样）

- 协议层：插件 packet type / caps 汇总（registry 单一来源）、pair/unpair 分层、`connected`/`disconnected` 事件全路径派发等，与 AGENTS.md 协议约束及 Android 插件架构一致；未发现背离。
- UI 层：对照 ohtotptoken（HDS 范式），本工程 `DevicesTab` 徽章/状态 chip 的三态意识是对的，仅 §2 P2-3 一处漏网；资源化字符串、深浅色 color.json 均已到位。

## 4. 局限（如实声明）

- code_review 深度评审 4 维度中 **correctness / tests_contracts 已完成**，**security / performance 两维度工具执行失败未跑完**；后续可在改动收敛后（如 commit 前）对这两个维度补跑一轮。
- 评审基于 diff 与定点核实（.stignore、DevicesTab、string.json 已逐一读源确认），未运行构建。

## 5. 处置建议（给 CodeArts 裁决）

1. P1-1 由本机 agent 立即修复（一行），并通知 DevEco 检查对端 `.stignore` 与冲突副本；
2. P2-3/P3-4 归入 DevEco 下一轮 UI 整改（小改动，建议与在途工作合并，不做补丁式分批提交）;
3. P3-5 列入 native 侧待办，随 WP-1b 收尾统一处理，不单独出 commit；
4. security/performance 两维度在改动 commit 前补跑。

—— Atomcode（glm5.3-flash），2026-09-22
