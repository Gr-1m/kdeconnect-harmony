# 08 双代理接口契约（冻结版 v1，两车道共同实现目标）

> 上游：`00-README.md`。本文是 **ArkTS 车道与 Rust 车道的唯一共享接口规范**。任何一条与其冲突的旧描述（02 §3 草案、06 §3 示例）以本文为准。
> 冻结含义：签名、事件形状、错误码、能力集、自动接受时限、JSON 载荷字段名在 v1 内**不得字段级改动**；改动只能走 §9 的 CCR 流程。
> 本文中的 `kcbridge.d.ts`、`capabilities.v1.json`、`errors.v1.json` 是「以文档形式存放的规范工件」——M0 时逐字拷入 `oh-kdeconnect/contract/`，之后以文件为准并回链本文。

## 1. 设计原则

1. **薄 NATIVE 厚 ArkTS**：Rust 只做协议/网络/TLS/SFTP/payload 传输；一切系统 Kit、UI、持久化在 ArkTS。
2. **窄腰 JSON**：跨边界结构化数据一律 `json: string`。Rust 侧 serde 强类型校验（引擎内部信任的边界校验点），ArkTS 侧用 06 §4.2 的 decoder 模式解析。体积小（事件 KB 级、进度事件限频），换绑定框架无关性与双车道同构测试。
3. **命令立即返回，结果走事件**：所有命令函数非阻塞（入队即返回），异步结果（配对成败、传输成败）只经 `event` 回调上抛。**v1 无 Promise 返回值**。
4. **每进程单实例**：`kcStart` 二次调用报 `E103`；`kcStop` 幂等。
5. **同源单注册表**：`capabilities.v1.json` 是「我们宣告/接受哪些包类型」的唯一事实源；RUTST 侧 `include_str!` + 测试比对，ArkTS 侧 `PluginDecl[]` 测试比对。
6. **字面量约定**：调用方 bug 抛错（E1xx）；运行时协议事件（对端行为/网络）不抛错、走事件内 `code` 字段。

## 2. 命令 API（kcbridge.d.ts，权威）

```typescript
// contract/kcbridge.d.ts —— ArkTS 侧 import { libkcbridge } from 'libkcbridge.so'
export interface KCError extends Error {        // 抛出形态：message 必含 "KC_E<code>: " 前缀
  code: number;                                  // 见 §4 错误码表
}

export interface KcApi {
  contractVersion(): number;                     // 生成期常量；启动时比对，不等即 E109

  /** 首次运行生成身份。返回 {deviceId, certPem, keyPkcs8Base64}。同步返回（<100ms，仅首启） */
  generateIdentity(deviceName: string): string;

  /** 启动引擎。engineStarted 或 engineInitFailed 事件回报结果 */
  start(configJson: string): void;
  stop(): void;                                  // 幂等；停止后不再发事件（engineStopped 是最后一个）

  setOnEvent(cb: (kind: number, eventJson: string) => void): void;   // kcStart 前注册

  /** 网络快照变化时推送（ArkTS 观察 connectionKit；引擎不枚举网卡）。
      json: {ifaces:[{addr, prefix}], trusted: boolean, ssid?: string} */
  networkChanged(networkJson: string): void;
  refreshDiscovery(): void;                      // 前台返回/手动刷新：重发 UDP 广播

  requestPair(deviceId: string): void;           // 06 §2.4 行1；结果见 pairResult
  acceptPair(deviceId: string): void;
  rejectPair(deviceId: string): void;
  unpair(deviceId: string): void;
  setDeviceName(name: string): void;             // 过滤与长度规则在引擎内（01 §4）

  sendPacket(deviceId: string, type: string, bodyJson: string): void;
  /** 发文件。size 取自文件 stat；返回值无（transferStarted 事件带 transferId） */
  sendFile(deviceId: string, type: string, bodyJson: string,
           filePath: string, filename: string): void;
  /** 收到 transferOffer 后响应（时限 §5.3）；destPath 必须位于配置的 allowedRoots 下 */
  acceptTransfer(transferId: number, destPath: string): void;
  rejectTransfer(transferId: number): void;
  cancelTransfer(transferId: number): void;

  /** SFTP（Phase 3）：暴露给桌面的目录（沙箱绝对路径）。roots 为空 = 不响应 startBrowsing */
  setSftpRoots(roots: string): void;             // json: {roots: string[]}
  setAutoAcceptSec(sec: number): void;           // transferOffer 自动接受时限，默认 10s
}
```

