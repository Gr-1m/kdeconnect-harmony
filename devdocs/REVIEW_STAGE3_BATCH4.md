# REVIEW_STAGE3_BATCH4.md — 批次 4 模块 DeviceController / DeviceActionController 接线前评审（AtomCode）

> 2026-09-26。对象：工作树未提交新文件（基线 `main@af437ad`）：
> `entry/src/main/ets/state/DeviceController.ets`（434 行）+ `entry/src/main/ets/state/DeviceActionController.ets`（271 行）。
> 范围：按 MSG111§3（CodeArts 裁决）——接线开始前先回复评审结论，评审通过后 DevEco 才开始接线。
> 方法：新模块逐方法与当前 `Index.ets`（接线前在位旧实现）对照，并对照 native 层（`cpp/net/`）核实契约承接方。

## 0. 结论：**不通过**（1×P0 + 3×P1 须先修复才能接线；3×P2 + 2×P3 随修）

P0 是**安全回归**：证书钉扎链（WP-2）在新模块中整体丢失。P1×3 是**核心流程断头 / 接线契约缺口**。
总体评价：事件分发与列表维护逻辑忠实保留旧语义（去重/防重渲染优化均在）；动作分发模块（DeviceActionController）忠实度高。
缺陷全部集中在 DeviceController 的**配对/信任域**——恰是旧注释中「真机实测 / 用户裁决 / 安全」标注最密集的区域。

## 1. P0 — 证书钉扎链整体断裂（handlePaired / handleUnpaired）

旧实现（Index.ets）的四个钉扎点：

| # | 位置 | 行为 |
|---|------|------|
| a | 805-810 | `native.getPeerCertificate(deviceId)` 取对端证书（catch 置空串降级） |
| b | 821/831 + 845-851 | certPem 写入信任条目；`native.setTrustedCertificate`（WP-2 钉扎，不符 → EACCES + 断链） |
| c | 861-865 | handleUnpaired 中 `native.removeTrustedCertificate`（解除钉扎） |
| d | 236-240 | 启动 load 后按 certPem 逐个重钉（pin rehydrate） |

native 对照（钉扎**纯 NAPI 驱动**，无自动钉扎）：
- `net_stack_link.cpp:335/465/584` — 校验只查 `trustedCertPem_` map；
- `napi_exports.cpp:470-474` — 唯一写入口是 `setTrustedCertificate` 导出；
- ⇒ ArkTS 端若从不写入，map 恒空 = **完全不做证书校验**。

新模块现状：
- `DeviceController.ets:185-220` handlePaired —— 无 getPeerCertificate、无 setTrustedCertificate，`certPem` 恒写 `''`；
  且新条目 `name: deviceId`（裸 32 位 id 当显示名，旧为 displayNameOf）、`pairedAt: Date.now()` 覆盖原配对时间；
- `DeviceController.ets:222-225` handleUnpaired —— 无 removeTrustedCertificate（只 setPairedFlag(false)）；
- 注入字段（39-58 行）中**没有任何钉扎相关入口**。

接线后影响：
1. **配对后 MITM**：配对成功后无钉扎，重连时恶意自签证书可声明对端 deviceId 通过 TLS 握手
   （`net_stack_link.cpp:647-651` 的 deviceId==CN 校验只挡「任意 CN 冒充」，挡不住「伪造对端 CN」）——WP-2 安全控制归零；
2. **certPem='' 落盘**：启动 rehydrate（d）重钉的是空串 —— 信任存储的证书字段永久失效；
3. 解除配对不解除钉扎 —— 若先修 (1) 而漏掉 remove，旧钉扎残留会导致对端重配对后无法重连（fail-closed 死锁）。

修复要求（DevEco，全部在 DeviceController 内）：
- 增加 3 个注入：`getPeerCertificate: (id) => string`、`setTrustedCertificate: (id, pem) => void`、
  `removeTrustedCertificate: (id) => void`（页面接线到对应 native 导出，try/catch 降级记日志，与旧口径一致）；
- handlePaired：name 用 `displayNameOf(deviceId)`；条目构造后经 `setPairedFlag(deviceId, true)`（见 §3-P2-1）；
  `certPem = getPeerCertificate(deviceId)` 非空则 setTrustedCertificate；
