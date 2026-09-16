# REVIEW_ASYNC_SENDPACKET.md — 评估：sendPacket 异步化提案（CodeArts MSG7 任务书）

> 2026-09-17。评审视角：独立功能实现评估者。结论先行：**技术上可行、当前不推荐做全量异步化**——治本（移出锁/缩短持锁）优先级更高；若锁修复后仍有残余阻塞，做「native 内串行发送线程 + Promise 化」的窄版。以下按任务书六问作答。

## 1. 可行性：**可行，无平台硬限制**

- OHOS NAPI 支持 `napi_create_async_work`（以及 Promise + deferred），鸿蒙三方 N-API 与标准 NAPI 语义一致；工作线程池执行、JS 线程立即返回，正是把「等锁 1.3~5.8s」移出主线程的正确原语；
- ArkTS 侧调用链 `PluginBase.send → PacketRouter.sendFrame → native.sendPacket` 全部可改 async/await（ArkTS 支持 Promise 语法），无语法障碍；
- **但有一个被任务书漏掉的平台事实**：`napi_create_async_work` 的回调（complete 回调）跑在 **UV 事件循环（JS 线程）**上——若开屏期 JS 线程仍被事件回调/渲染占住，complete 回调同样排队。异步化解决的是「不占 JS 线程」，不解决「回调按时到达」。对本场景（用户只需「能点」而非「立即发完」）够用，但值得写明预期。

## 2. 包顺序保证：**任务书的前提判断有误，必须纠正**

任务书问「异步入口能否保证入队顺序与调用顺序一致」——**用 `napi_create_async_work` 默认线程池：不能**。async_work 无顺序保证（并发执行、完成回调乱序），两个连续 sendPacket 可能以任意顺序 `enqueueTx` ⇒ **pair ack / battery / mpris 帧乱序，直接违反 KDE 协议要求**（identity→pair→插件的会话顺序被破坏，KDE 侧可能回 pair:false 或丢插件装载）。

任务书同时问「配对时序是否受影响（配对不在 sendPacket 路径）」——**这个前提也是错的**：`PacketRouter.sendFrame` 的 4 处调用全是 `kdeconnect.pair` 帧（:81/:94/:103/:175），配对**就在** sendPacket 路径上。异步化若引入乱序，最先坏的就是配对握手（这也是源码证据，非推断）。

**顺序保证的正确做法（二选一）**：
- **A（推荐）：native 侧串行化**——不给每个 sendPacket 开 async_work，而是 native 内部维护一个**单发送工作线程（per-stack 或 per-connection FIFO）**：`sendPacket` 只做无锁/细粒度入队（时间戳/序号排序），工作线程按序取出发送。入队顺序=调用顺序天然成立，JS 侧零改动顺序逻辑；
- B：ArkTS 侧 per-device Promise 链（`chain = chain.then(() => native.sendPacketAsync(...))`）——可行但把顺序契约放进 JS 纪律，插件一多必然漏（且每设备一条链，`requestedPeers`/竞态逻辑都要适配 await），脆弱。

## 3. 风险评估

| 风险 | 级别 | 说明 |
|---|---|---|
| **返回值契约破坏** | 高 | `sendPacket(): boolean` 被 **10+ 插件**消费（BatteryPlugin:77、ClipboardPlugin:63/75、ConnectivityReport:70、MprisPlugin ×7、PingPlugin:24…），`ok` 用于日志/toast/重试判定；改 Promise 意味着全部调用点改 async/await 或丢弃结果——影响面是「所有插件发送路径 + PacketRouter 全部配对逻辑」 |
| **配对时序** | 高 | 见 §2：配对就在 sendPacket 路径上；且 `handlePair` 的「双请求竞态回接受帧」依赖发送同步完成后的状态推进（`requestedPeers.delete` 后发 accept），异步化后这个窗口语义要重新论证 |
| **错误传递** | 中 | 当前同步抛异常/返回 false 即时反馈；异步后错误变 Promise reject / 错误事件，`KDC slow plugin send` 探针与「失败只给错误码」的 toast 契约（AGENTS.md 会话规则）都要重接 |
| **调试复杂度** | 中 | 当前「同步等锁」虽然卡，但**时序是确定的**——这正是本轮 1:1 埋点能一次定案的原因。异步化后同类问题将变成「回调何时到达」的非确定性问题，排查成本显著上升 |
| **半修复状态风险** | 中 | 10+ 插件不可能一次全改，「部分同步部分异步」期间顺序契约只覆盖改过的路径——比现在更糟 |

## 4. 与「移出锁」的关系：**互补，但顺序必须是移出锁在前**

- 不冲突：异步化解决「用户无感」（把等移出主线程），移出锁解决「等本身」；
- **但异步化是止痛片，且副作用不小**（§2/§3）：锁修复（omp 在途）把持锁降到 ms 级后，`sendPacket` 同步等待就是微秒~毫秒级——**异步化的收益随之归零，而契约破坏成本（10+ 插件 + 配对路径）已付**。这是典型的「先做了再说 regret」结构；
- 正确顺序：**分段计时 → 持锁段移出/缩短（治本）→ 若仍有不可消除的残余阻塞（如 hilog 抖动），再评估窄版异步**。

## 5. 实现复杂度估算

| 项 | 全量异步化 | 窄版（推荐，若将来需要） |
|---|---|---|
| native | async_work + FIFO 顺序保证 + 错误回调：~200–300 行，含并发语义重审 | 单发送线程 + 序号入队：~100 行；**d.ts 不变**（仍 boolean，语义变为「已入队」） |
| d.ts | `sendPacket(): Promise<void>`（破坏性变更，版本升级） | 不变或加可选异步出口 |
| ArkTS | PacketRouter + PluginBase + 10+ 插件调用点全改：~150–250 行，逐点回归 | **零改动**（JS 无感） |
| 回归成本 | 配对/双请求竞态/插件 toast/验证码时序全链路重测 | 仅发送路径 |

**任务书问的「锁竞争时才降级异步」混合方案：不推荐**——同一函数两种返回语义（boolean/Promise）会让 10+ 插件的调用点无法统一，比全量改造更脆。

## 6. 建议

**不推荐现在做全量异步化。** 理由收敛为三条：

1. **收益暂不存在**：治本在途，锁修复后同步 sendPacket 等待即 ms 级，异步化收益归零；
2. **成本前置且破坏面大**：返回值契约（10+ 插件）+ 配对路径乱序风险 + 非确定性调试，全是负资产；
3. **有更便宜的等效解**：若目标是「锁等待期间 UI 可点」，窄版（native 单发送线程，d.ts 语义改「已入队」）以 ~100 行 + 零 JS 改动达成同一用户体验，且不碰顺序契约（顺序由 native FIFO 保证）。

**优先级排序**：① 分段计时定位持锁段（当前在途）→ ② 持锁段移出/缩短（治本）→ ③ CN 校验（安全面，独立 commit）→ ④ **仅当 ② 之后仍有秒级残余阻塞**，再启动窄版异步化；全量 Promise 化**搁置**（除非未来有「发送结果驱动的 UI」需求——那时按新契约一次性做）。

—— Atomcode（glm5.3-flash），独立功能实现评估者
