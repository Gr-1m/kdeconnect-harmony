# 开屏卡顿等待 — Native 侧分析（C++/Rust 负责人 omp）

> 2026-09-16。按 CodeArts MSG5FromCodeArts_TO_OMP 的 5 项要求逐条作答。**先写自己的分析**（未读 ARKTS_ANALYSIS.md），
> 并交叉核对了 AtomCode 全量审查 `REVIEW_ATOMCODE.md` §4/§5 各条在**当前代码**中的状态（见 §6）。
> 结论先行：**开屏期的"点不动"是 ArkTS 主线程被同步块+重渲染占住；native 侧已无秒级阻塞，但仍有 3 项待收口**
> （慢 JsSendPacket 的成因尚未定性 / wake[conn] 3270/s / payload fd EPOLLOUT 常驻）。

## 0. 结论速览

| 问题 | 判断 | 依据 | 下一步 |
|---|---|---|---|
| 开屏"点不动" | **主因不在 native**：native 各出口均 <100ms | `[KDC-JS-ENTRY]` 真机数据只报 `JsSendPacket` 慢，其余 16 个出口干净；本轮又把锁等待归零 | 主因清单见 `ARKTS_ANALYSIS.md`（DevEco） |
| 慢 `JsSendPacket` 5 条（1.3~4.7s）且 `maxJsLockWait=0` | **成因未定性**，但**已被排除**：锁等待、队列积压、TX flush、epoll_ctl MOD、TLS 内部计算 | 见 §2 的逐段耗时上界分析 | **加"每次调用 CPU 时间"埋点**（§2.4）——wall≫CPU ⇒ 调度/日志阻塞；wall≈CPU ⇒ 函数内真活 |
| `wake[conn]` 3270/s | 未定性；**CPU 仅 ≈4% 核**，不影响冻结 | `events ≈ iters`（每次迭代 1 个连接事件） | 加「每 fd 事件掩码分布」埋点（§3.2） |
| `wake[payload]` 31,526/s | **已定性**：payload fd 常驻 EPOLLOUT（与连接侧同一 ET 陷阱）；**仅在有 payload 任务时出现** | 代码：`host_->epollAdd(fd, EPOLLIN|EPOLLOUT)`；真机计数 | 按需挂载（已试三次，见 §4.2 的失败机理）→ 需按 §4.3 的设计重做 |
| 待修的实际缺陷 | **P2-2 每事件 16KB 堆分配**（与 wake[conn] 同源，是 CPU/抖动放大器） | `REVIEW_ATOMCODE.md` §4 P2-2 + 当前代码仍在 | 立即修（§5，最便宜、收益明确） |

---

## 1. 启动期同步块：native 侧耗时分解

开屏同步块（`Index.aboutToAppear` 的 240–305 行）里的 native 调用共 6 类。**native 侧耗时（逐个出口）**：

| 调用 | 内部工作 | 量级 | 依据 |
|---|---|---|---|
| `setTrustedCertificate` ×N | 解析 PEM→DER（Rust `cert_util`）+ 写 `trustedCertPem_`（`trustMutex_`） | **<1 ms/次** | Rust 侧 base64/DER 是 O(n)，证书 ~1KB；无 I/O |
| `generateCert` | EC 自签生成（BearSSL keygen + ECDSA + ASN.1 + base64） | **~1–10 ms** | `cert_gen.cpp`；真机埋点未报慢（>100ms 才打） |
| `init` | 只存配置 + 建 `PayloadManager`（mkdir 逐级 + `purgeStaleSpool` 扫目录） | **~1–20 ms** | 目录项少时极快；spool 堆积时随条目数线性 |
| `setCapabilities` | 拷贝 caps + 重建 UDP identity JSON（Rust）+ `forceBroadcast_` + `wakeLoop()` | **<1 ms** | 本轮已把"JS 线程写 socket"移除 |
| `start` | `epoll_create1`/`eventfd` + **TCP bind 循环 1716→1764** + UDP socket/bind + `udp_->broadcast()`（getifaddrs + 每个网卡发一包）+ 起网络线程 | **10–100 ms** | 端口顺序 bind 是纯 syscall（微秒级/次）；`getifaddrs` + 多网卡 sendto 是主要项；**不阻塞等待** |
| 注册回调 | `napi_threadsafe_function` 创建 | **<1 ms** | — |

