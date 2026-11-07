# S2 文件分享闭环 — Native 侧契约提案（Omp-Native，2026-11-07）

> **状态（2026-11-08 用户裁决）**：S2 **只定契约，实现暂缓**——等「Rust 是否作为主要维护分支
> 并入 main」拍板后再决定在 C++ main 还是 Rust 分支落地。本文是 Native 侧对联合契约
> `devdocs/DESIGN_FILESHARE_20261110.md`（owner：Omp-ArkTS）的输入；两栈通用。

> 目的：让 S2（D+3 起）的 ArkTS/Native 接口在开工前定稿。原则：**能不新增 NAPI 就不新增**；
> Native 只做官方 API 覆盖不到的部分（socket/TLS/流式 payload），队列/重试/UI 归 ArkTS。
> 事实源：`kdeconnect-meta/schemas/kdeconnect.share.request{,.update}.json` + 现有 `Index.d.ts`。

## 1. 现状（全 Rust 分支已实现，可直接复用）

- `sendPayload(deviceId, packetType, bodyJson, filePath): number`：native 注入
  `payloadSize` 与 `payloadTransferInfo.port`，返回 transferId（0=失败）。
- `keepPayload/discardPayload/cancelPayload`：接收完成后 spool 的处置。
- 事件 `payloadTransfer`：`started/progress/finished/failed/cancelled`，字段
  `payloadDirection / payloadState / payloadSize / payloadBytesDone / payloadFileName / payloadFilePath / errorCode / errorMessage`。
- 进度节流 ≤10Hz（100ms）；接收侧每 16KiB 写 spool。
- 单包上限 32MiB（控制帧）；payload 字节流不受该上限约束。

## 2. `kdeconnect.share.request.update`（多文件元数据）

- **接收方向（桌面 → 手机）**：native 不需要专门处理，按普通 packet 走
  `packetReceived` 原样交给 ArkTS；ArkTS 记录 `numberOfFiles/totalPayloadSize` 作为批次总计。
  后续每个文件仍是独立 `share.request` + 独立 payload，事件照旧。
- **发送方向（手机 → 桌面）**：由 **ArkTS 先调 `sendPacket(deviceId, updateJson)`**，
  再对每个文件调 `sendPayload`。native 保证同一连接的 TX 队列**先进先出**，因此
  update 必先于各文件的 control 帧到达对端；无需新增 NAPI。
- 若 ArkTS 希望“一次调用发整批”，可另提案 `sendPayloadBatch(...)`；本提案默认不做
  （队列/错误处理在 ArkTS 更易做 UI）。

## 3. 多文件顺序与并发

- **建议 ArkTS 串行发送**（同一时刻 1 个 transfer）：与桌面 KDE 的既有行为一致，
  避免对端在“替换链路/多 payload”窗口下的状态歧义。
- 接收方向 native 允许多个 transfer 并存（每个 transfer 独立 port/线程）；单设备
  并发上限建议由 ArkTS 控制在 2 以内。
- transferId 是 native 单调分配，跨文件唯一；ArkTS 用 `(deviceId, transferId)` 关联
  update/started/progress/finished。

## 4. 失败与重试（错误码口径）

| 场景 | `payloadState` | `errorCode` | `errorMessage`（示例） |
|---|---|---|---|
| 对端拒连/端口不可达 | failed | ECONNREFUSED(111) | payload connect failed |
| 握手/接受超时（30s） | failed | ETIMEDOUT(110) | payload handshake/accept timeout |
| 传输 30s 无进展 | failed | ETIMEDOUT(110) | payload stalled (no progress) |
| 对端 CN ≠ deviceId | failed | EACCES(13) | payload peer cert mismatch |
| 对端提前关闭 | failed | ECONNRESET(104) | payload peer closed early |
| 本地 spool 写失败 | failed | errno | payload spool write failed |
| 用户取消 | cancelled | ECONNABORTED(103) | cancelled by local user |
| `sendPayload` 立即失败（文件/设备不可用） | 仅返回 0 | — | 无事件（既有语义） |