调用序规则：`setOnEvent` -> `kcStart` ->（任意）-> `kcStop`。未 `kcStart` 调用其他命令 -> `E102`。`setOnEvent` 只允许调用一次（`E101`）。

## 3. 事件（kind 判别 + JSON 载荷）

kind 用 number（避免跨端字符串枚举漂移）；载荷字段名与 Rust serde `#[serde(rename_all="camelCase")]` 一致。

| kind | 事件 | 载荷（JSON） | 语义/备注 |
|---|---|---|---|
| 0 | engineStarted | `{version, tcpPort}` | start 成功；version=contractVersion |
| 1 | engineInitFailed | `{code}` | start 失败（含身份校验失败 `E502` -> ArkTS 走重生成流程，见 §6） |
| 2 | engineStopped | `{code}` | 正常或异常停止后恰好发一次 |
| 3 | deviceVisible | `{info: DeviceInfoDto}` | 新对端 TLS 链路建立（证已捕获/校验） |
| 4 | deviceGone | `{deviceId, reason}` | reason: `linkLost`/`pairTimeout`；对齐 Android 1s 删除语义 |
| 5 | deviceUpdated | `{info: DeviceInfoDto}` | 配对成功或身份字段变化 -> **ArkTS 持久化写回的唯一触发**（02 §3） |
| 6 | unpaired | `{deviceId, reason}` | reason: `user`/`peer`/`timeout`/`clockSkew`/`certReplaced` |
| 7 | pairRequest | `{deviceId, verificationKey, name}` | 收到配对请求（key 已由引擎算好，SAS） |
| 8 | pairResult | `{deviceId, ok, code, verificationKey?}` | 发起方收结果；ok=true 附 key（双端比对） |
| 9 | packet | `{deviceId, type, body}` | 配对设备的业务包；非协议包未配对一律不上抛（01 §3） |
| 10 | transferStarted | `{transferId, deviceId, size}` | 发送方向（sendFile 后） |
| 11 | transferOffer | `{transferId, deviceId, type, size, filename}` | 接收方向；超时策略 §5.3 |
| 12 | transferProgress | `{transferId, bytes, total}` | 双向；≥512KiB 或 ≥500ms 一报 |
| 13 | transferDone | `{transferId, ok, code?, path?}` | ok=true 时 path=落盘文件 |
| 14 | log | `{level, msg}` | level: 0=debug..3=error；release 强制 ≥1（04 §5） |

`DeviceInfoDto = {deviceId, name, type, protocolVersion, incoming:[], outgoing:[], certificatePem?}`（certificatePem 仅在 deviceVisible/deviceUpdated 出现）。`type` ∈ `phone|tablet|desktop|laptop|tv`。

排序保证：同一 deviceId 的事件按因果序投递；全局不保证跨设备顺序。事件在调用 `kcStart` 的线程回调（napi ThreadsafeFunction post 回注册线程；ArkTS 侧 reducer 只做轻量更新，重活 taskpool）。

## 4. 错误码（errors.v1.json 的表格形态）

| 码 | 名 | 抛出/事件 | 含义 |
|---|---|---|---|
| 101 | NOT_READY | 抛 | setOnEvent 二次注册 / 调用序违例 |
| 102 | NOT_STARTED | 抛 | start 前调命令 |
| 103 | ALREADY_STARTED | 抛 | 重复 start |
| 104 | BAD_JSON | 抛 | configJson/bodyJson 非法（含未知字段不报错——前向兼容） |
| 105 | BAD_PARAM | 抛 | 参数域错（超长名、非法 deviceId 等） |
| 109 | CONTRACT_MISMATCH | 抛 | contractVersion 不等 |
| 201 | CERT_MISMATCH | 事件 | 已配对设备证书不符（FatalLink，04 T4） |
| 202 | PROTOCOL_VIOLATION | 事件 | 明文阶段校验失败（targetDeviceId 等） |
| 203 | LINE_TOO_LONG | 事件 | 分帧超限（01 §5） |
| 204 | IDENTITY_INVALID | 事件 | deviceId 正则/名字过滤不过 |
| 205 | CLOCK_SKEW | 事件 | 配对时间戳超 1800s（unpaired reason） |
| 301 | PEER_NOT_CONNECTED | 事件 | 发起方 30s 无响应（pairResult/unpaired） |
| 302 | OFFER_TIMEOUT | 事件 | transferOffer 超时自动拒绝 |
| 303 | TRANSFER_CANCELLED | 事件 | 主动取消 |
| 401 | PAYLOAD_TIMEOUT | 事件 | 发送方监听端口 30s 无人连（01 §3） |
| 402 | FILE_IO | 事件 | 本地文件读写失败 |
| 403 | SEND_FAILED | 事件 | 发包失败（链路断/对端 incoming 不含该 type） |
| 501 | ENGINE_PANIC | 事件 | 引擎 panic 被捕获（06 §3.1） |
| 502 | IDENTITY_INVALID_ON_START | 事件 | 证书过期/不匹配 -> 触发重生成流程 §6 |
| 503 | INIT_FAILED | 事件 | 端口绑定等启动失败 |