**结论**：native 六项合计 **实测/估算 10–130 ms 量级**，与真机 `[KDC-JS-ENTRY]` 只报 `JsSendPacket` 慢互相印证 ⇒ **同步块的"秒级"感觉主要来自 ArkTS 侧**
（Preferences/TrustStore 的 JSON 解析与逐设备循环、`setColorMode`+`setLanguage` 全量重主题、日志驱动的整页重建）——
即 `MSG174 §4` / `OVERVIEW.md` 的清单 #1/#4。

> 需要精确数字时：`JsEntryTimer` 只在 **>100ms** 时打日志。若 CodeArts 要精确分解，我可以加一个**启动期一次性统计**（每个出口打一次实际毫秒，前 3 秒内有效），一次性拿到真机数字。

## 2. 慢 `JsSendPacket`（1.3~4.7s）而 `maxJsLockWait = 0` —— 逐段上界分析

**先给函数内的逐段耗时上界**（`NetStack::sendPacket`，全部为常数级）：

| 段 | 工作 | 上界 |
|---|---|---|
| 取锁 | `lock_guard connMutex_` | **已测：本轮峰值 0 ms** |
| 遍历 `connections_` | 每连接一次 `deviceId()`（string compare）+ 状态判定 | 微秒（连接数 ≤ 数十） |
| `enqueueTx` | 帧拷贝 + 上限判定（`MAX_TX_QUEUE_BYTES`） | 微秒（帧 KB 级） |
| `[KDC-PAIR-OUT]` 判定 | `std::string::find`（仅 pair 帧才打日志） | 微秒 |
| `updateWriteInterestLocked` | **`epoll_ctl(MOD)` 1 次**（仅在写兴趣变化时） | 微秒（syscall） |
| `wakeLoop()` | `write(eventfd)` 1 次 | 微秒 |

⇒ **函数内不存在任何秒级操作**。因此 1.3~4.7s 只能来自：

1. **线程被剥夺运行权（调度延迟）** —— wall time 计入"没被调度"的时间。此时函数本身的 CPU 时间仍是微秒级；
2. **`LOGI`/hilog 同步写阻塞** —— 本函数在慢路径上会打 `[KDC-LOCKWAIT]`、`[KDC-PAIR-OUT]` 与 `JsEntryTimer` 的超时日志。
   OHOS 的 hilog 是**同步**接口，日志服务拥塞时可阻塞到秒级；且这会自我放大（越慢越打日志）；
3. 组合：先被 2 阻塞 → 判定为慢 → 再打日志 → 更慢。

**为什么不是"TX flush / epoll_ctl MOD 开销 / TLS 引擎内部"**（CodeArts §2 的三个候选）：
- TX flush 不在本函数内（`sendPacket` 只入队；写出由网络线程做）⇒ 不可能是本函数的耗时；
- `epoll_ctl(MOD)` 是单个 syscall（微秒），且**只在写兴趣变化**时调用；
- TLS 引擎计算全部在网络线程（`flushTx`/`doTlsHandshake`），`sendPacket` 不碰引擎。

### 2.4 建议的判定实验（决定性，成本极低）

在 `sendPacket` 内同时测 **wall** 与 **本线程 CPU 时间**：

```cpp
struct timespec c0, c1; clock_gettime(CLOCK_THREAD_CPUTIME_ID, &c0);
... 函数体 ...
clock_gettime(CLOCK_THREAD_CPUTIME_ID, &c1);
// wall = nowMs()-t0, cpu = (c1-c0)
if (wall > 50) LOGI("[KDC-ENTRY-SPLIT] sendPacket wall=%lldms cpu=%lldms lock=%lldms", wall, cpu, lockWait);
```
判读：**wall ≫ cpu ⇒ 调度/hilog 阻塞**（则修法是减少同步日志 + 检查系统日志压力）；
**wall ≈ cpu ⇒ 函数内真有活**（则按 §2 表逐段加微秒计时；我预期结论是"没有"）。

## 3. `wake[conn]` 3270/s 残留

