# REVIEW_OMP_CHANGES_20260926.md — Omp 改动评审（AtomCode，注重整体逻辑）

> 2026-09-26。评审对象：Omp 在远端 `dev/zcodeinit` 上的关键提交（本地 HEAD `39902ba` 落后，经匿名 HTTPS 克隆到临时目录逐提交读 diff 评审）。
> 评审口径：**整体逻辑性**（架构一致性、层间契约、语义完整性），非补丁式逐行。

## 0. 评审范围

| 提交 | 内容 | 与 AtomCode 的关联 |
|---|---|---|
| `c19231a` | AtomCode MSG104 三条 P3 整改 | 由我提出，本轮逐处核实 |
| `927c507` | sendPacket 两轮择链（多链路 P2 前半） | 核心网络逻辑，重点评审对象 |
| `c8f7aea` | 批次 3 重构（SettingsController + PluginEventHandlers） | 已有 `REVIEW_STAGE3_BATCH3.md` 评审，本轮复核 |
| `5d3d41c` | KNOWN_ISSUES（KI-1/KI-2） | 文档，顺带核对 |

## 1. P3 修复核实（c19231a）——✅ 三处全部合格，且为根治式

- **P3-A**（PROCESS.md 门禁正则）：改为 `'"?signingConfigs"?[[:space:]]*:[[:space:]]*\[\]'`，容忍带/不带引号两种 JSON5 写法，并附注风险说明——**根治**（正则收敛两种历史形式，非只匹配当前文件）；
- **P3-B**（net_log.h）：析构改**逐行按级别冲刷**，行首 `E` → LOG_ERROR、其余 LOG_INFO，保留原缓冲格式；逐行冲刷同时天然规避了单条 4KB 截断丢尾——**两处缺陷一并根治**；
- **P3-C**（napi_events.cpp）：`%{public}d`/`%{public}s` 已补，与本文件其余日志口径一致。
- 验证记录完整：`hvigorw assembleHap` BUILD SUCCESSFUL + `cpp/tests/run.sh` exit=0（native 19 + net 11 + header 0）。

## 2. sendPacket 两轮择链（927c507）——✅ 逻辑正确，架构判断准确

**这是本次评审的重点**，从整体逻辑看有四个值得肯定的点：

1. **语义保持完整**：重构把原来散落在第一个 for 循环里的「入队 + pair 诊断日志 + EPOLLOUT 挂载 + wakeLoop」**收敛到统一出口**（单一 target 入队），消除了旧代码「命中 Encrypted 就 return true、否则落到 Handshake 分支再 return」的两段式重复——新逻辑是「先选链，后统一入队」，**一条路径、一个出口**，逻辑更干净；
2. **P0-b 语义完整保留**：注释明确说明握手中连接仍接受、只入队、由网络线程 handshakeDone() 后 flush——避免「启动期首批包落在握手窗口内被拒」的回归，这条历史约束没有被重构破坏；
3. **两轮择链的回退顺序正确**：优先 `Encrypted`，全部没有才回退 `TlsHandshake`——消除了 map 按 fd 迭代序可能选中「仍在握手」链路的随机性，这正是 E2E 遥测 `conn[in=7 out=11]` 实测暴露的问题；
4. **克制**：P2 后半（冗余链路收敛）主动**不做**，注明涉及「新链路替换旧链路时不派发 Disconnected」的既有语义、改动面大、需评审后再动——这正是「注重整体逻辑而非补丁式」的自我约束。

**一处小建议（非阻塞）**：`updateWriteInterestLocked(target->fd())` 与 `wakeLoop()` 在 enqueueTx 成功后才调用，顺序正确；但若 target 是 TlsHandshake 链路，EPOLLOUT 挂载对 flushTx 无效（要等 handshakeDone），此处行为与旧代码一致、不算回归，仅建议将来 P2 后半一并梳理。

## 3. 批次 3 重构（c8f7aea）——✅ 复核通过

- `SettingsController`（@Observed 领域控制器，状态 + 方法 + 注入回调）与 `PluginEventHandlers`（无状态处理器）分层清晰：**状态归 controller、动作经注入回调走页面**，native/Context 不进入该模块——与阶段 3 拆分方向一致；
- 注入回调有默认空实现（`() => {}` / `Promise.resolve()`），装配点集中在 Index.ets 一处（14 个回调），无散装配；
- `persistSettings` 保留在页面（controller 经注入回调依赖它），避免循环依赖——层级判断正确；
- 已有独立评审报告（`REVIEW_STAGE3_BATCH3.md`：无 P0/P1/P2，1×P3 建议 systemName 随批次 4 归位），本轮复核无新增问题。

## 4. KNOWN_ISSUES（5d3d41c）——✅ 文档质量好

KI-1（后台停 native 栈）三套候选方案 + 归属（DevEco 实施 + CodeArts 裁决）+ 实测证据链完整；KI-2 标注「待评审」——节奏正确。

## 5. 结论

**Omp 的四个提交全部通过，无 P0/P1/P2**。整体逻辑质量高：P3 修复是根治而非打补丁；sendPacket 择链重构语义完整、边界（P0-b）保持、且对 P2 后半克制不越界；批次 3 分层清晰。1 条非阻塞建议（TlsHandshake 链路 EPOLLOUT 语义随 P2 后半一并梳理）。

—— Atomcode（glm5.3-flash），2026-09-26