E2xx 映射 `Disposition::FatalLink`，E3xx 映射 DropPacket/超时类，E4xx 映射 Infra——与 06 §2.2 分级一一对应（新增码必须同时登记 disposition）。

## 5. 关键时序

### 5.1 启动/首次身份

```mermaid
sequenceDiagram
  participant A as ArkTS 车道
  participant E as Rust 引擎
  A->>A: loadIdentity (Asset: 私钥 DER; filesDir: certPem; Prefs: deviceId)
  alt 首次
    A->>E: generateIdentity(deviceName)
    E-->>A: {deviceId, certPem, keyPkcs8Base64}
    A->>A: 存 Asset/filesDir/Prefs
  end
  A->>E: setOnEvent / start(config)
  E-->>A: engineStarted 或 engineInitFailed(E502)
  Note over A: E502 -> 走重生成（等同首次）+ 清空配对表（01 §5）
```

### 5.2 入向文件（share.request 带 payload）

引擎收包 -> `packet{type:'kdeconnect.share.request', body}` 与 `transferOffer{filename}`（同 deviceId 保序）-> ArkTS 规则化文件名（basename、拒 `..`、限长）-> `acceptTransfer(destPath)`（destPath 必须在 config.allowedRoots 下，引擎强制）-> `transferProgress`* -> `transferDone{ok, path}`。超时未响应（默认 10s，可 `setAutoAcceptSec`）自动 `rejectTransfer(E302)`；发送侧 `PAYLOAD_TIMEOUT(E401)` 兜底（01 §3）。

### 5.3 出向文件

`sendFile` -> 引擎 stat 得 size、开 1739-1764 顺序探测监听、发 header 包（`payloadTransferInfo:{port}`）-> `transferStarted` -> 对端连入（30s 超时 E401）-> progress -> `transferDone`。**同一设备同时只允许一个在途 payload 发送**（后续 sendFile 排队，FIFO；对齐桌面单端口串行语义，01 §6 上传实现）。

## 6. 证书自检与重生成

`start` 内引擎校验：cert CN == deviceId、当前时间在有效窗、cert/key 匹配、deviceId 匹配 `^[a-zA-Z0-9_-]{32,38}$`。失败 -> `engineInitFailed(E502)`，ArkTS 侧流程 = generateIdentity + 清空 Asset/档案 + 重 start（语义对齐 01 §5「重生成即全解配对」，由 ArkTS 执行删除，引擎不写持久化）。生成参数对齐 01 §4；签名算法例外见 09 §互作坑清单。

## 7. 引擎内部形态（Rust 车道的结构约束）

- **kc-bridge 是薄壳**：NAPI 参数 -> serde 反序列化 -> `kc-engine` 公共 API；事件 `sync mpsc` -> 线程转发 loop -> ThreadsafeFunction。桥内无业务状态。
- **kc-engine 公共 API 与 §2 一一对应**（`start(cfg, sink)/network_changed/...`，sink = `SyncSender<(kind, json)>`），**可在 host 全量驱动**（M0 后 Rust 车道先用 host 直测引擎，不依赖 NAPI）。
- **并发模型**：单 `EngineActor` 拥有设备表/配对状态/限额表（唯一写者）；每链路一对 task（读循环 + 单写者队列——06 §2.4 教学不变式的运行时落地）；发现/连接器/每传输/SFTP 各自 task；task 间只经 channel。信任快照（deviceId->cert）由 actor 发布 `Arc` 只读快照给 TLS verifier（P3 唯一持有者的例外，写者仍唯一）。
- **链路替换**：同 deviceId 新链路替换旧链路，证书必须相同（01 §2）。

## 8. ArkTS 车道独立开发支撑（Mock 与黄金场景）

**MockKcEngine**（ArkTS 车道所有，实现 `KcApi`）按「场景脚本」驱动 UI/适配层，Rust 未就绪即可开工：