**事实**：`events ≈ iters`（每次迭代恰好约 1 个连接事件），`wake[conn]=16,589 / 5.07s ≈ 3,270/s`，且该窗口 CPU 增量仅 **199ms/5s ≈ 4% 核**。
⇒ 单次事件成本 ≈ 12µs（`198,999µs / 16,589`），**已不是冻结来源**，但属于不该有的持续唤醒。

**已排除**（本轮改动后）：
- 连接 fd 常驻 EPOLLOUT —— 已改按需（`674d6a9`）；
- `epoll_ctl` 风暴 —— `updateWriteInterestLocked` **仅在状态变化时 MOD**；
- 500ms 端口探测 —— 只持 `dialMutex_`，且只在有未决拨号时跑；
- `tick` 重活 —— 已按 `LOOP_TICK_MS` 节流。

**剩余候选**（需数据区分）：
1. 某条连接**持续可读**：对端周期发小包（KDE 的 battery/connectivity 是分钟级，不足以解释 3270/s）；
2. 某条连接在 **`TlsHandshake` 状态反复触发可写** 且 `wantsWrite()` 真 ⇒ 每次 arm 变化都会 MOD（MOD 会**立即上报**）；
3. fd 复用 / 残留 epoll 条目导致的"永久就绪"；
4. `EPOLLERR|EPOLLHUP` 半死连接（当前分支会关连接，理论上自愈，需排除竞态）。

### 3.2 建议埋点（一次就能定性，成本极低）

`NETLOOP` 行加两项：
- **事件掩码分布**：`connIn=` / `connOut=` / `connHup=`（按 `events[i].events` 分类计数）；
- **窗口内 Top fd**：`topFd=<fd> count=<n> mask=0x<hex>`（每窗口重置）。

判读：`connOut` 占绝大多数 ⇒ 写兴趣在翻转（候选人 2）；`connIn` 占绝大多数 ⇒ 有持续可读流（候选人 1/3）；`connHup` ⇒ 半死连接（候选人 4）。

## 4. `wake[payload]` 31,526/s

### 4.1 定性（明确）

`payload/payload.cpp` 的注册点是 `host_->epollAdd(fd, EPOLLIN | EPOLLOUT)`（`PayloadHost::epollAdd` 恒定附加 `EPOLLET`）⇒
**payload fd 常驻 EPOLLOUT**，与连接侧（`674d6a9` 已修）是**同一个 ET 陷阱**：fd 可写但无待发内容时，ET 会持续上报。
**出现条件**：仅在存在活动 payload 任务时（对端发文件 / 本机发文件）——这与 DevEco 报的"桌面发文件到平板"窗口一致。

### 4.2 为什么我先回退了修复（重要教训）

我按连接侧同样的做法改（注册只 `EPOLLIN` + 需要时 `epollMod` 挂 `EPOLLOUT`），**三次迭代都失败**：
本机 harness 复现为「接收侧事件只有 `state=started done=0/262144`，10s 超时」⇒**载荷的 TLS 握手首飞发不出去**。

**机理**：payload 通道的**两个方向都要写握手记录**（server 先发 ServerHello、client 回 ClientHello/Certificate…）。
连接侧的 `wantsWrite()` 判据在我第一次实现时写成 `send && !pending.empty()` ⇒ 覆盖不到握手期；
第二次改成 `!pending.empty() || tls->wantsWrite()` 仍失败，因为**判据求值点**在 `pumpSendLocked` 内 ——
而握手推进发生在 `onReadable`/`onWritable`，**首飞之前根本没有一次会调用到我的刷新点** ⇒ EPOLLOUT 永远不挂 ⇒ 死锁在握手。

### 4.3 正确设计（下次按此提交）

1. **注册只挂 `EPOLLIN`**；
2. 在**所有推进 TLS 引擎的入口**（`onReadable`、`onWritable`、`onTick`、`startHandshakeLocked` 之后、`accept` 之后）统一刷新写兴趣
   ——用一个局部 RAII 守卫放在事件处理函数顶部，保证任何 return 路径都刷新；
3. 判据：`!job.pending.empty() || (job.tls && job.tls->wantsWrite())`
   （`TlsEngine::wantsWrite()` = `BR_SSL_SENDREC`，与控制连接同一语义；**不要**纳入 `SENDAPP`——它几乎常真，会把 EPOLLOUT 变回常驻）；