- handleUnpaired：先 removeTrustedCertificate(deviceId)，再 setPairedFlag(deviceId, false)；
- 增加 `rehydrateTrust(loaded: TrustedDevice[])` 入口（remember 同步 + 按 certPem 重钉 + flush pendingKnown，
  见 §2-P1-3），页面加载路径调用一次，替代旧 Index.ets:228-250 的逻辑。

## 2. P1 — 三个核心流程断头 / 接线契约缺口

### P1-1 requestPairWith 空转：接线后配对按钮不可用
- 新：`DeviceController.ets:271-275` —— 只算验证码 + 打日志，**没有打开确认弹窗的出口、没有请求帧发送路径**。
- 旧：`Index.ets:774-780` —— `pairSession.openPrompt(d.id, d.name, selfTs, code)`；请求帧在用户确认后由 PairSession.confirm 发出。
- 模块上也没有 pairSession.openPrompt 注入（39-58 行）——接线契约同样缺失。
- 修复：增加注入 `openPairPrompt: (id, name, ts, code) => void`，requestPairWith 内逐字调用
  （保留旧语义：弹窗打开时固定 ts 与 code，confirm 发帧用同一 ts）。

### P1-2 connected 分支丢失「连接成功」toast（违反用户 2026-09-13 裁决）
- AGENTS.md「连接/配对会话」：**任何情况都必须给 toast 反馈**：成功/失败都要提示。
- 旧：`Index.ets:950-956` —— connected 事件 + stage==='connecting' + 设备匹配 ⇒ `showNotice('connected', shownName, false)`。
- 新：`DeviceController.ets:93-112` 只调 `pairSessionOnConnected`；而 `PairSession.onConnected`
  （PairSession.ets:190-196）只做状态迁移、**不发 onNotice**（PairSession 仅 start 时发 'connecting'、
  失败时发 'pairFailed'/'connectFailed' —— 成功提示没有任何发出点）。
- 修复（二选一，须写入接线契约）：**推荐**在 PairSession.onConnected 的成功守卫内补
  `this.onNotice('connected', this.peerName, false, 0)` —— 守卫条件（191 行）与旧 950-951 逐字一致，
  且状态机已统一承担 connecting/pairFailed/connectFailed 的反馈，补上成功即闭环；
  等价替代：页面在 `pairSessionOnConnected` 接线内先判 stage/设备再 showNotice（旧逻辑原样复制）。

### P1-3 pendingKnown 无冲刷入口：早连设备永远不进记住列表
- 新：`DeviceController.ets:37-38`（字段）、`381-384`（rememberKnown 在 !trustLoaded 时排队）——字段与排队都在，**但没有冲刷方法**。
- 旧：`Index.ets:246-250` —— TrustStore.load 完成后：trustLoaded=true → 逐个 rememberKnown → 清空。
- 接线若漏：每次启动，信任加载完成前连上的设备（如 KDE 启动即拨入）将永远留在 pendingKnown，
  不进「记住的设备」（离线灰）列表。
- 修复：并入 §1 的 `rehydrateTrust` 入口（load → remember 同步 → 重钉 → flush pendingKnown → trustLoaded=true），
  页面加载路径调用一次。

## 3. P2 — 随修（不改不阻塞，接线时一并做）

1. **handlePaired 双写配对态**（违反 MSG50 §3「配对态单一写者」）：新 189-213 行在 map 内联写
   `paired: true`/新条目 `paired: true`，随后 `persistTrust`；而 `setPairedFlag`（227-252）本身就是
   单写者（负责 trusted↔remembered 同步 + 持久化 + pairedAt）。新 214-218 又整体重建 rememberedDevices + 再 persist。
   修复：条目构造只写 name/certPem（paired 保持 false 或沿用旧值），末尾统一 `setPairedFlag(deviceId, true)`，
   去掉内联的 rememberedDevices 重建（setPairedFlag 已做）。
2. **disconnected 分支清理缺项**：旧 `Index.ets:962-980` 在 disconnected 内还做
   `failInflightReceives`（接收传输落 failed）、`batteryItems` 清理、`pluginHost.unloadForDevice`（AP-4 插件卸载）、
   `mprisController.forget`（P2 MSG132 §2 媒体面板清账）、`forgetSendQueue`（P3 清发送队列）。
   新 `DeviceController.ets:114-121` 只调 `onDisconnectedCleanup` 一个注入——这些清理**若都在该回调内承接则等价**，
   但接线时必须逐项对表（旧 965-976 五处），并在回调实现处注释清账清单（与 MSG111§1 裁决的
   TeardownRegistry/「disconnected 清账清单」隐性契约对齐）。建议接线契约里显式列出这 5 项。
