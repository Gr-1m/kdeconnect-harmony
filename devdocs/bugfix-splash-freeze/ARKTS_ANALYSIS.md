# ARKTS_ANALYSIS.md — 开屏卡顿：ArkTS 侧入口源头 / 触发位置 / 实测数据（DevEco Code）

> 2026-09-16。对应 CodeArts `MSG8FromCodeArts_TO_DEVECO` §4 的 7 个问题。**分析先写本文件，消息只用于通知**（按合作排查规则）。
> 设备：MatePad Mini（`5KPBB25901205531`）；版本：`06c0e9d` + omp b2c/b2c-2 + 我侧在途改动；口径：`aa force-stop` → `hilog -r` → `aa start` → 观察 20s。

## 0. 结论先说（TL;DR）

| 层 | 开屏等待的贡献 | 证据 |
|---|---|---|
| **native `sendPacket` 阻塞（连接后首批插件通告）** | **主因：1.27 ~ 5.79 秒/次** | 23:00:39.753 `JsSendPacket 5785ms`，随后 3 次 ≈1.27s（omp 的 `[KDC-JS-ENTRY]` 埋点） |
| ArkTS 侧日志驱动整页重建（#1） | **已很小：20s 内 3 次**（此前的 900ms 合并 + 动态窗生效） | 新增 `KDC logflush #n` 计数：23:00:39.765 / 43.724 / 44.643 |
| ArkTS 事件 JSON 往返（#2） | 小（开屏 20s 共 29 个事件），但**每事件都多一次 `JSON.stringify` + 一行 hilog** | `Index.ets:1156` |
| #4 主题/语言应用 | 一次全量重主题，发生在 **+1.23s**（首帧之后） | `KDC settings loaded` @23:00:33.866 |
| #3 ticker | **与开屏无关**（面板未打开，`startMprisTicker` 只在打开面板时调用） | `Index.ets:855-868` |
| #5 onAreaChange | 开屏期未见反复触发（设备页 rail 的 `onAreaChange` 需进一步计数，见 §7） | `DevicesTab.ets:845/861` |

**一句话**：开屏那几秒 **不是在等 ArkTS**，是在等 native 的同步 `sendPacket`（JS 线程被卡住，UI 自然「出来了但点不动」）。ArkTS 侧的问题是「放大器」，不是根因。

## 1. 启动时间线（实测，23:00:32.638 启动）

| 时刻 | 相对启动 | 事件 |
|---|---|---|
| 23:00:32.638 | +0 | `aa start` |
| 23:00:33.866 | **+1.23s** | `KDC settings loaded`（Preferences + TrustStore + 设置读取完成，`applySettingsIfReady` 在此触发） |
| 23:00:33.97（推算） | +1.33s | **进入 native `sendPacket`**（该调用于 39.753 结束、耗时 5785ms） |
| 23:00:39.753 | **+7.1s** | 第一次 `sendPacket` 返回 ⇒ **这段就是用户说的「开屏等待」** |
| 23:00:41.054 / 42.418 / 43.720 | +8.4 ~ +11.1s | 又 3 次 ≈1.27s 的 `sendPacket` |
| 23:00:39.765 / 43.724 / 44.643 | — | 3 次 `logflush`（各触发一次整页重建） |

⇒ 开屏期 JS 线程有 ~9.5s 中的约 9.5s 处于 native 调用内（4 次慢调用累计 ≈9.6s）。

## 2. Q1：`aboutToAppear` 同步块（`Index.ets:236-320`）耗时分解

代码顺序与实测：

| 步骤 | 代码位置 | 实测/估算 | 说明 |
|---|---|---|---|
| `preferences.getPreferences` + 读 deviceId/certPem/keyPem/deviceName | `~212-220` | 与下一项合计 **+1.23s** 到 settings loaded | 平台 Preferences，`await` 不阻塞 UI 线程 |
| `PayloadHistory.load`（我新增） | `~220` | 含在上面 | 一次 JSON.parse（≤100 条） |
| `TrustStore.load` | `230` | 含在上面 | 同上 |
| **`native.setTrustedCertificate` 循环（每个已配对设备）** | `237-245` | 毫秒级/台 | 实测「解冻后」无 `[KDC-JS-ENTRY]` 慢条目 ⇒ 不是瓶颈 |
| `applySettingsIfReady`（→ `applyTheme`/`applyLanguage`） | `259` / `384-391` | 一次全量重主题 | 见 §4 |
| `native.generateCert`（仅首启） | `263` | EC 生成，毫秒级 | 仅首次运行 |
| `native.init`（注册事件回调） | `283` | 无慢条目 | — |
| 插件注册 ×10 + `PluginHost` 构造 | `291-305` | 无慢条目 | 纯 JS 构造 |
| `PacketRouter` 构造 + `startNative`（含 `setCapabilities`/`start`/`probeNative`） | `306-320` | 无慢条目 | 实测 `setCapabilities`/`start` 均 <100ms |
| `registerNetworkListener` | `320` | 无慢条目 | — |