4. 仍需 **只在状态变化时** `epoll_ctl(MOD)`；
5. 验收：本机 `tests/run.sh` 全绿（`payloadE2eSendReceive`/`payloadSettleCrossFilesystem`/`payloadPeerCertMismatch` 必须通过）+ 真机 `wake[payload]` 归零。

## 5. 我建议的修复优先级（native 侧）

| 优先级 | 项 | 理由 | 需授权 |
|---|---|---|---|
| **P0** | **§2.4 加 CPU 时间埋点**（sendPacket 分段 + wall/cpu） | 让"1.3~4.7s 到底在等什么"一次定性；这是**用户唯一还能感知的卡顿** | 是（native 改动，1 处） |
| **P0** | **§4.3 payload fd 按需挂载**（按新设计重做） | 消除 3 万次/秒空转；可能与"文件停在接收中"同源 | 是 |
| **P1** | **§3.2 wake[conn] 掩码分布埋点** | 一次定位 3270/s 来源（当前 4% 核，不阻塞但应清零） | 是 |
| **P1** | **P2-2 每事件 16KB 堆分配**（改 per-connection 复用缓冲） | 3270 事件/秒 × 16KB ≈ 50MB/s 分配/释放，是 CPU 与抖动的放大器；改动小 | 是 |
| **P2** | 减少热路径同步日志（含 ArkTS 探针） | 若是 §2 的候选 2（hilog 阻塞），这是直接解法 | 需与 DevEco 协同 |

## 6. AtomCode 全量审查（`REVIEW_ATOMCODE.md`）逐条核验（**当前代码状态**）

| 条目 | 审查结论 | 我核对当前代码的结果 |
|---|---|---|
| **P1-1** `error`/`deviceLost` 从不派发 | UI 死分支 | **已修**（现在有 `dispatchError`/`dispatchConnectError`/`Disconnected` 多条派发路径） |
| **P1-2** 事件字段名 `message`/`code` 与契约不符 | 修 P1-1 即爆 | **已修**：`napi_events.cpp:64/66` 现为 `errorMessage`/`errorCode` ✅ |
| **P1-3** 超大帧写半截、污染流 | ≥16KB 必踩 | **已化解**：`sendPacket` 只入队 + `flushTx` 分片推进（队列保证整帧原子与完整）；`TlsEngine::write` 仍单次拷贝，但已在队列语义下安全 |
| **P1-4** EPOLLET 每次事件只读一次 | 数据滞留 | **已修**：`drainEncrypted` 排空 + tick 兜底 |
| **P1-5** 明文 identity 不按帧切分 | 偶发连不上 | **已修**：`readPlainFrame` 按 `\n` 精确切分 + 超时 |
| **P1-6** `sendPacket` 主线程阻塞 I/O | UI 卡死 | **已修**（P0-b：队列 + 单写者；本机探针 160 次调用最长 1ms） |
| **P1-7** 无定时器 ⇒ 三项不变量未实现 | 半开连接占用 fd | **已修**：`epoll_wait` 200ms + `plainExpired`/`handshakeExpired` + 未配对连接上限 + 同设备替换语义 |
| **P1-8** TLS client 不发客户端证书 | 严格 server 拒绝 | **已修**：`tls_engine.cpp:252` 已 `br_ssl_client_set_single_ec(&clientCtx_, &certChain_, …)` ✅（**这条我原以为是"文件停在接收中"的根因，核对后排除**） |
| **P2-1** 无 32MiB 帧上限 | OOM 风险 | **仍开**（低风险） |
| **P2-2** 每事件 16KB 堆分配 | 性能 | **仍开** ⇒ 见 §5（与 wake[conn] 同源） |
| **P2-3** `PacketIO::writeFrame/readFrame` 死代码 + 忙等 | 误用风险 | **仍开**（死代码可删） |
| **P2-4** `deviceId` 未做格式校验 | 低风险 | **仍开**（WP-2 派生存储键前必须做） |
| **P2-5** CMake 注释里 net/ 归属过期 | 误导后人 | **仍开**（顺手指明现归属 = native/omp） |
| **§5.1** per-connection TX 队列 | 最高优先 | **已落地** |
| **§5.2** 定时器基础设施 | 提到 WP-2 前 | **已落地** |
| **§5.4** 事件序列化单一化 | 字段漂移温床 | **仍开**（`napi_exports.cpp` 里未注册的旧事件桥仍在，可删） |

