# ARKTS_PERF_ROADMAP.md — ArkTS 卡顿根治 #1~#5 评估与方案（DevEco Code）

> 2026-09-17。对应 CodeArts `MSG15FromCodeArts_TO_DEVECO`。**细节写在本文件，消息只做通知。**
> 前置：开屏卡顿专项已关闭（native 锁等待修完）；§8-A/B/C/D 是「开屏期降载」，本文件是**稳态根治**。

## 0. 总览

| # | 位置 | 现状优化 | 根治方案 | 风险 | 收益 | 优先级 |
|---|---|---|---|---|---|---|
| 1 | `Index.ets` `logText` | §8-A：日志页不可见不写 @State（开屏期重建 3→0） | 日志数据搬到**子组件局部**（@Observed `LogStore` + `@ObjectLink`） | 低 | 日志页**可见时**的整页重建 → 只重建日志组件 | **P1** |
| 2 | `PacketRouter`→插件→`Index` | §8-C：事件日志瘦身（负结果，净收益保留） | 插件→UI 回调**改传对象**（去掉 `notify(stringify)` + `JSON.parse`） | 中 | 每事件省 2 次 JSON 往返（MPRIS 稳态 ~1/s） | **P1** |
| 3 | `Index.ets` ticker | 已确认与开屏无关；暂停时不写 | 媒体面板抽组件，插值时钟写**面板局部 @State** | 中 | 面板打开时每秒整页重建 → 只重建面板 | **P1** |
| 4 | `applySettingsIfReady` | §8-B：延后 300ms | 确认可接受；可选：language 未变则不调 | 低 | 一次性成本，已移出首屏窗口 | P3（确认即可） |
| 5 | `DevicesTab.onAreaChange` | §8-D：150ms 去抖 + 同值不写 | **已基本根治** | — | 开屏仅 1 次触发（实测） | P3（确认即可） |

**共性根因**：#1/#3 同病——**页面级 `@State` 驱动整页重建**。根治手法一致：**把状态下沉到组件**（组件局部 `@State` 或 `@Observed` + `@ObjectLink` 共享对象），使状态变化只重建**用到它的组件子树**。

---

## 1.（#1）`@State logText` 整页重建

**当前状态**
- 触发链：`log()`（`Index.ets:2105`）攒 `logBuf` → 定时 `flushLog()`（`2131`）→ `this.logText = …`（**页面级 @State**）→ 整页重建；
- §8-A 已做到「日志页不可见不写 @State」（切回日志页时补一次 flush）⇒ 开屏 20s 内重建 **3→0**；
- **残留**：用户停在日志页时，每次 flush 仍整页重建（稳态高频日志下持续重建）。

**根治方案（推荐 A）**
- A：新增 `@Observed class LogStore { text: string = '' }`；`Index` 以**普通字段**持有 `logStore`（**不是 @State**），`LogsTab` 以 `@ObjectLink logStore` 接收；
  `flushLog()` 改成 `this.logStore.text = …` ⇒ **只有 LogsTab 重建**，页面其余部分不动；
- B（备选，改动更小）：`LogsTab` 内部持 `@State`，`Index` 通过回调「推」文本进去（`@Prop` 不行，@Prop 变化仍走父级 build）。

**风险/收益**：A 依赖 ArkTS `@Observed/@ObjectLink`（本项目已在用 `@Observed` 类：见 `model/` 下的数据类），风险低；收益 = 消除稳态整页重建。
**验证**：复用我已有的 `KDC logflush #n` 计数 + 新增「页面 build 次数」（用 `@Observed` 包装后两者应解耦）。

## 2.（#2）同帧 JSON 往返（**唯一尚未优化项**）

**当前链路（实测）**
```
native 事件（packet 已是 JSON 字符串）
  → Index.handleEvent
  → PacketRouter.onPacket → JSON.parse(frame)              ← 每帧 1 次 parse（必要，协议边界）
  → PluginHost.dispatch → 插件 onPacketReceived(body: Object)
  → 插件的 notify(kind, JSON.stringify(obj))               ← 【多余 stringify】
  → Index.onPluginEvent → JSON.parse(data)                  ← 【多余 parse】
发送侧：
  插件拼 body(Object) → PluginBase.send → JSON.stringify(frame)  ← 必要（上线格式）
  → native.parse                                              ← 必要
```
**多余的是插件→UI 的 `notify` 通道**（`PluginBase.ets:57`，`uiFn(deviceId, kind, data: string)`）。