**结论**：同步块本身**没有**长任务；`+1.23s` 主要是前置的 `await`（Preferences/TrustStore 往返）。真正吃掉 1.3~7.1s 的是**随后由连接事件触发的 `sendPacket`**（在事件回调路径上，不在 `aboutToAppear` 里）。
⇒ 建议把「首批插件通告」从连接回调里**串行+延后**（见 §8），而不是去拆 `aboutToAppear`。

## 3. Q2 / #1：`logText` 整页重建（触发点 `Index.ets:2131 flushLog`）

- 触发链：`log()`（`2105`）→ 攒入 `logBuf` → 定时 `flushLog()`（`2131`）→ **`this.logText = …`**（`2135`）→ 页面级 `@State` 变化 ⇒ **整页重建**。
- 早期实现是「每条日志一次写」，现为**动态窗合并**（空闲 ≥900ms ⇒ 100ms 短窗，否则 900ms 节拍）。
- **实测（本次）**：首屏 20s 内 **只有 3 次 flush**（`KDC logflush #1/#2/#3`）。
⇒ **#1 已基本消解**；剩余优化空间见 §8-A（不可见时不写）。

## 4. Q3 / #4：`setColorMode` / `setLanguage`（`applySettingsIfReady` `384-391`）

- 触发点：`settingsLoaded = true`（`257`）+ `pageShown`（`onPageShow`）→ `applySettingsIfReady` ⇒ `applyTheme(themeMode,false)` + `applyLanguage(language,false)`。
- 实测发生在 **+1.23s**，即首帧之后 ⇒ 不是「挡住首帧」，但会带来**一次全量重主题**（字体/颜色/资源重新解析）。
- 代码已有 `settingsApplied` 幂等护栏 ⇒ 只执行一次。
⇒ 可优化为「首帧后延迟一拍（≥300ms）应用」，或把主题/语言合并成一次（见 §8-B）。**影响量级：一次重主题，远小于 native 的秒级阻塞。**

## 5. Q4 / #2：事件 JSON 往返（`Index.ets:1154-1156`）

```ts
private handleEvent(event: NetEvent): void {
  console.info('KDC net event: ' + JSON.stringify(event));   // ← 每个事件一次整对象序列化 + 一行 hilog
```
- native 侧事件本身是 JSON 字符串（`NetEvent.packet` 也是字符串）；ArkTS 再 `JSON.stringify(event)` **只为打日志** ⇒ 每事件多一次序列化 + 一次 hilog 写（设备上 hilog 是 syscall，代价明显）。
- 实测开屏 20s **29 个事件**（≈1.5/s）；稳态面板开着时 MPRIS 推包可达 1/s。
⇒ 属于「可立即修且零风险」：把日志改为**低频/裁剪**（见 §8-C）。

## 6. Q5 / #3：媒体 ticker

`startMprisTicker`（`855-868`）**只在打开媒体面板时调用**，开屏期不运行 ⇒ **与开屏卡顿无关**（它与「点媒体控制后卡」相关，那是另一条线，已做「暂停不写 @State」）。

## 7. Q6 / #5：`onAreaChange`

- 页面根：`Index.ets:2914 onAreaChange → onRootArea`（`421`）；设备页 rail：`DevicesTab.ets:845/861`（写 `@State paneWidthVp`）。
- 开屏期只应发生**一次**首屏布局；本次日志中未见与尺寸相关的异常重建。
⇒ 待办：给 `DevicesTab` 的 `onAreaChange` 加**去抖 + 同值不写**（与 #5 原建议一致），并计数验证（见 §8-D）。

## 8. 修复建议（分类：立即修 / 需数据 / 归 native）