## 7. 我能立即动手的（等 CodeArts 授权即可提交）

1. **§2.4 CPU 时间埋点** + **§3.2 掩码分布埋点**（一次改完，一次真机复跑即可给全部结论）；
2. **§4.3 payload 写兴趣重做**（按上文设计）；
3. **P2-2**（复用缓冲）+ **P2-5**（归属注释）+ **§5.4/§2-3 死代码清理**。

—— omp（后端 C++/Rust 负责人），2026-09-16

## 8. 按功能点排查（后端 C++/Rust 视角）：每个功能点的可疑点与现状

| 功能点 | 关键 native 路径 | 可疑点 / 现状 |
|---|---|---|
| **发现设备**（UDP） | `onUdpReadable` → `DeviceDiscovered`/`DeviceLost` | 广播节奏（5s×5→60s）与 `forceBroadcast_`；`lastSeenMs_` 清理；**注意**：无端口拨号会走 `findListeningTcpPort`（并行 48 连接 + 单次 500ms poll）⇒ **网络线程被占 ≤500ms**（不阻塞 JS，但会推迟握手/事件派发）⇒ 若用户感觉"点连接后要等"，第一嫌疑在此 |
| **连接 / 配对** | `connectToPeer` → `onConnectionWritable`（明文队列）→ TLS → `dispatchFrames` | 本轮已修「0.7s 自断链」（设备级限流 vs KDE 链路替换语义）；**残疑**：配对 ack 的发送延迟 = §2 的慢 `sendPacket` |
| **已连接列表 / 功能卡片** | 事件 → ArkTS | native 只负责 `Connected`/`Disconnected`/`Paired` 的及时与去重（链路替换时已抑制误报） |
| **文件传输（接收）** | `startReceive` → `onReadable` → `drainReceiveLocked` → `finishJobLocked("finished")` | 完成判据 `done >= total` 正确；**待查**：① payload fd 常驻 EPOLLOUT（§4）② 是否少收字节（`[KDC-PAYLOAD]` 埋点已入库，等一次真机数据） |
| **文件传输（发送）** | `startSend` → 监听 → accept → `pumpSendLocked` | 同 §4；另：大文件走 `pending` 缓冲（`PAYLOAD_CHUNK=16KB`）⇒ 与 §4.3 的写兴趣刷新点强相关 |
| **保存文件（keepPayload）** | `PayloadManager::settle` | 已修（锁外 I/O，不再阻塞 JS 线程与 payload 引擎）；**未做**：把落盘整体移出 JS 线程（需 d.ts + ArkTS 契约变更，已与 DevEco 约定载荷 `transferId/ok/finalPath/errorCode`） |
| **媒体控制（MPRIS）** | `sendPacket`（请求） + payload（专辑封面） | native 侧只剩 §2 的慢 `sendPacket`；其余重活在 ArkTS（同帧 4~6 次 JSON 往返、1s ticker） |
| **剪贴板 / 查找设备 / 远程输入** | `sendPacket` 直发 | 已无阻塞面（队列化）；风险同 §2 |
| **开机首批发包**（battery/connectivity/mpris） | 插件 `send()` → `native.sendPacket` | **正是 DevEco 观测到 5 条慢调用的场景** ⇒ §2 是这块的收口点 |

> 排查建议的执行顺序（按"用户可感知程度"）：§2（慢 sendPacket，直接影响开屏与所有点按）→ §4（payload 写兴趣，影响文件/封面）
> → P2-2（分配抖动）→ §3（wake[conn]，当前仅 4% 核，最后收）。

---

## 9. 【关键新证据】用户真机对照实验：**关 WiFi 进入 APP 就可点击**

用户提供的现象（2026-09-16 真机）：

1. 开屏后**设备页没有卡片**；
2. 此时**点击无任何效果**；
3. 等到「已连接/已配对设备」加载出来之后，**导航与卡片都可点击**，进入正常状态；
4. **关闭 WiFi 进入 APP → 可以点击**。

### 9.1 这条实验推翻了什么、坐实了什么

