# CCR-3: KcApi 补登记（信任/证书/手动连接/能力集）+ 事件形态 + contractVersion

- 日期：2026-11-15
- 提出人：AtomCode（依据用户 2026-11-15 对「阶段 B 三个开放问题」裁决建议的批准）
- 状态：**Conditional Approved 已按意见修正（2026-11-15）**——CodeArts 评审通过（F1–F5 全部采纳），Omp-ArkTS 已签名；
  **待 Omp-Native 车道签名后生效**
- 影响：`contract/kcbridge.d.ts`、`devdocs/MAP_KCApi_PHASEA_20261114.md`、`KcBridge.ets`（阶段 B）、`tools/check-native-contract.py`（C 组转阻塞）
- 关联：`MSG261`（队列裁决 P1-5 Stage-B）、`MSG263`（映射表骨架/阶段 A 实施）、`MSG262`（阶段 B 排序）

## 1. 动机

阶段 A 已把 native 依赖收敛到唯一 `KcBridge.ets`（现有 19 导出一一转发，契约未动）。
映射表（`MAP_KCApi_PHASEA_20261114.md` §2）指出：冻结 `KcApi` 与现行导出有 **5 条契约缺口**（信任/证书 4 个、`setCapabilities`、手动连接 2 个、`getPairVerificationCode`），
若不在契约层补登记，ArkTS 无法完成配对信任与手动连接；同时 `kind + JSON` 事件形态需要在 bridge 内还原类型化事件。

本 CCR **只增不减**：旧 `Index.d.ts`/napi 导出原样保留，`KcBridge` 以适配层承接新形态；`errors.v1.json` 码表与 `capabilities.v1.json` 能力广告均不变。

## 2. 变更内容

### 2.1 `kcbridge.d.ts` 的 `KcApi` 新增 8 个方法（只增）

```typescript
/** 能力集：直接声明本端 incoming/outgoing（不再由 ArkTS 自拼 identity 能力表） */
setCapabilities(incoming: string[], outgoing: string[]): void;

/** 配对待确认码（v8：双方公钥 DER 排序拼接 + SHA256 前 8 位 hex；timestamp 为对端 timestamp，秒） */
getPairVerificationCode(deviceId: string, timestamp: number): string;

/** 信任与证书（配对信任链；certPem 为对端叶证书 PEM） */
getPeerCertificate(deviceId: string): string;
getOwnCertificate(): string;
setTrustedCertificate(deviceId: string, certPem: string): void;
removeTrustedCertificate(deviceId: string): void;

/** 手动连接（Add by IP）；host 为 IPv4/IPv6 字面量，port 为 TCP 端口 */
connectToPeer(host: string, port: number): void;
disconnect(deviceId: string): void;
```

### 2.2 事件形态（既定，不新增方法）

- 契约层：`setOnEvent(cb: (kind: number, eventJson: string) => void)`（当前 d.ts 已定义，不改）；
- `contract/kcbridge.d.ts` 的 `EventKind` 为 **15 项（0–14）**（F1 修正：此前误写 14）；
- 实现层：`KcBridge` 内维护 **15 行 `EventKind` → 内部 `NetEvent` 对照表**（**多对一折叠**，不是一一对应），
  控制器/插件签名零改动；**未知 `kind` ⇒ 丢弃 + 记日志**；**已登记 kind 必须全部有处置（不得静默丢弃）**。

| kind | 契约事件 | 内部处置（阶段 B） |
|---|---|---|
| 0 | `EngineStarted` | 丢弃 + debug 日志（`start()` 同步返回已覆盖启动结果） |
| 1 | `EngineInitFailed` | 丢弃 + debug 日志（`start()` 返回 false / toast 已覆盖） |
| 2 | `EngineStopped` | 丢弃 + debug 日志（`stop()` 幂等，无 UI 依赖） |
| 3 | `DeviceVisible` | → `deviceDiscovered` |
| 4 | `DeviceGone` | → `deviceLost` |
| 5 | `DeviceUpdated` | 丢弃 + debug 日志（名称更新由 `packetReceived`/`connected` 承载） |
| 6 | `Unpaired` | 丢弃 + debug 日志（以 `kdeconnect.pair{pair:false}` 包为准） |
| 7 | `PairRequest` | → `pairingRequest` |
| 8 | `PairResult` | 丢弃 + debug 日志（结果由 `kdeconnect.pair` 包解析） |
| 9 | `Packet` | → `packetReceived` |
| 10 | `TransferStarted` | → `payloadTransfer(state='started')` |
| 11 | `TransferOffer` | 丢弃 + debug 日志（S2 走 spool 模式，不依赖 offer；将来启用 offer 模式再映射） |
| 12 | `TransferProgress` | → `payloadTransfer(state='progress')` |
| 13 | `TransferDone` | → `payloadTransfer(state='finished'｜'failed')`（按 success 字段） |
| 14 | `Log` | → 写入 `LogStore`（不丢；与「不得静默丢弃」一致） |

