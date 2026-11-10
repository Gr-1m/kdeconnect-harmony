# P0 交付：现有 errorCode → 契约 v0.2 / kcbridge 映射表（Omp-Native，2026-11-08）

> **码空间边界裁决（2026-11-10，AtomCode）**：`contract/errors.v1.json`（kcbridge 101–503）与 payload 0–7
> 是**两套独立码空间**，边界以本文档（§0）标注为准；**暂不修改 `errors.v1.json`**（避免契约抖动）。
> 若将来需要机读（工具/测试消费），再走一次 CCR（只增不减的顶层键，如
> `"codeSpaces": {"control":"101-503","payload":"0-7"}`），届时由 CodeArts 起草 CCR-3。

> 依据：MSG196 §2 派单（错误码对齐 + 映射表先交 CodeArts 评审）、`devdocs/DESIGN_FILESHARE_20261110.md` §5（v0.2）、
> `docs/kdeconnect-oh/08-interface-contract.md` §4（kcbridge 错误码）。
> **2026-11-09 已对照参考实现**：`kdeconn1109/kdeconn-1108/contract/errors.v1.json` 与 docs/08 §4 **逐条一致**
> （101–503 / kind / disposition），故 §2 的 E 码列无需调整；见 `REFERENCE_KDECONN1109_TAKEAWAYS.md`。
> 范围：**只映射，不改协议逻辑**；阶段 1 仅形态对齐（阶段 2 下沉另行派单）。
>
> **2026-11-09 实现状态**：payload 路径 0–7 **已落地**（`core/src/payload.rs` 的 `pub mod code`；
> 含 spool 超时补 `failed code=7` 事件、`cancelPayload` → 6）；E2E 增加「cancel → code 6」断言。
> 控制路径 E 码（§2）**已按 `contract/errors.v1.json` 落地**（MSG199 §1 裁决）：新增
> `core/src/errors.rs`（101–503 + `Disposition` + `is_throw`，穷举分级 + 单测），所有 `error`
> 事件改用该编号；E2E 负路径断言由 errno 13 → `CERT_MISMATCH(201)`。

## 0. 两套码空间边界（勿合并）

| 码空间 | 范围 | 事件字段 | 位置 |
|---|---|---|---|
| **kcbridge 控制路径码** | 101–503 | `Error.errorCode` | `core/src/errors.rs`（唯一事实源 `contract/errors.v1.json`） |
| **payload 通道码（契约 v0.2）** | 0–7 | `PayloadTransfer.errorCode` | `core/src/payload.rs` 的 `pub mod code` |

- 两套码**独立编号、独立语义**，数字重叠不代表同一含义（例：kcbridge `403 SEND_FAILED` 与 payload `3`）；
- `contract/errors.v1.json` 里预留而**未被引用的码**（101/109/205/302/303/402/501/502/503）属**后续阶段预留**，
  发布前不得因为「未使用」而删除；其中 payload 侧的取消/文件 IO 走 payload 码（6/4/5），**不要**改成 kcbridge 码；
- 判定口径：一个错误若属「控制路径（链路/协议/证书/参数）」→ 用 kcbridge 码；若属「payload 传输自身状态」
  → 用 payload 码（仲裁见 CodeArts 报告 `devdocs/REVIEW_ECODE_B596260_20261109.md` §6）。

## 1. payload 路径：现有 → 契约 v0.2（0–7）

| 现有触发点（Rust） | 现报 code | v0.2 code | 说明 |
|---|---|---|---|
| `started/progress/finished` | 0 | **0** | 成功/完成（已满足，仅显式化） |
| 接收方回连失败（ECONNREFUSED/ETIMEDOUT） | 111/110 | **1** | 对端 payload 端口连接失败/超时 |
| 发送方监听 30s 无人连入（"payload accept timeout"） | 110 | **1** | 同属「端口超时」；v0.2 表未列发送侧，建议并入 1 |
| payload 证书 CN 不符 / pin 不符 | **13** | **2** | 契约定性为「TLS 握手失败（证书/角色）」；修 13 撞号 |
| payload TLS 初始化/握手 IO 失败（非证书） | 110 / 5 | **2** | 归 2；**细节留 errorMessage** |
| 传输中断：对端提前关闭 / 本端写失败 | 104 / 5 | **3** | 「对端读到 0 或本端写失败」 |
| 本端源文件读失败 / 文件比 payloadSize 短 | 5 | **4** | 「本端文件读失败/权限」 |
| spool 写失败 / open 失败 | 5 | **5** | 「落盘失败/空间不足」；修 5 撞号（见 §3） |
| 用户主动取消（`cancelPayload`） | 103 | **6** | 「用户取消」 |
| 接收完成后的 spool 自动回收（24h） | 静默 | **7** | 「对端超时未取件」；现无事件，见 §4 待决 |
| （发送侧）对端始终未取件 | 110 | **1** | 发送侧语义=1；接收侧超时=7 |