- **推翻**：「开屏同步块（`aboutToAppear` 240–305）是主因」。
  WiFi 关时**同一段同步块照样执行**，但 APP 可点击 ⇒ **同步块不是冻结来源**（§1 的结论需据此修正：
  native 那 6 个出口仍是 ms 级，但"同步块吃主线程"不足以解释现象）。
- **坐实**：冻结是**网络事件驱动**的 —— 开 WiFi ⇒ 发现/拨入/连接/插件包一连串事件涌入 ⇒
  JS 线程被 `tsfn` 事件回调占满 ⇒ **主线程无暇处理输入**（点击排队）⇒ 事件洪峰过去后才恢复。
  这与"等已连接已配对设备加载出来就恢复"完全一致：**恢复点 = 事件洪峰结束点**。
- 附带解释「设备页一开始没有卡片」：**native 没有 `devices()` 这类查询出口**（d.ts 19 个出口里没有），
  设备列表是**纯事件驱动**在 ArkTS 侧累积的 ⇒ 事件没处理完就没有卡片；而"已配对"列表还额外依赖
  ArkTS 侧 TrustStore 读取，同样被占满的主线程拖慢。

### 9.2 因此需要一次「二选一」判定（已埋点，等一次真机复跑）

| 分支 | 判据 | 归口 |
|---|---|---|
| **A. ArkTS 单事件成本过高** | 开屏期窗口内事件只有**几十条**，但 JS 线程仍被占满数秒 ⇒ 每条事件的处理（整页重建 / 4~6 次 JSON 往返）是瓶颈 | **ArkTS（DevEco）**：`MSG174 §4` / `OVERVIEW.md` 的 #1/#2/#4 是正解 |
| **B. native 过度派发** | 窗口内事件是**数千条** ⇒ 每次重拨/每次广播都在重复告知 | **native（我）**：已加入 `DeviceDiscovered` 2s 事件级去重（见下），必要时再合并其他冗余事件 |

**已落地的埋点（本次改动）**：
- `dispatchEvent` 按 `EventType` 普查（8 类：`disc/lost/conn/disc2/pkt/pair/err/xfer`），随 NETLOOP 行输出，`dt=` 给出窗口毫秒 ⇒ 可直接算"每秒事件数"；
- **`DeviceDiscovered` 事件级去重**（同设备 2s 内不再派发）：UDP 广播（`onUdpReadable`）与对端拨入
  （`handlePlainIdentity`）会**成对**宣告同一设备，开屏期直接放大 ArkTS 处理量。
  （保留语义：设备**首次**出现仍会立刻告知——这正是此前修「发现页空」的关键。）

### 9.3 与分析文件其余部分的关系

- §2（慢 `JsSendPacket` 1.3~4.7s）与本节**同源**：都指向"JS 线程在开屏期被网络相关处理占住"；
  §2.4 的 wall/cpu 埋点将判定它到底是**被调度剥夺**（⇒ 与本节 A 分支一致）还是函数内真活。
- §4（payload fd 常驻 EPOLLOUT）是**同一类问题的另一形态**：网络事件空转 ⇒ 若不解决，即便 A 分支修好，
  CPU 与唤醒仍会被白白消耗（只是当前占 4% 核，不是冻结主因）。
- `OVERVIEW.md` 的"已知证据"表建议追加两行：**关 WiFi 对照实验**、**事件普查埋点**。

> 排查执行顺序（更新）：**① 真机复跑拿事件普查数字（决定 A/B）→ ② §2.4 埋点定性慢 sendPacket → ③ §4.3 payload 写兴趣 →
> ④ P2-2 分配复用 → ⑤ §3 wake[conn]**。

---

## 10. 与另两份分析的交叉核对（DevEco `ARKTS_ANALYSIS.md` / AtomCode `MSG4FromAtomcode_TO_ALL`）

### 10.1 我需要更正的两处（对自己前面的结论）

1. **§1/§9 的「同步块」判断要收窄**：DevEco 的真机时间线证明，`aboutToAppear`(236–320) **没有长任务**
   （`setTrustedCertificate`/`generateCert`/`init`/`setCapabilities`/`start`/注册回调 在 `[KDC-JS-ENTRY]` 里**均无慢条目**），
   `+1.23s` 主要是前置的 `await`（Preferences/TrustStore）。**结论修正为**：native 出口确实都在 ms 级（与我 §1 一致），
   但"开屏等 5~7 秒"是**随后由连接事件触发的 `sendPacket`**（在事件回调路径上），不在同步块里。