- **对齐联合稿 `DESIGN_FILESHARE_20261110.md` §5 的编号（1–7）**：

| 联合稿 code | 含义 | native 侧 `payloadTransfer failed` 的 `errorCode`/msg | 备注 |
|---|---|---|---|
| 0 | 成功/完成 | 无（`started/progress/finished` 的 code 恒为 0） | 显式约定 |
| 1 | 对端端口连接失败/30s 超时 | 接收方回连失败：ECONNREFUSED(111) | 发送方「监听 30s 无人连入」也是 ETIMEDOUT(110)，建议一并归 1 |
| 2 | payload TLS 握手失败 | ETIMEDOUT(110) / EIO / 证书不符 EACCES(13) | `tls.rs` 决定细节 |
| 3 | 传输中断 | ECONNRESET(104)（对端提前关闭）/ EIO（读写失败） | |
| 4 | 本端文件读失败/权限 | **预检失败**：`sendPayload` 返回 0（无事件）⇒ ArkTS 映射 4；传输中：EIO "payload source read failed" | |
| 5 | 落盘失败/空间不足 | **预检失败**：`startReceive`/open spool 失败 ⇒ 无任务、回 error EIO "payload not started"；传输中：EIO "payload spool write failed" | |
| 6 | 用户取消 | cancelled / ECONNABORTED(103) | |
| 7 | 对端未取件（keep 前 spool 被丢弃） | 7b 用户主动丢弃：ArkTS 调 `discardPayload`，native 无事件（ArkTS 自知）；7a 24h 自动回收：native 静默 reap，**无事件** | 若要 7a 有事件需新增；推荐 ArkTS 按本地时间戳判断过期 |
| — | 控制队列满 | ENOBUFS(105) "sendPacket: tx queue full" | 控制帧路径 |

- **重试策略归 ArkTS**：收到 failed 后按 `errorCode` 决定是否重试；重试 = 重新
  `sendPayload`（native 每次重新开 listener/端口，不复用旧 transfer）。
- native 保证：失败/取消后立即关闭 socket 并释放监听端口；spool 半成品删除；
  `keepPayload` 对非 finished/发送任务返回 false（幂等）。

## 5. 接收开关 / 自动保存开关

- **自动保存**：native 已是「先落 spool，由 ArkTS `keepPayload` 决定去向」；开关只在 ArkTS
  生效，native 无改动。
- **接收开关（是否接受对端文件）**：两种方案二选一（请 CodeArts 定）：
  1. **无新 API（推荐先做）**：ArkTS 在 `payloadTransfer started`（direction=receive）
     时若开关关闭，立即 `cancelPayload(transferId)`；native 关 socket 并把取消信号传给对端。
     代价：已建立连接后才取消（大文件可能白传几 KB）。
  2. **新增 NAPI**：`setReceivePayloadsEnabled(enabled: boolean): void`，native 在
     `start_receive` 前 fail-closed（不建任务、不落 spool，回
     `error code=EACCES "payload rejected: receive disabled"`）。需要 d.ts 变更走契约流。
- 若选 2，native 侧改动很小（共享一个 bool + 一处判断），可在 1 天内完成。

## 6. 待 CodeArts 确认的问题

1. 接收开关选 1（cancel-on-started）还是 2（新增 `setReceivePayloadsEnabled`）？
2. 多文件发送是否同意「ArkTS 先发 update + 串行 `sendPayload`」，不改 d.ts？
3. 进度 UI 以 `payloadBytesDone/payloadSize` 为准还是需要批次级聚合事件？
4. `share.request.update` 的 `numberOfFiles/totalPayloadSize` 是否由 ArkTS 从待发文件列表计算
   （native 不参与）？

## 7. 验收对照（S2 native 侧）

- 双向各 ≥3 文件（含大文件）：native 已支持；需 ArkTS 队列串行。
- 失败有错误码：上表已覆盖。
- 开关跨重启：ArkTS 持久化；native 侧选 1 时无需状态。
- 接口契约先定稿：本文即提案，确认后 D+3 当天冻结。

—— Omp-Native，2026-11-07