**A（立即修，ArkTS 侧）**：`log()`/`flushLog()` 增加「日志页不可见时不写 `@State logText`，切回日志页时补一次」——零风险，把开屏期剩余 3 次整页重建降到 0。
**B（立即修，ArkTS 侧）**：`applySettingsIfReady` 延后到首帧后一拍（`setTimeout(…, 300)`）+ 主题与语言合并；并确认 `applyTheme` 内部是否重复调用系统 `setColorMode`。
**C（立即修，ArkTS 侧）**：`handleEvent` 的 `console.info('KDC net event: ' + JSON.stringify(event))` 改为**仅在前 N 秒 / 仅非 packetReceived 类型 / 仅截断前 200 字符**打点；packet 内容需要时改由 native 埋点输出。
**D（需数据）**：`DevicesTab.onAreaChange` 去抖 + 同值不写；先用计数确认开屏/旋转时的实际触发次数。
**E（归 native，不在我范围）**：连接后首批 `sendPacket` 的 1.3~7.1s 同步阻塞 —— 这是开屏等待的**根因**（omp 正在做 payload/连接 fd 的 EPOLLOUT 收口与无锁入队）。

## 9. ArkTS 侧入口清单（供后续排查检索，file:line）

| 用途 | 入口 |
|---|---|
| 启动总入口 | `Index.ets:194 aboutToAppear`（异步块 `196~`） |
| 启动同步段 | `Index.ets:236-320`（pin 回灌 / init / 插件注册 / router+startNative） |
| 事件总入口 | `Index.ets:1154 handleEvent`（`console.info` 在 `1156`） |
| 事件分发 | `Index.ets:1152-1370`（`deviceDiscovered` / `connected` / `packetReceived` / `disconnected` / `payloadTransfer` …） |
| 日志写入/刷新 | `Index.ets:2105 log` / `2131 flushLog` |
| 设置应用 | `Index.ets:384 applySettingsIfReady` → `applyTheme`/`applyLanguage` |
| 发现广播节流 | `Index.ets:551-562 registerNetworkListener` + `actionGate('net:triggerBroadcast',3000)` |
| 发送出口（全量） | `PacketRouter.ets:206 sendFrame`（含我的 `KDC pair OUT` 诊断） + `PluginBase.ets:51 send`（插件侧探针） |
| 面板 ticker | `Index.ets:855 startMprisTicker` / `863 stopMprisTicker` |
| 设备列表三态 | `Index.ets:2258-2307`（`connectedShown`/`discoveredShown`/`offlineKnownShown`）+ `2249 syncSelectedDevice` |

## 10. 追加复测（23:03 轮）：事件日志瘦身 = **负结果**（已排除 hilog 假设）

**改动**（`Index.ets:1154 handleEvent`）：去掉「每事件 `JSON.stringify(event)` + 整行 hilog」，常态只打
`KDC event <type> dev=<前8位> pktLen=<n>`（轻量摘要），完整 JSON 改为 `debugEventLog` 开关（默认关）。

**复测（同口径，启动 23:03:51.631，观察 20s）**：

| 指标 | 瘦身前 | **瘦身后** |
|---|---|---|
| 完整 `KDC net event` 行 | 29 行（每行数 KB） | **0 行** |
| 轻量 `KDC event` 行 | — | 44 行 |
| 慢 `JsSendPacket` | 5785 / 1273 / 1270 / 1282 ms | **5791 / 1296 / 2541 / 1243 / 3223 ms** |
| `THREAD_BLOCK_3S/6S` | 0 / 0 | 8 / 0 |

⇒ **结论：慢 `JsSendPacket` 与「每事件 hilog 同步写」无关**（数值几乎完全一致）。这条排除对 omp 的
NATIVE_ANALYSIS §2 有用：他们的候选 2（hilog 阻塞）**可以划掉**，剩下候选 1（调度延迟）/3（组合）——
建议按他们 §2.4 的 `wall vs cpu` 三段时间埋点一次性定性。

> 瘦身改动**仍然保留**：它把每事件的数 KB 拷贝 + hilog 写省掉（开屏期 29 次、稳态更长），属净收益，
> 只是**不是**开屏卡顿的原因。

## 11. 再追加（23:15 轮，用 omp 的新普查埋点）：**慢 `sendPacket` = 锁等待，1:1 吻合**

omp 的新埋点在 `NETLOOP` 行里加了两组数：`ev[disc/lost/conn/disc2/pkt/pair/err/xfer]`（事件计数）与 `conn[in/out/hup]`。同口径复跑后：

| 慢 `JsSendPacket`（= 我的 `KDC slow plugin send`） | 同窗口 `maxJsLockWait` | 同窗口 `maxHold` |
|---|---|---|
| **5776 ms**（battery） | **5775 ms** | 3205 ms |
| 1312 ms（battery） | 1285 ms | 1285 ms |
| 2560 ms（connectivity_report） | **2560 ms** | 3220 ms |
| 1237 ms（battery，另一对端） | **1238 ms** | 12 ms |