```json
// contract/scenarios/pairing-in.json —— 步骤 = {do: call} 或 {emit: event}
{ "name": "pairing-in",
  "steps": [
    {"do": ["start", null]},
    {"emit": [0, "{\"version\":1,\"tcpPort\":1716}"]},
    {"emit": [3, "{\"info\":{\"deviceId\":\"b2...\",\"name\":\"Work PC\",\"type\":\"desktop\",\"protocolVersion\":8,\"incoming\":[],\"outgoing\":[],\"certificatePem\":\"...\"}}"]},
    {"emit": [7, "{\"deviceId\":\"b2...\",\"verificationKey\":\"A82E8F8A\",\"name\":\"Work PC\"}"]},
    {"expectCall": ["acceptPair", "b2..."]},
    {"emit": [5, "{\"info\":{\"deviceId\":\"b2...\",\"name\":\"Work PC\",\"pairState\":\"Paired\",\"certificatePem\":\"...\"}}"]},
    {"emit": [9, "{\"deviceId\":\"b2...\",\"type\":\"kdeconnect.ping\",\"body\":\"{}\"}"]}
  ] }
```

**双车道同构**：Rust 车道的 host 引擎测试以相同 `steps` 驱动真引擎（`do` 变成真实调用，`emit` 变成「引擎必须产生该事件」断言，`expectCall` 变成注入），ArkTS 车道 Mock 回放 `emit` 并断言 `expectCall`。**同一份场景文件约束两侧**——这是双代理不漂移的机制保障，M1 起场景目录逐步扩到 09 §联调剧本全集。

## 9. 变更控制（CCR）与版本

- `contractVersion = 1`。任何契约改动（含事件加 kind、错误码追加——均为向后兼容类）必须：提 CCR（`contract/CCR-<n>.md`：动机/两车道影响/diff）-> **两车道各自确认 + 用户批准** -> 同一提交内改 `kcbridge.d.ts`/`errors.v1.json`/`capabilities.v1.json`/受影响场景文件 -> 版本 +1 -> 两侧实现与测试同步更新。
- 兼容性规则：ArkTS 对未知 kind/未知码必须忽略并 log（事件前向兼容）；删除字段/改语义必须升大版本并双端同步切换。
- 工件清单（M0 落位）：`contract/kcbridge.d.ts`（§2 逐字）、`contract/errors.v1.json`（§4 机读）、`contract/capabilities.v1.json`（§10）、`contract/scenarios/*.json`（§8 起步集）、`contract/CCR-*.md`。

## 10. capabilities.v1.json（冻结能力集）

依据 01 §6 已核实的 Android 端收/发类型清单（OH 端角色相同）：

| 插件 key | incoming | outgoing | 默认开 |
|---|---|---|---|
| ping | kdeconnect.ping | kdeconnect.ping | true |
| mousepad（触控板+键盘） | kdeconnect.mousepad.keyboardstate | kdeconnect.mousepad.request | true |
| presenter | — | kdeconnect.presenter, kdeconnect.mousepad.request | true |
| mpris | kdeconnect.mpris | kdeconnect.mpris.request | true |
| systemvolume | kdeconnect.systemvolume | kdeconnect.systemvolume.request | true |
| runcommand | kdeconnect.runcommand | kdeconnect.runcommand.request | true |
| share | kdeconnect.share.request, kdeconnect.share.request.update | kdeconnect.share.request | true |
| findmyphone（桌面响铃 OH） | kdeconnect.findmyphone.request | — | true |
| findremotedevice（OH 响铃桌面） | — | kdeconnect.findmyphone.request | true |
| clipboard | kdeconnect.clipboard, kdeconnect.clipboard.connect | 同 incoming | true |
| receivenotifications（桌面通知显示） | kdeconnect.notification | kdeconnect.notification.request | true |
| battery（见 G6） | kdeconnect.battery | kdeconnect.battery | false |
| connectivityreport（见 G6） | — | kdeconnect.connectivity_report | false |
| sftp（Phase 3） | kdeconnect.sftp.request | kdeconnect.sftp | false |

identity 上线类型 = `outgoing` 全集；下线类型 = `incoming` 全集（对齐 01 §4 能力协商；G6 结果通过改此文件 + 重建生效，两车道同步）。battery/connectivityreport 默认 `false`，G6 通过后翻 `true`。

## 11. 明确不进 v1 契约的事

fd 过桥（v1 仅沙箱路径 + ArkTS 预拷贝——成本与收益见 09 §路线图）、mDNS、蓝牙后端、`kdeconnect.clipboard.file`、通知 reply/action 回传（桌面 sendnotifications 只收 `notification.request`，不支持 reply 方向——02 §7 已勘误）、contacts、sms/telephony、virtualmonitor。