> 内部 `NetEvent` 现有 8 值（`deviceDiscovered/deviceLost/connected/disconnected/packetReceived/pairingRequest/payloadTransfer/error`），
> 故 15 kind 中 5 个走折叠、7 个显式丢弃+日志、3 个（Log/DeviceVisible/DeviceGone… 见上表）另有归属；单测须**逐行**覆盖。

### 2.3 `contractVersion` 校验策略（写入契约注释）

1. ArkTS 侧常量 `EXPECTED_CONTRACT_VERSION`（随本文件版本同步的手工常量，改动即评审点）；
2. 启动早期（`Index.aboutToAppear` 装配控制器前）调用；
3. 不匹配 ⇒ **拒绝 `start()`** + 日志/状态栏可见（E109 语义），不得静默继续；
4. 桩测试：注入不同版本 ⇒ 断言「未 start + 已记录」。

### 2.4 语义备注（不新增方法，但需在 d.ts 注释写明）

| 方法 | 备注 |
|---|---|
| `setSftpRoots` | **声明但 not implemented**（Q3 已裁决不广告 `sftp` 能力）；**napi 无对应导出** ⇒ bridge 提供 stub，返回 `E105 BAD_PARAM`（或等价未实现码）+ 日志，避免广告不可用能力 |
| `setAutoAcceptSec` | **napi 无对应导出** ⇒ bridge 提供 stub 返回 `E105`（阶段 B 若实现 offer 模式再接入）；与 S2「自动保存接收文件」是**不同语义**，**不默认开启**，注释写明 |
| `generateIdentity` | **保留 ArkTS 持有私钥**：bridge 内调 `generateCert` + 回填 deviceId，返回形状不变；私钥入 HUKS 属 0.8.x 安全补丁，另走 CCR-4 |
| `stop` | 幂等；进程级 `shutdown` 作为别名标注，不新增方法 |

## 3. 兼容性与风险

### 3.1 现有 `KcApi` ↔ napi 导出签名差异（F3 补充；非本 CCR 引入，阶段 B 适配需处理）

| 方法 | `KcApi`（冻结） | napi 现行 | 阶段 B 映射策略 |
|---|---|---|---|
| `sendPacket` | `(deviceId, type, bodyJson)` | `(deviceId, packetJson): boolean` | bridge 内拼 `{type, body}` 成 packetJson；返回值转事件/`KCError` |
| `start` | `(configJson: string)` | `(config: NetConfig): boolean` | bridge 解析 configJson → NetConfig；结果合成 `EngineStarted`/`EngineInitFailed` |
| `setOnEvent` | `(cb: (kind, json) => void)` | `init(cb: (event: NetEvent) => void)` | bridge 内建 15 行 kind↔NetEvent 映射（§2.2） |
| `generateIdentity` | `(deviceName): string` | `generateCert(deviceId): CertPair` | bridge 生成/回填 deviceId（证书 CN），返回 `{deviceId, certPem, keyPkcs8Base64}` |
| `sendFile` | 5 参数（含 filePath+filename） | 无（`sendPayload(deviceId, type, bodyJson, filePath): number`） | bridge 调 `sendPayload`，filename 并入 body；tid 由 `TransferStarted` 回填 |
| `acceptTransfer/rejectTransfer/cancelTransfer` | 3 方法（void） | `keepPayload/discardPayload/cancelPayload`（boolean/void） | 名称映射；失败走 `KCError`（`kind=throw` 抛、`kind=event` 事件） |

### 3.2 风险与约束

- **只增不减**：8 个方法均为新增；现有 19 个 napi 导出与 `Index.d.ts` 不动，老路径经 `KcBridge` 继续可用；
- **不做能力广告变化**：`capabilities.v1.json` 与 identity 广告范围不变（`setCapabilities` 只是把既有能力集入口契约化）；
- **风险**：`contractVersion` 常量若与 native 生成值漂移会拒绝启动 ⇒ 由 `check-native-contract.py` C 组转阻塞 + CI 双端校验兜底；
- **不在本 CCR**：`setSftpRoots` 实装、HUKS 私钥移民、`setAutoAcceptSec` 与 autoSave 合并。

## 4. 验收（生效条件）

1. CodeArts 评审通过（重点：新增方法签名是否贴现有导出、`contractVersion` 失败语义、注释准确性）；
2. Omp-ArkTS（bridge 侧）与 Omp-Native（导出侧）双方书面确认签名一致；
3. `contract/kcbridge.d.ts` 更新后：`tools/check-native-contract.py` **C 组转阻塞**（19→27 方法集合相等）；
4. 阶段 B 门禁：`contractVersion` 桩用例、14 kind 映射单测、真机冒烟（连接/配对/收发一图）。

## 5. 状态记录

| 日期 | 事件 |
|---|---|
| 2026-11-15 | 草案提出（AtomCode，用户批准裁决建议） |
| — | 待 CodeArts 评审 + 两车道签名；生效后更新 d.ts 并排阶段 B |