2. **§2 的候选 2（hilog 同步写阻塞）可以被划掉**：DevEco §10 做了**负结果实验**——把每事件
   `JSON.stringify(event)` + 整行 hilog 去掉（29 行完整 JSON → 0 行），慢 `JsSendPacket` 数值**几乎不变**
   （5785/1273/1270/1282ms → 5791/1296/2541/1243/3223ms）。
   ⇒ 因此 §2 只剩：**候选 1（线程被剥夺运行权/调度延迟）** 与组合项。**§2.4 的 wall vs cpu 埋点成为唯一的决定性实验。**

### 10.2 DevEco 侧关键实测（我据此定优先级）

| 事实 | 数值 | 含义 |
|---|---|---|
| 开屏 20s 内慢 `JsSendPacket` | 5785 / 1273 / 1270 / 1282 ms（另一轮 5 条） | **JS 线程约 9.5s/20s 处于 native 调用内** ⇒ 用户"点不动"的来源 |
| `logText` 整页重建 | **仅 3 次**（900ms 合并 + 动态窗生效） | 我 §9.2 的 A 分支（ArkTS 单事件成本）**被削弱**：日志放大已基本消解 |
| 开屏事件总数 | **29 个/20s（≈1.5/s）** | ⇒ **B 分支（native 过度派发）也不成立**：几十条事件不可能卡住主线程数秒 |
| ArkTS 主题/语言 | +1.23s 一次全量重主题 | 放大器，非根因 |

⇒ **A/B 二选一被排除，剩下唯一的解释**：**单次 `sendPacket` 的 wall 时间真的是秒级，而函数体内没有任何秒级操作**
⇒ 只能"这段时间线程没在跑"。§2.4 埋点（本线程 CPU 时间）一跑即知：**wall≫cpu = 调度问题**（要继续找谁在占 CPU / 谁在让 JS 线程入睡）；
**wall≈cpu = 函数内真有活**（则按 §2 表逐段打微秒计时，我预期会推翻"无秒级操作"的结论）。

### 10.3 AtomCode 全量功能点排查（7 域）—— 域5 与我的结论互证，且比我更准

- **域5 P2-2**：他把"永远接收中"的机制链**补全得比我准**：
  `epollAdd` 强制 `|EPOLLET`（`net_stack.cpp:1414`）→ 接收 fd 注册 `EPOLLIN|EPOLLOUT`（`payload.cpp:376`）
  → 接收任务多数时间无可写内容 → **ET 下边沿耗尽后读事件滞留** ⇒ `drainReceiveLocked` 不再被驱动 ⇒ **终态永不派发**。
  （我 §4.1 只说到"空转烧 CPU"，**他指出的"读事件滞留 ⇒ FSM 停摆"是更贴近症状的机理**。）
- **域5 P2-3 补充的关键点**：`onTick` 的 30s 超时兜底**在握手完成后被清零**（`payload.cpp:535 job.deadlineMs = 0`）
  ⇒ **传输中没有任何超时** ⇒ 一旦停摆就"接收中"到进程结束。⇒ 我的 §4.3 设计必须**加上传输级无进展超时**
  （基于 `lastProgressMs`：N 秒无字节进展 ⇒ `failJobLocked`），这也顺带解决 P2-3（accept 前对端断开后无推进路径）。
- **域2 P2-1**：**TLS 层未校验「证书 CN == deviceId」**（`peerCommonName()` 无消费方）——协议硬约束（AGENTS.md: deviceId = 证书 CN）。
  对我而言这是一条**可立即修**的 native 缺陷（在 identity/配对处校验，不一致即断链），且**顺带**覆盖 AtomCode 的 P3-6
  （TrustStore 旧条目 `certPem:''` 时钉扎被静默跳过）。
- 其余（域1/3/4/6/7 与 P3 系列）与我无冲突；其中 P3-8（`epollWriteArmed_` 注释）我已在 `8417d29` 修完。

### 10.4 更新后的执行顺序（我的范围）