## 2. 控制/连接路径：现有 errno → kcbridge 阶段 1（E 码）

| 现有触发点 | 现报 code/msg | kcbridge code | 分级（08 §4） |
|---|---|---|---|
| 证书不符（控制链路 pin/CN） | 13 | **201 CERT_MISMATCH** | FatalLink |
| 明文身份/协议校验失败（self identity、target 校验、非法帧） | 13 / 5 | **202 PROTOCOL_VIOLATION** | FatalLink |
| 同 `(host,deviceId)` 限速拒绝 | 13（EAGAIN） | **202** | FatalLink（对端可重试） |
| 未配对设备发非协议包 / payload 非受信设备 | 13 | **202** | FatalLink |
| identity 帧超限 | 静默丢弃 | **203 LINE_TOO_LONG** | DropPacket |
| identity 非法（deviceId 正则/名称过滤） | 静默 | **204 IDENTITY_INVALID** | FatalLink |
| 配对时间戳超 1800s | 由 ArkTS 判定 | **205 CLOCK_SKEW** | DropPacket |
| 出向连接失败/超时、端口探测无监听 | errno | **301 PEER_NOT_CONNECTED** | Infra/Drop |
| transferOffer 10s 未响应 | 由 ArkTS 处置 | **302 OFFER_TIMEOUT** | Drop |
| 用户取消传输 | 103 | **303 TRANSFER_CANCELLED** | Drop |
| payload 通道超时（发送监听无人连/回连超时） | 110 | **401 PAYLOAD_TIMEOUT** | Infra |
| 本地文件读写/spool 失败 | 5 | **402 FILE_IO** | Infra |
| 发包失败（链路断/队列满 ENOBUFS） | 105 | **403 SEND_FAILED** | Infra |
| 引擎 panic / identity 自检失败 / 端口绑定失败 | 进程级 | **501 / 502 / 503** | Fatal |

## 3. 需修掉的撞号（MSG196 §2 点名）

1. **13（EACCES）**：现被用于「证书不符 / 限速 / 未配对 / 协议校验」等多种语义 ⇒ 在阶段 1 分别归 201/202，payload 证书归 v0.2 `2`；
2. **5（"not started"）**：现 `payload not started (port missing/deviceId unknown/not trusted)` 用 EIO(5)
   ⇒ 归 **202**（策略拒绝）或 **401**（端口缺失）——见 §4 待决；
3. `error` 事件与 `payloadTransfer` 事件的 `errorCode` 采用同一编号空间（阶段 1 均为 kcbridge 码）。

## 4. 待 CodeArts 裁决（3 项）

1. **接收侧 spool 超时（v0.2 code 7）**：**已按方案 A 实现**——`tick` 回收前补
   `failed code=7 "payload spool expired (peer did not fetch)"`（ArkTS `PayloadController.ets`
   已按 `errorCode === 7` 显示「对端未取件」）；待 CodeArts 复核确认。
2. **「payload not started」归类**：`port missing`→401？`deviceId unknown/not trusted`→202？还是统一 202？
3. **payload TLS 非证书失败**：v0.2 只有 code 2；是否允许 2 + `errorMessage` 区分（无需新增码）？

## 5. T2 §4 观察项跟踪（本表附带）

| 观察项（GLM5.3） | 现状 | 下一步 |
|---|---|---|
| spool 总大小上限 | 无总量上限（仅 24h 回收） | 阶段 1 后加 `PAYLOAD_SPOOL_MAX_BYTES`（limits.rs）+ 超限拒绝 |
| `keepPayload` 路径白名单 | 仅拒 `..` | 评估 `allowedRoots` 配置（对齐 08 §2） |
| `libc++_shared.so` 瘦身 | HAP 内随 NDK 带入（~1.2MB） | 评估 `-static-libstdc++`/仅留必需 ABI |
| 二次 identity 复校 protocolVersion | 我方只比 deviceId/CN | 补 protocolVersion 比较（≤ 或 = 8） |
| 周期遥测 | 无 | 评估 `log` 事件（kind 14）或 hilog 计数，phase 2 |

—— Omp-Native，2026-11-08