**⇒ 结论（对 ArkTS_ANALYSIS 的最终定性）**：
1. **慢 `sendPacket` 就是等 `connMutex_`**（`maxJsLockWait` 与慢调用逐条 ±1ms 对应），`txQueued=0/plainQueued=0` 排除积压，`maxHold` 1.2~3.2s 说明**持锁方是网络线程**；
2. **不是事件洪峰**：同窗口 `ev[…pkt=6 pair=4…]`，每 5s 仅个位数事件；我侧 25s 共 45 行轻量事件日志（≈1.8/s）；
3. **不是 ArkTS 单事件成本**：§8-C 的事件日志瘦身让慢发送数值**完全不变**（5785→5791，5776 复现）⇒ 已排除；
4. ⇒ 开屏「点不动」的**唯一剩余根因在 native 持锁段**；ArkTS 侧 §8-A/B 仍是净收益（重建 3→0），但**不是根因**。

> 已把该结论作为 `MSG11FromDevEco_TO_OMP` 发给 omp（附建议：持锁分段计时 + 把 `JsEntryTimer` 阈值临时降到 0 汇总）。

## 12. 终局定性（23:30 轮，用 omp `a57ca4c` 的带标签持锁埋点）：**凶手是 `onConnectionReadable` / `eventLoop` 在锁内长计算**

```
KDC-LOCKHOLD] label=sendPacket          hold=4582ms cpu=1ms        ← 纯等锁（cpu≪hold）
KDC-LOCKHOLD] label=onConnectionReadable hold=1304ms cpu=1298ms    ← 锁内真算（cpu≈hold）
KDC-LOCKHOLD] label=eventLoop            hold=3281ms cpu=3273ms    ← 锁内真算（cpu≈hold）
KDC-ENTRY-SPLIT] sendPacket wall=4582ms cpu=1ms lock=4582ms        ← 100% 等锁
```

- 慢发送与我的插件探针 **1:1**（4584/1290/3258/1316ms）；
- `sendPacket` 自身 `cpu=0~1ms`、`lock=wall` ⇒ **它一行活都没干，全在等锁**；
- 持锁方 `onConnectionReadable` / `eventLoop` 的 **`cpu ≈ hold` ⇒ 锁内长计算**（非锁序、非调度剥夺），单次 1.3~3.3s，集中在**建链突发期**（末窗口 `maxHold` 已回落 12ms）。

**⇒ 开屏「点不动」的完整因果链（终版）**：
`建链突发 → 网络线程在 connMutex_ 内做 1.3~3.3s 长计算 → JS 线程的 sendPacket 只能阻塞等待 → JS 线程（含 UI）冻结数秒 → 用户「界面出来了但点不动」`。
ArkTS 侧所有改动（§8-A/B/C）都只是净收益，**不能**消除该冻结；根治点在 native（把长计算移出锁，或先算后持锁）。

## 13. 专题：同一个凶手对**媒体控制卡片/面板卡顿**的影响（用户提问）

**结论：是的，同一个凶手是媒体控制「点击卡顿」的主导原因——但只解释「点一下要等几秒」，不解释「面板自己在转时的每秒重绘」。**

### 13.1 共同路径（为什么必然受影响）

媒体控制卡片/面板的**每一个动作**都走与 `battery`/`connectivity_report` **完全同一条发送入口**：

```
点卡片 → onDeviceAction('media') → mp.requestPlayerList() / mp.requestStatus()
面板内 → 播放/暂停/上一首/下一首 → control('PlayPause'|'Next'|'Previous')
       音量 → setVolume() ｜ 进度 → setPosition() ｜ 刷新 → requestPlayerList+requestStatus ｜ 切播放器 → selectPlayer+requestStatus
                   ↓（全部）
        PluginBase.send()  →  sendFn  →  native.sendPacket()  →  ⏳ connMutex_
```
⇒ 只要此刻网络线程正持锁（`eventLoop` / `onConnectionReadable` 锁内长计算 1.3~3.3s），**该动作就被卡同样久**。

### 13.2 实测证据

1. **修复前的日志里已多次抓到 mpris 的慢发送**（与 battery/connectivity 同批）：
   `KDC slow plugin send 1439ms / 3791ms / 2656ms / 1848ms -> kdeconnect.mpris.request`
2. **本轮面板打开窗口（23:3x）再次抓到持锁**：
   ```
   KDC-LOCKHOLD] label=onConnectionReadable hold=1313ms cpu=1309ms
   KDC-LOCKHOLD] label=eventLoop            hold=1304ms cpu=1301ms
   ```
   该窗口内**没有**打印慢 mpris 发送 ⇒ 那两次 `sendPacket` 恰好没撞上持锁窗口 ⇒ **表现为「时好时坏」**（这解释了用户观感的不稳定）。

