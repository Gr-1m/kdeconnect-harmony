# WP-1 设计：payload 二进制传输（v0.2）

> 2026-09-12，zcode 起草 v0.1；**v0.2 由 AtomCode 更新**（用户指定其在 zcode 暂停期间临时接任 C++ native）。
> 评审人：DevEco Code（契约/ArkTS 侧）、CodeArts（测试指导）。
> §3 的 d.ts v2 定稿进 `types/libkdeconnect_napi/Index.d.ts`（唯一契约源）后，由 native 按 §4 实现 `payload/` 模块。
> 协议事实已对照 `kdeconnect-kde/core/backends/lan/`（landevicelink.cpp / compositeuploadjob.cpp / uploadjob.cpp）与 `kdeconnect-meta/schemas/kdeconnect.json` 核实。

## 0. v0.2 变更：WP-1a（读写路径修复）已落地

`REVIEW_ATOMCODE.md` §3.2 / §4 / §8 指出的 WP-1 前置缺陷已由 AtomCode 修复，**验证通过**（NDK clang `-Wall -fsyntax-only` 零 error 零 warning；scratch 副本 `hvigorw assembleHap` **BUILD SUCCESSFUL 34 tasks**，双 ABI HAP 内含新代码）。

| # | 交付 | 落点 | 对应缺陷 |
|---|---|---|---|
| 1 | **统一接收缓冲 + 按 `\n` 切帧**：`extractFrame()` 纯函数（超限帧丢弃、半包等待），明文与 TLS 两路共用 | `net/packet_io.{h,cpp}`、`net/net_stack.cpp: dispatchFrames` | REVIEW §3.2 B3 / §4 P1-5 |
| 2 | **排空读**：`fillTlsRx()` 反复读到 EAGAIN；`rxBuf_` 上限 32 MiB | `net/tcp_connection.{h,cpp}` | §4 P1-4 / P2-1 |
| 3 | **事件派发补齐**：`error` 事件（含 connect 失败 / TLS 握手失败 / 读写失败）；`deviceLost` 由发现超时（60s）派发；`packetReceived` **一事件一帧** | `net/net_stack.cpp` | §4 P1-1 |
| 4 | **`error` 字段名修正** 为 `errorCode`/`errorMessage`（与 d.ts 逐字一致）；删除 `napi_exports.cpp` 中从未注册的第二套事件桥 | `napi/napi_events.cpp`、`net/napi_exports.cpp` | §4 P1-2 |
| 5 | **单写者 TX 队列**：`enqueueTx`（任意线程只入队）+ `flushTx`（仅网络线程），EPOLLOUT/tick 驱动续传；`sendPacket` 不再阻塞 JS 线程，大帧不再被截断 | `net/tcp_connection.{h,cpp}`、`net/net_stack.cpp: sendPacket/onConnectionWritable` | §4 P1-3 / P1-6 / §5.1 |
| 6 | **最小定时器基建**：`epoll_wait(…, 200ms)` + tick 内检查 —— accept 后 1s 无 identity 断连、同设备 500ms 去抖、`MAX_UNPAIRED_CONNECTIONS` 真正生效（此前仅作 backlog） | `net/net_stack.cpp: eventLoop`、`net/tcp_connection.cpp` | §4 P1-7 / §2 P2-1 |
| 7 | **TLS client 装载客户端证书**（`br_ssl_client_set_single_ec`）+ **对端 EE 证书捕获**（`peerLeafCertDer()` / `peerCommonName()`） | `net/tls_engine.{h,cpp}` | §8 D1 / D2 / §4 P1-8 |
| 8 | **payload 元数据解析**：`parsePacket(..., payloadSize, payloadTransferPort)`；`NetEvent` 增 `payloadSize`/`payloadTransferPort` | `net/packet_io.{h,cpp}`、`net/net_types.h` | §8 D3 |
| 9 | **常量集中**：`MAX_PACKET_SIZE`(32 MiB)、`PAYLOAD_PORT_MIN`(1739)、`DISCOVERY_TIMEOUT_MS`、`MAX_TX_QUEUE_BYTES` | `net/net_types.h` | §5.3 |
| 10 | **deviceId 格式校验** `^[a-zA-Z0-9_-]{32,38}$`（`parseIdentity` 出口收口） | `net/packet_io.cpp` | §4 P2-4 |
| 11 | 清理死代码 `PacketIO::readFrame/writeFrame`；`AGENTS.md` 三项不变量不再只是声明 | 同上 | §4 P2-3 |

**帧契约（重要，ArkTS 侧无需改动）**：native 现在**保证「一个 `packetReceived` 事件 = 一个完整帧」**，且 `ev.packet` **保留帧尾 `\n`** —— 与 `PacketRouter.onPacket` 现有「按 `\n` 切分 + 缓存半帧」逻辑完全兼容（实测：单帧 `A\n` → 正常处理；两帧同批 → 各自独立成事件）。ArkTS 侧**不需要**为本次改动做任何适配。