1. **§2.4 `sendPacket` wall/cpu/lock 三段时间埋点** ← 唯一能定性"开屏等待到底在等什么"的实验（**最高优先**）；
2. **§4.3 payload 写兴趣按新设计 + 传输级无进展超时**（与 AtomCode 域5 P2-2/P2-3 合并收口）；
3. **域2 P2-1 CN==deviceId 校验**（协议硬约束，顺带 P3-6）；
4. P2-2 分配复用 → §3 wake[conn] 掩码分布。

—— omp，2026-09-16（§10 追加）

---

## 11. 【修正 §2】真机新证据：慢 `JsSendPacket` **就是** `connMutex_` 锁等待（我此前的排除是错的）

DevEco MSG11（用本轮埋点，同一设备同口径）给出**1:1 吻合**的对照：

| 慢 `JsSendPacket` | 同窗口 `maxJsLockWait` | 同窗口 `maxHold` |
|---|---|---|
| 5776 ms | **5775 ms** | 3205 ms |
| 1312 ms | 1285 ms | 1285 ms |
| 2560 ms | **2560 ms** | 3220 ms |
| 1237 ms | **1238 ms** | 12 ms |

- **每 5s 事件只有个位数**（`ev[disc=2 pkt=6 pair=4]`）⇒ 既不是 A（ArkTS 单事件成本）也不是 B（native 过度派发）；
- `txQueued=0 plainQueued=0` ⇒ 不是队列积压；
- 慢调用与 `maxJsLockWait` **逐条 ±1ms 对齐** ⇒ **JS 线程在等 `connMutex_`**；
- `maxHold` 1.2~3.2s ⇒ **持锁方（网络线程）单次持锁达秒级**。

### 11.1 修正我 §2 的结论

§2 我据"函数内无秒级操作 + 早先一轮 `maxJsLockWait=0`"排除了锁等待 —— **该排除作废**：
`maxJsLockWait` 是**每窗口重置**的极值，早先那几轮窗口恰好没有慢调用发生，属**观测窗口错配**，不是"不存在锁等待"。
**现行结论**：慢 `sendPacket` = 等 `connMutex_` = 网络线程持锁秒级。§2 的 wall/cpu 埋点仍有价值（区分"等锁" vs "被调度剥夺"），
但真正的定位手段是**持锁分段计时**。

### 11.2 已排除的可能（附证据）

- **阻塞套接字**：`TcpServer::accept` 用 `accept4(..., SOCK_NONBLOCK|SOCK_CLOEXEC)`（`tcp_server.cpp:58`）、
  拨号侧 `socket(AF_INET, SOCK_STREAM|SOCK_NONBLOCK|SOCK_CLOEXEC)`（`net_stack.cpp:306`）⇒ **套接字全为非阻塞**
  ⇒ 网络线程**不可能**在锁内阻塞于 send/recv。（我一度怀疑"accept 不继承 O_NONBLOCK"导致入向连接阻塞，**已证伪**。）
- 队列积压、事件洪峰、hilog 阻塞（DevEco 负结果）：均排除。

### 11.3 剩下的两类可能 + 已落地的判定手段

既然 I/O 非阻塞，秒级持锁只能是：
1. **锁内长 CPU 工作**（如超大帧 JSON 解析、证书/握手密码学、批量连接遍历）；
2. **持锁时又去等另一把锁**（锁序 `connMutex_ → mu_/trustMutex_/capsMutex_/callbackMutex_`），
   若另一把锁被长持有（例如 payload `mu_` 曾被 `settle` 的文件拷贝长持有——**已修**），
   则网络线程在该锁内被堵 ⇒ JS 线程等 `connMutex_` 数秒。

**已落地（commit 见下）**：带标签的持锁分段计时，覆盖 **17 个 `connMutex_` 锁点 + 10 个 payload `mu_` 锁点**：
- 超 100ms 即打 `[KDC-LOCKHOLD] label=<调用点> hold=?ms cpu=?ms`；
- `cpu` 字段用于区分"真在算"（cpu≈hold）与"在等别的锁/被调度剥夺"（cpu≪hold）——**这是锁序问题的判定依据**。

⇒ **下一次真机复跑即可指名凶手**（哪个 label、cpu 占比多少）。若 label 落在 payload 调用链上且 `cpu≪hold` ⇒ 锁序问题（按 §11.3-2 收口）；
若 `cpu≈hold` ⇒ 锁内长计算（按 label 定位那段循环/解析）。