### 13.3 什么时候最严重

稳态 `maxHold` 已回落（上轮末窗口 12ms）⇒ 媒体控制卡顿**集中在刚连上/刚重连/对端在重拨的那几秒**（建链突发期）。这与用户「点媒体控制就卡」的时机吻合。

### 13.4 不属于该凶手的部分（已由 ArkTS 侧修掉）

- **接收侧**：对端 ~1s 推 `kdeconnect.mpris` 状态走事件路径（native → `napi_threadsafe_function(nonblocking)` → JS 回调），**不占用锁** ⇒ 不受影响；
- **面板每秒重绘**：ticker 已改「暂停不写 @State」；滑块改千分比；弹层/面板去模糊；日志合并 ⇒ 这部分是**渲染层放大器**，已修；
- **面板关闭时**：不再写 `mprisItems` 镜像 ⇒ 后台推包不再驱动整页重绘。

### 13.5 因此

- **native 那把锁的锁内长计算一旦移出锁，媒体控制的点击会直接受益**，ArkTS 侧无需再改；
- 反之，只要锁内长计算还在，无论我怎么在 ArkTS 侧加切分/限频，**点媒体控制仍有概率被卡 1~3 秒**（因为那是同步发送的固有路径）。

## 14. 终局：子段拆分（omp `c05ba58`）把凶手钉到 **`drain → json_dispatch`**

```
KDC-PHASESPLIT] what=eventLoop:tick total=3259ms plain=0ms tls=0ms ident=0ms drain=3259ms json=0ms flush=0ms
KDC-DRAINSPLIT] tls_decrypt_recv=1ms json_dispatch=1301ms
KDC-DRAINSPLIT] tls_decrypt_recv=0ms json_dispatch=3259ms
```
- `plain`/`tls`/`ident` 全 0 ⇒ 与握手无关；**`drain` = total ⇒ 全部时间在 drain**；
- drain 内：`tls_decrypt_recv` 0~3ms，**`json_dispatch` 1296~3315ms** ⇒ **凶手是「把包派发给 JS」这一步**；
- 同一时刻 JS 线程正卡在 `sendPacket` 等同一把锁（`lock=wall=4558ms`）⇒ **形态上是「互相等」**：网络线程持锁派发、JS 线程等锁发不出包。

**本次还现场抓到媒体控制卡的同一个卡顿**：
```
KDC-LOCKHOLD] label=onConnectionWritable hold=1297ms cpu=1297ms
KDC slow plugin send 2599ms -> kdeconnect.mpris.request (d6c113f1…)
```
⇒ 与 §13 的结论一致：**媒体控制的点击卡顿 = 同一把锁**；`drain` 的派发移出锁后，媒体控制与开屏**同时受益**，ArkTS 侧无需再改。

## 15. 收口验证（omp `f872b99`：帧解析不再每帧新建 32MiB 缓冲）

omp 按 §14 的 `drain→json_dispatch` 定位读码，找到具体出处：`PacketIO::extractFrame` **每帧**新建 `out(32MiB+2)` 并零初始化，而它**全程持 `connMutex_`** ⇒ 收包突发期每帧一次 32MiB 分配 + memset；已改为线程局部复用缓冲。

**同口径前后对比（真机）**：

| 指标 | 修前 `c05ba58` | **修后 `f872b99`** |
|---|---|---|
| `drain` / `json_dispatch` | 1296~3315 ms | **384 ms（仅 1 次）** |
| 慢 `sendPacket` | 4558/1284/2599/1318 ms（5 条） | **384 ms（1 条）** |
| `maxJsLockWait` | 5775/2560/1238 ms | **0 ms** |
| `maxHold` | 3205/1285/3220 ms | **11 / 5 ms** |
| `THREAD_BLOCK_3S/6S` | 8/0 | **0/0** |
| 网络线程 CPU | 14.5s / 110 iters | **0.87~0.97s / 182~217 iters** |

**`[KDC-FRAMESPLIT] frames=1 bytes=2294 maxFrame=2294 total=384ms`** ⇒ 单帧 2.2KB 却曾耗 384ms ⇒ 印证「每帧固定开销」是主因。

**结论**：开屏卡顿与媒体控制卡顿的**同一根因已消除 ~90%**（秒级冻结 → 384ms 轻微掉帧）；`ARKTS_ANALYSIS §8-A/B/C` 与卡片忙碌态是 ArkTS 侧的净收益补充。残留 384ms 若要继续压，走 omp 的「解析移出锁」设计。






