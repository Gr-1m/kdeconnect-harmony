# P1-1 方法映射表骨架（ArkTS 车道）——现有 19 导出 ↔ 冻结 `KcApi`

> 日期：2026-11-14　状态：**骨架，供总指挥 + CodeArts 评审**（MSG254 §3.1 / MSG259 §3② 采纳项）
> 依据：`contract/kcbridge.d.ts`（Frozen bridge contract v1，源自 `docs/kdeconnect-oh/08-interface-contract.md §2`）、
> 我方 `entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts`、`PLAN_CONSOLIDATED_20261112.md` §2 P1-1 与 §5（P0-4 与 P1-1 合并）。
> 本文件只定**边界与映射**，不含实现；阶段 A 不动契约（无 CCR），阶段 B 走 **CCR-3（只增不减）**。

## 1. 现状盘点（`[代码事实]`）

| 侧 | 事实 |
|---|---|
| 我方 bridge（现行） | `Index.d.ts` **19 个 camelCase 导出**：`init / shutdown / start / stop / connectToPeer / sendPacket / disconnect / generateCert / setCapabilities / triggerBroadcast / sendPayload / keepPayload / discardPayload / cancelPayload / getPeerCertificate / getOwnCertificate / getPairVerificationCode / setTrustedCertificate / removeTrustedCertificate` |
| 我方事件 | `NetEvent`（**类型化对象**，`type` 为字符串：`connected`/`packetReceived`/`payloadTransfer`/…） |
| 契约侧（冻结） | `KcApi` **19 个方法** + `EventKind` **0–14** 常量表 + `KCError{code}`（message 前缀 `KC_E<code>: `） |
| 直连 native 的文件 | 5 个（`Index.ets:3-4`、`EntryAbility.ets:12`、`net/PacketRouter.ets:9`、`state/DeviceController.ets:11`、`state/PayloadController.ets:20-21`） |

> 说明：`PLAN_CONSOLIDATED` 里写的「19 个 snake_case 导出」实为 **camelCase**（以 `Index.d.ts` 为准，见上）；`KcApi` 同为 camelCase，故**命名差异不是主要成本**，真正的差异在下面 §2 的「语义/形态」列。

## 2. 方法映射（KcApi → 我方现状）

| # | `KcApi`（冻结契约） | 我方现状（`Index.d.ts`） | 差异类型 | 处置（阶段 A / 阶段 B） |
|---|---|---|---|---|
| 1 | `contractVersion(): number` | **缺** | 新增常量 | A：无；B：native 生成常量 + ArkTS 启动校验（见 §3） |
| 2 | `generateIdentity(deviceName): string(JSON)` | `generateCert(deviceId): CertPair` | **语义**（谁持有 deviceId / 私钥是否出 native） | A：保留现状；B：CCR-3 决定「身份生成归谁」——我方现状是 ArkTS 持有私有密钥（`keyPem` 落 Preferences），与 HUKS backlog 一并决议 |
| 3 | `start(configJson): void`（结果走事件） | `start(config: NetConfig): boolean`（同步返回） | **形态**（事件化 vs 同步返回） | A：保留现状；B：`engineStarted/engineInitFailed` 事件化 |
| 4 | `stop(): void`（幂等） | `stop(): void`、`shutdown(): void` | 我方多一个进程级 `shutdown` | A：保留；B：`stop` 幂等 + `shutdown` 并入或标注别名（CCR-3 写明） |
| 5 | `setOnEvent(cb(kind: number, json: string))` | `init(cb(event: NetEvent))` | **最大结构性差异**：类型化对象 → `kind + JSON` | A：保留；B：**映射层放在 `KcBridge` 内部**（kind→内部 `NetEvent` 还原），控制器不感知编号，避免污染既有类型 |
| 6 | `networkChanged(networkJson): void` | 缺（`NetworkWatcher` 内部探测后调 `triggerBroadcast`） | 新增入口 | A：保留；B：ArkTS 由 `NetworkWatcher` 调 |
| 7 | `refreshDiscovery(): void` | `triggerBroadcast(): void` | 命名 | A：保留（bridge 内做别名注释）；B：改名或保留别名 |
| 8 | `requestPair/acceptPair/rejectPair/unpair` | 无原语：ArkTS 用 `sendPacket(..., 'kdeconnect.pair', body)` **自拼协议 body** | **原语化**（把协议知识收回 native） | A：保留；B：KcBridge 映射到原语，ArkTS 不再拼 `kdeconnect.pair` |
| 9 | `setDeviceName(name)` | 无原语（同上走 `sendPacket` + 本地 Preferences） | 原语化 | A：保留；B：同上 |
| 10 | `sendPacket(deviceId, type, bodyJson): void` | `sendPacket(deviceId, packetJson): boolean` | 签名 + 返回语义 | A：保留；B：拆 `type`、错误事件化 |
| 11 | `sendFile(deviceId, type, bodyJson, filePath, filename): void` | `sendPayload(deviceId, packetType, bodyJson, filePath): number`（返回 tid） | 语义（tid 由事件回填；多 `filename`） | A：保留（S2 批次逻辑依赖返回值）；B：`TransferStarted` 事件回填 tid |
| 12 | `acceptTransfer(transferId, destPath): void` | `keepPayload(transferId, destPath): boolean` | 命名 + 返回语义 | A：保留；B：映射（失败走事件/`KCError`） |
| 13 | `rejectTransfer(transferId): void` | `discardPayload(transferId): boolean` | 命名 | A：保留；B：映射 |
| 14 | `cancelTransfer(transferId): void` | `cancelPayload(transferId): void` | 命名（一一对应） | A：保留；B：别名/改名 |
| 15 | `setSftpRoots(rootsJson): void` | **缺**（SFTP 未实现；Q3 已裁决**不声明** `canCreateSftpServer`） | 新增 | A：无；B：**先不实现**，KcBridge 内显式 `not implemented`（避免广告不可用能力） |
| 16 | `setAutoAcceptSec(sec): void` | **缺**（我方语义是 `autoSaveFiles` + 用户手势） | 语义待定 | A：无；B：CCR-3 里写明「与 S2 autoSave 的关系」，不默认开启 |
| 17 | — | `getPairVerificationCode(deviceId, ts)` | **我方额外** | A：保留；B：决定是否并入 `PairRequest` 事件负载 |
| 18 | — | `setCapabilities(incoming[], outgoing[])` | **契约缺口**（I10 能力集来源） | A：保留；B：CCR-3 需补对应方法或明确「能力由 native 按 `capabilities.v1.json` 自生成」 |
| 19 | — | `getPeerCertificate / getOwnCertificate / setTrustedCertificate / removeTrustedCertificate` | **契约缺口**（信任/证书 4 个导出在 KcApi 无对应） | A：保留；B：CCR-3 补方法或明确「信任由 native 自管、ArkTS 只消费事件」 |
| 20 | — | `connectToPeer(host, port) / disconnect(deviceId)` | 契约缺口（手动连接/断开） | A：保留；B：同上 |