**仍未做（属 WP-1b，见 §3/§4）**：`payloadSize`/`payloadTransferPort` 尚未映射进 JS 事件对象（d.ts v2 定稿后随契约一并暴露）；payload 通道（监听/连接/TLS 角色注入/spool 落盘/进度事件）全部未实现。

---

## 1. 协议事实（对桌面 KDE 互操作的关键）

1. 带载荷的 packet 在控制连接（TLS、换行分帧 JSON）上发送，多出两个字段：
   - `payloadSize`：字节数（schema 允许 -1 表示无限流，**不使用**，恒 ≥0）；
   - `payloadTransferInfo`：`{"port": <监听端口>}`。
2. **方向**：packet 发送方在本地**监听** 1739–1764（KDE `MIN_PORT=1739, MAX_PORT=1764`，逐个试到成功）；packet 接收方**主动连接**监听方。
3. **payload 通道也是 TLS**：监听方 = TLS server，连接方 = TLS client（与控制连接不同——控制连接是 TCP 发起方 = TLS server，payload 通道以"谁监听"定角色）。双方使用与控制连接相同的证书/身份。
4. 发送方等待接收方连接的超时 **30000 ms**（KDE 同值）；流式分块 4096 B（KDE 值；分块大小不影响互操作，我方用 16 KiB）。
5. `payloadSize == 0`（空文件）：KDE 发送侧直接完成不传数据；我方约定**不发 `payloadTransferInfo`**，接收侧见 `payloadSize==0` 直接视为完成，不发起连接（与 KDE 接收侧行为兼容）。
6. 取消：任一侧关闭 socket 即中止；接收方读到 EOF 但不足 `payloadSize` → 失败。
7. 接收方连接目标地址 = **控制连接的对端地址**（不是发现时的广播地址），native 侧已知。

## 2. 我方设计决策（与 KDE 的差异点及理由）

| 决策 | 理由 |
|---|---|
| **接收侧自动落盘到 spool 暂存目录**，完成后由 ArkTS 决定去留 | KDE 发送方 30s 超时，若等 ArkTS 弹窗确认再连接，超时风险大；自动收满后 `keepPayload`（move，同分区原子）/`discardPayload`（删）零超时风险。安全性靠：payload 只可能来自已过 TLS 的控制连接对端，且 §5 校验对端证书 CN |
| 分块 16 KiB（对 KDE 透明） | 减少系统调用与 TLS record 开销；TCP 流语义无互操作影响 |
| 进度事件节流：≥100 ms 或每 10% | 防 tsfn 洪泛卡 UI |
| `transferId` = 十进制自增序号（字符串） | 简单、唯一、可关联；跨端不传输此 id（仅本地语义） |
| 监听器按次创建，传输结束即关 | 与 KDE CompositeUploadJob 一致，避免常驻端口占用 |

## 3. d.ts v2 契约（DevEco Code 定稿 → Index.d.ts）

```typescript
// NetConfig 增加（可缺省，缺省时收到 payload 会产生 error 事件）：
spoolDir?: string;   // payload 暂存目录，建议 context.cacheDir + '/payloads'

// 新增方法：
// 发送：packetJson 由 ArkTS 组好 type/body（不含 payloadSize/payloadTransferInfo，native 注入）。
// filePath 为沙箱内绝对路径。true=已受理（后续经 payloadTransfer 事件汇报）。
export const sendPayload: (deviceId: string, packetJson: string, filePath: string) => boolean;

// 接收完成后认领：把 spool 文件 move 到 destPath（同分区 rename）。true=成功。
export const keepPayload: (transferId: string, destPath: string) => boolean;

// 接收完成后丢弃：删除 spool 文件。
export const discardPayload: (transferId: string) => void;

// 取消进行中的传输（双向皆可；send 侧会关监听与 socket）。
export const cancelPayload: (transferId: string) => void;
```

`NetEvent` 扩展（同一次改动内更新字面量联合类型）：

```typescript
export interface NetEventBase {
  type:
    | "deviceDiscovered" | "deviceLost" | "connected" | "disconnected"
    | "packetReceived" | "pairingRequest" | "error"
    | "payloadTransfer";                          // 新增
  ...
  // packetReceived 且包带 payload 时附加：
  transferId?: string;
  // type === "payloadTransfer" 时：
  direction?: "send" | "receive";
  state?: "started" | "progress" | "finished" | "failed" | "cancelled";
  bytesTransferred?: number;
  totalBytes?: number;
  fileName?: string;   // 取自 packet body.filename
  filePath?: string;   // receive: spool 临时路径（finished 时有效）；send: 回显源路径
  errorCode?: number;
  errorMessage?: string;
}
```

事件语义：
- **send**：`started`（监听成功、packet 已发出）→ `progress`… → `finished` / `failed` / `cancelled`；对端断开未传完 = `failed`（errorCode=ECONNRESET 语义）。
- **receive**：packet 到达即 `started`（此时 `fileName`/`totalBytes` 可用）→ `progress`… → `finished`（`filePath` = spool 路径，**等 ArkTS `keepPayload`/`discardPayload` 处置**，否则文件留在 spool）；`failed`（不足量 EOF、TLS 失败、无 spoolDir 等）。
- ArkTS 侧注意：`packetReceived` 事件里 packet JSON 本身就含 `payloadSize`/`payloadTransferInfo`，UI 可用于"正在接收"预览，但文件处置只能等 `payloadTransfer finished`。

