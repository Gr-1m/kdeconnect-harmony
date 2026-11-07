# DESIGN — 文件分享闭环契约（S2，草案 v0.1）

- 日期：2026-11-08（D+1；D+3=11-10 定稿）
- 作者：Omp-ArkTS；**待 CodeArts 评审、Omp-Native 确认**
- 范围：S2「文件分享闭环」（`devdocs/ROADMAP_FUNCTIONAL_20261107.md` §6）
- 事实源：`kdeconnect-meta/schemas/kdeconnect.share.request.json`、`.../kdeconnect.share.request.update.json`（协议唯一事实源）；
  KDE 桌面 `core/compositefiletransferjob.cpp`、`plugins/share/shareplugin.cpp`（行为对照）

## 1. 协议事实（已核对，勿凭记忆改）

| 项 | 结论 | 来源 |
|---|---|---|
| `share.request` body 可选字段 | `filename` / `creationTime`(ms epoch) / `lastModified`(ms) / `open`(bool) / `numberOfFiles` / `totalPayloadSize` / `text` / `url`；带 `filename` 时必带 payload 传输信息 | schema |
| `share.request.update` body | **仅** `numberOfFiles` / `totalPayloadSize`；描述为「多文件传输的元数据，按惯例在携带 payload 的包**之前**发送，后者包含相同字段（可能为更新后的总计）」 | schema |
| update 包的进度语义 | **协议未定义**；KDE 桌面接收侧没有对应分支（落到 `Nothing attached` 调试输出）⇒ 预告性质，缺失/多余都不致命 | `shareplugin.cpp:receivePacket` |
| 接收侧批量进度 | KDE 从**每个 `share.request` 包的** `numberOfFiles`/`totalPayloadSize` 建立 `CompositeFileTransferJob`，不是从 update 包 | `compositefiletransferjob.cpp:addSubjob` |
| 空文件 | `payloadSize == 0` 也计入批量（KDE 注释明示「even ones with no payload」），不建立 payload 连接 | KDE `shareplugin.cpp` |
| 文件名处理 | 只取 basename、拒绝路径穿越、目标已存在则自动重命名 | KDE `cleanFilename` / `getFileDestination` / `setAutoRenameIfDestinationExists` |
| payload 通道 | 发送方监听 1739–1764、接收方回连，独立 TLS（同一证书），接收方须 30s 内连上 | `WP1_PAYLOAD_DESIGN.md` §1 |

**结论**：跨端「字节级进度」不在协议内；`share.request.update` 只做**开始前的总量预告**。S2 的「进度」= 本机 UI 用 `payloadTransfer` 事件的进度，**不新增私有包**。

## 2. 发送侧契约（ArkTS）

1. **单文件**：`share.request` body `{filename, lastModified, creationTime, open?}` + `payloadSize` + `payloadTransferInfo{port}`；`payloadSize==0` 时**不发** `payloadTransferInfo`。
2. **多文件（N≥2）**：
   - 发第一个文件之前，先发**一条** `kdeconnect.share.request.update`：`{numberOfFiles:N, totalPayloadSize:Σ}`（对齐 Android，schema 的「advance」语义）；
   - 随后按用户选择顺序逐个发 `share.request`，**每个包都带** `numberOfFiles`/`totalPayloadSize`（KDE 侧就是靠它建批量进度的）；
   - 单个文件失败不阻断队列，继续下一件；结束时汇总「N 成功 / M 失败」。
3. **不实现** update 的反复发送/进度回传（无协议依据）。

## 3. 接收侧契约（ArkTS）

1. 收到 `share.request.update` → 预建「批量」条目（N、总字节），作为 UI 分母；缺失时退化为「一个 request 一个条目」。
2. 收到带 `filename` 的 `share.request` → 走既有 spool → `keepPayload/discardPayload` 流程；
   连续到达的文件在 **5s 窗口 + `numberOfFiles` 计数**内归入同一批（协议无批次 id）。
3. **命名**：仅 basename；拒 `..`；重名自动 `name (n).ext`（沿用 `PayloadHistory.safeFileName`，扩展重名规则）。
4. **空文件**：`payloadSize==0` 直接落 0 字节文件并计入批量。
5. **自动保存开关真正生效**：开 = 完成后自动 `keepPayload` 到下载目录；关 = 进「接收文件」对话框等用户处置；跨重启保持。

## 4. transferId / 顺序 / 取消（**NAPI 零改动**）

- NAPI 现有：`sendPayload(...)→transferId`、`keepPayload`、`discardPayload`、`cancelPayload`、`payloadTransfer` 事件（`direction/state/size/bytesDone/fileName/filePath`）。
- **多文件 = 串行 N 次 `sendPayload`**（现有 `PayloadController.sendQueue` 已如此）；不新增 d.ts 字段。
- **顺序**：单设备单写者，FIFO，严格按用户选择顺序；同一时刻只有一个 payload 通道。
- **批次**：ArkTS 侧新增 `batchId`（单调递增）关联同批的多个 transferId，仅用于 UI 聚合与取消。
- **取消**：`cancelPayload(当前 transferId)` → 关闭 socket（对端据此判失败/取消，**协议无专门取消包**）；同批剩余任务出队并标 `cancelled`。

## 5. 错误码表（需 Omp-Native 在 payload 路径分档，ArkTS 只做文案）

| code | 含义 | 触发点 |
|---|---|---|
| 1 | 对端 payload 端口连接失败/30s 超时 | 接收方回连失败 |
| 2 | payload TLS 握手失败（证书/角色） | 通道建立 |
| 3 | 传输中断（对端读到 0 或本端写失败） | 进行中 |
| 4 | 本端文件读失败 / 权限不足 | 发送前/中 |
| 5 | 落盘失败 / 空间不足 | 接收完成 |
| 6 | 用户取消 | cancelPayload |
| 7 | 对端未取件（keep 前 spool 被丢弃） | 接收完成 |

现状：`error`/`errorCode` 已有通道，但 payload 路径尚未按上表归类 → **是 S2 Native 侧的主要工作量**（不是新契约）。

## 6. 验收（对齐 ROADMAP）

1. 双向各 ≥3 文件（含 1 个 ≥100 MB）——桌面 KDE 与鸿蒙互发；
2. 失败路径给出可区分错误码（断网 / 拒绝落盘 / 空间不足至少两项可复现）；
3. 自动保存开关跨重启生效；
4. 契约先于实现定稿（本文档 + CodeArts 评审记录）。

## 7. 待评审 / 待确认

1. CodeArts：批次 5s 聚合窗口是否可接受？UI 上是否需要「按批折叠」？
2. Omp-Native：§5 错误码表能否落到现有 `errorCode` 通道？是否需要新增 `payloadFailed` 事件字段？
3. 是否对 `creationTime/lastModified/open` 三个可选字段做发送（KDE 会写文件时间戳）——建议发送前两者，`open` 恒 false。