**小结**：一一对应或可直映射的 **6** 条（4/13/14 + 命名类 7/12 + 部分 10）；**语义不同** 5 条（2/3/5/11/16）；**契约缺口**（KcApi 未覆盖我方必要的）5 条（17–20 及 `setCapabilities`）；**缺失（native 新增）** 4 条（1/6/8/9/15）。

## 3. `contractVersion` 校验策略（阶段 B）

1. ArkTS 侧定义 `EXPECTED_CONTRACT_VERSION`（随 `contract/` 版本同步的手工常量，改动即评审点）；
2. **启动早期**（`Index.aboutToAppear` 装配控制器之前）调用 `bridge.contractVersion()`；
3. 不匹配 ⇒ `notify.log` 记一行 + **拒绝 `start()`**（不进入半兼容运行）+ 状态栏显示「引擎契约不匹配（E109 语义）」；
4. 单测：注入桩 bridge 返回不同版本 ⇒ 断言「未调用 start + 记录日志」（宿主通道可跑）。

## 4. 阶段 A / 阶段 B 边界（避免两次搬迁）

| | 阶段 A（**现在可做**，无契约变更） | 阶段 B（**CCR-3 后**） |
|---|---|---|
| 目标 | 收敛 native 依赖到**唯一** `net/KcBridge.ets` | 在 bridge 内**增补** `KcApi` 形态（原语 + `kind/JSON` 事件） |
| 改动 | 新增 bridge，按域分组（lifecycle / pair / payload / trust / caps / discovery）暴露**现有 19 导出的同签名**；其余 4 个文件改为经 bridge 调用 | bridge 内部做 `kind ↔ NetEvent` 映射、原语化配对/设备名、错误 `KCError` 化、`contractVersion` 校验 |
| 明确不做 | **不**引入 `KcApi` 命名、**不**改事件形态、**不**动 `Index.d.ts`/napi、**不**改任何 `contract/` | 不改控制器对外方法签名（映射留在 bridge 内） |
| 验收 | `grep -rl libkdeconnect_napi.so entry/src/main/ets` 只剩 bridge（`EntryAbility` 单列例外并注明理由）；宿主 111 例 + 设备 hypnos 全绿；真机冒烟（连接/收发一图） | `contractVersion` 校验用例 + `d.ts ↔ napi` 门禁脚本（native P1-2）联合验收 |
| 串行队列（P1-5） | **A 阶段不引入**：P0-A3 审计已证派发链全程同步（见 `PluginEventBus`/`DeviceController`/`Index` 注释） | 若阶段 B 的事件化引入 await 分支，再在 bridge 内加**单写者队列**（统一入口，不散落各控制器） |

> 依据（为什么 A 阶段不引串行队列）：MSG259 §3④ 与统一规划 §5 都要求「P1-5 的 ArkTS 串行队列随 KcBridge 阶段 A 落地」——
> 但 A 阶段仍是**同步**调用形态（现有 19 导出全同步），加队列会是**无目标复杂度**；本表按「有 await 才排队」给出边界，请总指挥裁决。

## 5. 待评审的三个开放问题

1. **身份生成归属**（#2）：KcApi 的 `generateIdentity` 期望 native 产出 deviceId + 私钥 base64；我方现状是 ArkTS 持私钥（含 HUKS backlog）。是否在 CCR-3 里改归属，或保留 ArkTS 归属并在契约里改签名？（涉及安全与重装不丢身份的既有验证）
2. **事件形态**（#5）：`kind + JSON` 会丢掉我们现在的类型化 `NetEvent`（`plugins/*` 的 body interface 收益）。建议：**契约层用 kind/JSON，ArkTS 层在 KcBridge 内还原类型化事件**，不改控制器与插件；请确认这符合「不改控制器签名」的约束。
3. **契约缺口**（#17–#20 + `setCapabilities`）：信任/证书/手动连接/能力集在 `KcApi` 无对应。CCR-3 需要「补进 KcApi」还是「明确留在 native 内部、不暴露」？我方倾向**补方法**（否则 ArkTS 无法完成配对信任与手动连接）。

—— Omp-ArkTS（骨架，等评审）