3. **deviceLost 分支缺 mpris 清账**：旧 `Index.ets:1000`（`mprisController.forget(lid)`，P2 MSG132 §2）
   在新 `onDeviceLostCleanup` 注入中无对应说明——同样并入清账清单对表项。

## 4. P3 — 备注（不改，记录在案）

1. **事件日志口径**：新 62 行每事件固定 `console.info`（无 debugEventLog 门控）；旧 882-887 是
   轻量摘要行 + `debugEventLog` 全量开关。轻量摘要行与旧常态口径一致，可接受；建议保留一个
   `debugEventLog` 注入/字段恢复全量开关（真机排查用）。
2. **自过滤（已核验，无需改）**：旧 `Index.ets:891` 的 `id === this.deviceId` 自过滤在新模块消失，
   但 native 双层已承接：UDP 发现侧 `net_stack_discovery.cpp:369`（`info.deviceId == config_.deviceId`
   直接丢弃，省跨线程投递）；TCP 入向侧自连在身份校验层不可能成立（自己的证书 CN 不会从对端 socket 出现，
   且 rate limit/限流兜底）。DeviceController 无需持有 selfId。**备注原因**：若未来 native 自过滤语义变动，
   ArkTS 侧无二道防线——不建议加回（避免双重维护），仅在此记录。
3. **pairingRequest 的 name 回填**：新 148-160 与旧 1012-1027 语义一致（identity 帧回填两列表），无问题。

## 5. DeviceActionController 评审结论：**通过**（2×P3 备注）

逐方法对照旧 Index.ets，忠实度高：
- `onDeviceAction`（45-119）↔ 旧 1185-1273：send_file 跳 tab、300ms 连点保护、clipboard/clipboard_request/
  find_device/run_command/media 分支语义一致；media 500ms 二次门控保留。
- `runCardAction`（121-127）↔ 旧 1151-1169：setCardBusy/clearCardBusy 注入化，「弹窗类不立即释放」语义保留。
- `manualConnect`（129-141）↔ 旧 1085-1097：host/port 校验逐字一致；`pairSessionStart` 注入替代
  `pairSession.start`（接线后 toast 由 PairSession.start 的 'connecting' onNotice 覆盖，符合「成功/失败都要提示」）。
- `unpairDevice` 在 DeviceController 侧（277-289）↔ 旧 1070-1082：发帧 + handleUnpaired + forgetPeer 三步一致
  （「不主动断链」裁决保留 ✓）。
- `pickAndSendFile`/`stageSendJob`（200-270）：文件复制进沙箱 + 批量 seq 命名与旧实现一致；9 文件上限保留。

P3 备注：
1. `runCommand`（143-156）用 `getSelectedDeviceId()` 而旧 1277 用 `this.runCommandDeviceId`（弹窗打开时记录的设备）。
   二者在正常流中相等（弹窗只对选中设备打开），但若用户打开弹窗后切换了选中设备再点命令，新实现会发往**错误的设备**。
   建议：`setRunCommandState(deviceId, ...)` 注入本就带 deviceId，弹窗侧记住该 id、runCommand 优先用它。
2. `openDeviceDetail`（167-177）：旧实现点行即回功能页 + 选中；新实现多了一个 `!online` 拦截 toast
   （`device_offline`）。语义增强（发现页离线行不可点详情），需确认 UI 上离线行的点击预期——若发现页离线行
   本就不响应点击则无碍，建议接线时确认一次。

## 6. 接线前门禁建议（请总指挥裁决）

1. P0 + P1×3 修复并 review 通过后 DevEco 方可开始接线（与 MSG111§3 门禁一致）；
2. 接线契约文件建议显式列出：(a) 3 个钉扎注入 + openPairPrompt 注入 + rehydrateTrust 调用点；
   (b) onDisconnectedCleanup / onDeviceLostCleanup 的清账清单 5+1 项（§3-2/3）；(c) 连接成功 toast 的
   承接方（§2-P1-2 二选一）；
3. 修复后跑 `hvigorw assembleHap`（libxml2 shim 环境）+ `cpp/tests/run.sh`，ohemu 冒烟验证配对全流程
   （配对 → 重启 → 重连证书校验 → 解除配对）——P0 项的回归验证必须在真流程上做，单测无法覆盖 NAPI 钉扎链。