## 4. C++ 实现设计（`entry/src/main/cpp/payload/`）

> **v0.2 补充（AtomCode）**：§3.2 B1/D1/D2 的前提已在 WP-1a 打好，实现 payload 时直接用：
> - **TLS 角色必须显式传入**，不能沿用 `TcpConnection::tlsRole()`（它按 `isIncoming_` 推导：主连接的正确性来自「TCP 发起方 = TLS server」，而 payload 通道恰好相反 —— 监听方才是 server）。建议 `TlsEngine` 构造处加显式 role 参数，payload 通道按「本侧是否监听」决定；
> - **客户端证书已可用**：`TlsEngine::init()` 的 client 分支现在会装入本机 `certChain_`（`br_ssl_client_set_single_ec`），因此本侧作为 payload 拉取方（TLS client）也能满足对端 `VerifyPeer`；
> - **对端证书已可读**：`TlsEngine::peerLeafCertDer()` / `peerCommonName()` 已实现（捕获 vtable），§5 的「CN == deviceId」校验直接用这两个接口；
> - **帧收发已可靠**：`PacketIO::extractFrame()`（按 `\n` 切帧、半包等待、超限丢弃）+ `TcpConnection::enqueueTx/flushTx`（单写者队列、大帧不截断、不阻塞 JS 线程）；payload 通道的字节流复制建议沿用同一 `flushTx`/`fillTlsRx` 思路，避免另起写路径。
> - **payload 字段已解析**：`PacketIO::parsePacket(json, type, body, &payloadSize, &payloadTransferPort)` 可直接拿到 `payloadSize`/`payloadTransferInfo.port`；`NetEvent` 已有对应字段（JS 事件映射待 d.ts v2 定稿）。

- `payload_manager.{h,cpp}`：transfer 注册表（transferId → 状态机）、spool 目录管理、`sendPayload/keepPayload/discardPayload/cancelPayload` 入口、进度节流与事件组装（复用 `EventCallback`，`net_types.h` 的 `NetEvent` 扩字段）。
- `payload_channel.{h,cpp}`：临时监听（1739–1764 逐个 bind）、向对端发起 payload 连接、TLS server/client 握手（复用 `net/tls_engine`，证书取自该 deviceId 的控制连接会话）、epoll 驱动的流式拷贝循环（socket 非阻塞；本地文件读写缓冲 16 KiB）。
- `net/` 改动点：`tcp_connection`/`net_stack` 需暴露「某 deviceId 的对端地址 + 对端证书」查询接口给 payload 模块；`napi_exports` 注册 4 个新方法；`napi_events` 扩展事件字段映射。
- 约束（CPP_GUIDE §2）：`payload/` 只依赖 POSIX + cJSON + `net/` 的连接管理接口，不直接 include NAPI 头（NAPI 组装放 `napi/`），host 单测可编译。
- 生命周期：设备断开（`disconnected`）时，该设备进行中的 transfer 全部转 `failed`（send 侧同时关监听）。

## 5. 安全要求

- payload 监听器收到连接后，先完成 TLS 握手并**校验对端证书 CN == 该 transfer 期望的 deviceId**，不匹配立即断开，不传输任何字节（KDE 用 isDeviceTrusted 配置，我方为防未配对设备探测加固）。
- spool 目录内文件名不使用对端提供的 `filename` 原文（路径注入防护）：spool 名 = `payload_<transferId>.bin`，`fileName` 仅作展示与 `keepPayload` 时的建议名。
- `keepPayload` 目标路径由 ArkTS 决定（其负责用户可见目录与合法性）；native 只做 move，不额外放宽沙箱。

## 6. 验收（对齐 M1 锚点）

1. 桌面 KDE「发送文件」→ 鸿蒙 `payloadTransfer started/progress/finished` → `keepPayload` 落盘，内容与源文件一致（大小 + 哈希比对）；
2. 鸿蒙 `sendPayload` → 桌面 KDE 收到文件，KDE 侧无告警；
3. 空文件（0 字节）双向传输正常（不建 payload 连接）；
4. 中途取消：KDE 侧取消 → 鸿蒙收到 `failed/cancelled`；鸿蒙 `cancelPayload` → KDE 侧传输中止；
5. 大文件（≥100 MiB）传输不卡 ArkTS UI（epoll 线程承载，主线程只收节流进度）；
6. 未配对设备直连 payload 端口：TLS 校验拒之门外，无事件泄漏。

## 7. 测试要点（供 CodeArts 出单测指导）

- `payload/` host 可测部分：transferId 分配与注册表状态机、spool 文件名生成（不落对端文件名）、事件节流逻辑、`payloadSize==0` 分支。
- 需双端联测部分：§6 全部（单测无法覆盖 TLS 互操作）。