**根治方案**：把 `notify(kind, data: string)` 改为**类型化事件对象**：
```ts
// plugins/PluginEvent.ets（新）
export interface PluginEvent {
  kind: string;                        // 'mpris.playerList' | 'mpris.playerUpdate' | 'battery' | 'runcommand.output' | ...
  mprisList?: string[];                // 按 kind 取用
  mprisSnap?: MprisSnapshot;
  batteryCharge?: number;
  batteryCharging?: boolean;
  text?: string;
  code?: number;
  ok?: boolean;
}
```
- `PluginBase.notify(ev: PluginEvent)` → `uiFn(deviceId, ev)`；
- `Index.onPluginEvent(deviceId, ev)` 直接读字段（**去掉 2 次 JSON 操作**）；
- 影响面：`PluginBase` + 使用 `notify` 的插件（`MprisPlugin`（2 处）、`BatteryPlugin`、`RunCommandPlugin`、`ClipboardPlugin`）+ `PluginHost.uiFn` 签名 + `Index.onPluginEvent`。
**风险**：中（跨插件契约变更，需一次改全；但**协议/线上格式不变**，只是进程内通道）。
**收益**：每次插件事件省「1×stringify + 1×parse」；MPRIS 稳态 ~1/s、开屏 20s 29~45 事件 ⇒ 稳态收益可观、且为后续「面板局部刷新」铺路。
**不做的事**：`PacketRouter.sendFrame` 的 `JSON.stringify` 与 native 的 parse 是**协议要求**，保留（这点与 AtomCode 的结论一致）。

## 3.（#3）媒体面板 1s ticker

**当前状态**：`startMprisTicker`（`Index.ets:855`）每秒 `this.mprisNowMs = Date.now()` ⇒ **页面级 @State** ⇒ 面板打开期间**每秒整页重建**（暂停时已不写，但播放时仍每秒一次）。
**根治方案**：把媒体面板抽成组件 `components/MediaPanel.ets`：
- 面板内 `@State nowMs`（ticker 只写它）⇒ 只有面板重建；
- 面板所需数据（`MprisSnapshot`/`playerList`）由 `Index` 以 `@Prop`/`@ObjectLink` 传入（配合 #2 的类型化事件，天然是对象）；
- 顺带把「进度条千分比」「只在 SliderChangeMode.Begin 才算拖动」等既有修正一起搬进组件，逻辑集中。
**风险**：中（面板是最大的一段 UI，抽取需保证既有行为不变；建议**纯搬迁**，不改逻辑）。
**收益**：面板是用户交互最密集处，收益最直观（每秒一次整页重建 → 面板局部）。
**验证**：面板打开时用 `KDC build #n` 计数对比（抽取前/后）。

## 4.（#4）启动期 `setColorMode` + `setLanguage`

**现状**：§8-B 已延后到首帧后 300ms，且 `settingsApplied` 幂等（只执行一次）。
**结论**：**一次全量重主题**的成本远小于 native 秒级阻塞，**可在延后方案上收尾**。
**可选微优化（P3）**：`applyLanguage` 前比对当前 language 是否变化（不变则不调）；`applyTheme` 同理加「同值不调」护栏。风险低、收益小。

## 5.（#5）`DevicesTab.onAreaChange`

**现状**：§8-D 已加 150ms 去抖 + 原有「>1vp 才写」同值保护；实测**开屏仅 1 次触发**（`KDC onAreaChange #1 w=642vp`）。
**结论**：**已基本根治**，无需进一步改动（保留去抖作为旋转/拖拽场景的保险）。

---

## 6. 建议实施顺序与批次

| 批次 | 内容 | 依赖 | 说明 |
|---|---|---|---|
| 批 1 | **#2 类型化插件事件**（去掉 notify 的 JSON 往返） | 无 | 为 #1/#3 的组件化铺路（组件间传对象） |
| 批 2 | **#3 媒体面板抽组件** + 局部 ticker | 批 1 | 用户体感最明显（面板打开时的每秒重建） |
| 批 3 | **#1 日志 store 化**（`@Observed` LogStore） | 无（可与批 2 并行） | 消除日志页可见时的整页重建 |
| 批 4 | #4/#5 收尾确认（同值护栏，或确认不做） | — | 低风险小改 |

每批**单独报文 + 真机量化**（沿用既有探针：`KDC logflush #n`、`KDC build #n`（待加）、面板打开窗口的 `THREAD_BLOCK`/慢发送）。

## 7. 与 native 侧的边界（避免重复劳动）

- native 侧的 `drain→json_dispatch` 长持锁问题**已修**（`105ddff`/`d3cd02c` 全零）；
- 本文件 5 项**全部是 ArkTS 进程内开销**，不涉及协议与 native 接口；
- AtomCode 的「异步化 / 双 API」评估结论为**当前不需要做**，本方案不依赖它。
