# REVIEW_STAGE3_BATCH2.md — 阶段 3 批次 2 全量评审：MprisController / PayloadController / 两 Dialog / Index 接线

> 2026-09-26。评审人 Atomcode（用户指令：全量评审接线改动）。对象：工作树未提交改动——4 新文件（MprisController 332 + PayloadController 564 + MprisDialog 348 + ReceivedFilesDialog 107 = 1351 行）+ Index.ets diff（−917/+77，2598→1681 行）+ FilesTab.ets（@Link→@Prop）。
> **总体结论：通过（静态评审层面）。无 P0/P1。2×P3 + 1×注记。提交前仍差 Omp 的构建 + ohemu 冒烟（运行时验证，我方静态评审不替代）。**

## 一、MprisController（332 行）——通过

- 24 方法迁入（状态镜像 10 / 系统音量 6 / 面板读数 6 / 生命周期 2 / 控制动作 9 分组注释清晰）；注入 5 点（log/toast/resText/actionGate/pluginsFor）方向正确——Controller 零 I/O、零 UIContext；
- **不变量在位**：①`isPanelFor` 前后台分离门控（setList/setSnapshot 双处，注释带「对端周期推送整页重渲染」的实测背书）；③`svDeviceId === deviceId` 单槽过滤（svSinksForCurrent）；②进度插值时钟确认留在 MprisProgress 组件局部 @State（Dialog 内子组件使用，5 参数 + onSeek 回调，ticker 未退回页面级）；
- `forget()`（断链丢镜像+关面板）语义完整，Index 两处调用点（disconnected 1046 / lost 1073）已接。

## 二、MprisDialog（348 行）——通过

- `@ObjectLink mpris` + `@Prop deviceName`，所有动作直调 Controller 方法（无中间转发层）；
- **4 条行为保持要点全部保留且有注释**：弹层实底色（dialog_bg，无毛玻璃）、卡片空点击消费（防遮罩误关）、Slider Begin 门控（volDragging 状态机防程序性回调误发包）、不 @Builder 传值；
- **一处有意的行为修正（注记）**：页脚「刷新/关闭」从「媒体」tab 内提到两 tab 共用——旧实现在设备 tab 无关闭入口，代码注释已声明修正依据。这是**改进了旧 bug 而非保持旧行为**，方向正确，真机回归时顺带确认设备 tab 可关；
- 遮罩 `.onClick(close)` + 卡片 `.onClick(空)` 组合与 PairConfirmDialog 裁决语义一致（媒体面板非安全门，卡外可关合理）。

## 三、PayloadController（564 行）——通过，1×P3

- 27 方法 + SendJob；注入 10 点（log/toast/resText/hostFilesDir/pickSaveTarget/pickDownloadTarget/requestWritePermission/persistHistory/clearPersistedHistory/connectedDeviceIds）；
- **不变量 4 条全在位**：①队列只由 `onSendPayloadSettled`（终态）驱动推进，无 sleep；②`tid <= 0` 不建条目（L124，含「declared but not started」日志）；③`sanitizeFileName` 单一来源（转调 PayloadHistory.safeFileName）；④`failInflightReceives` 终态兜底（map 重建 + 仅 receive + 仅 active 态）；
- `pumpSendQueue` 的在线校验（`connectedDeviceIds().some(...)` 不在线即 `forgetSendQueue` 全清）保留；发送失败递归 pump（shift 后继续）保留；
- native 直接 import（L11 注释说明 NAPI 不需 Context）——与旧 Index 同款调用，行为保持；
- **P3-1：564 行超 400 阈值（MSG35 建议线）**，发送队列 4 方法 + 6 字段（sendQueue/sendBusyId/sendInflightJob/sendTarget/sendOkCount/sendTotal）内聚独立，建议拆 `state/PayloadSendQueue.ets`（Controller 持实例）。**不阻塞本批提交**，可批后做或随批次 4。

## 四、ReceivedFilesDialog（107 行）——通过

- `@ObjectLink payload`，ForEach 键 `recv_${transferId}` 稳定；只读 + 回调（clearReceivedHistory/fmtBytes/payloadStateText 直调 Controller）；弹层底色/遮罩/卡片消费点击三件套保留。

## 五、Index 接线 diff——通过（四重点全核）

### 5.1 旧代码清零
- 旧 6 个 MPRIS @State 字段（mprisItems/mprisDeviceId/mprisDialogOpen/mprisTab/svSinks/svDeviceId）：**0 残留**；
- 旧 10 个 payload @State/队列字段：**0 残留**（`sendTargetDevice` 方法名误报排除）；
- 旧 21 个 MPRIS 方法 + 17 个 payload 方法：diff 全删除，Index 内旧名调用 **0 残留**（唯一命中 `svPrepare:1` = `this.mprisController.svPrepare()` 合法新调用）；
- 旧两弹窗内联体特征串（media_dialog_title / files_received_dialog_title 等）：**0 残留**。

### 5.2 注入装配
- MprisController 5 点（432-437）+ PayloadController 10 点（438-448）逐条核过，全部转调页面既有实现（notify.log/notify.toast/notify.resText/actionGate/pluginHost.pluginsFor/ensureKdcDir/pickSaveTarget/pickDownloadTarget/ensureWritePermission/persistPayloadHistory/clearPayloadHistory/connectedDevices 映射）；
- 装配自检 `plugin routes registered: 7` 保留（449 起）。

### 5.3 生命周期成对
- aboutToAppear(192) / aboutToDisappear(514)；netWatcher.register(454) / unregister(515)；router 构建(338)。成对无泄漏。

### 5.4 事件转发（新接线核心）
- `onMprisPlayerList/Update`（766-774）→ controller.setList/setSnapshot；
- `onSystemVolumeSinks`（779-784）：写侧单槽过滤 `deviceId !== mprisController.deviceId` 前置 + `svSinks`/`svDeviceId` 双写——与旧语义逐字一致；
- payload 事件（1103）→ handlePayloadTransfer；**disconnected 双动作**（1038 failInflightReceives + 1049 forgetSendQueue）+ MPRIS 镜像清理（1046 forget）；error 事件（1112）→ failInflightReceives 兜底——三条断开/错误路径全接。

### 5.5 不变量 8 条逐项（PLAYBOOK §三）
| # | 不变量 | 结果 |
|---|---|---|
| 1 | paired 单写者 setPairedFlag | ✅ 8 调用点，无内联 `paired: true`（906/1775/1808 的 `paired: false` 均为**新建条目初值**，非配对态改写） |
| 2 | 配对三信号终局 | ✅ PairSession 本批零改动（工作树未触及） |
| 3 | sinks 单槽过滤 | ✅ 读侧（controller.svSinksForCurrent）+ 写侧（Index 779）双在位 |
| 4 | MPRIS canClaim | ✅ 留插件层（MprisPlugin:314），本批未动 |
| 5 | payload 终态驱动队列 | ✅ onSendPayloadSettled 唯一推进点，无 sleep |
| 6 | size>0∧tid==0 不建条目 | ✅ L124 |
| 7 | 验证码与请求帧同一 ts | ✅ 本侧发起（852）openPrompt 与 computePairCode 同一 selfTs；对端请求（323）同一 ts |
| 8 | 弹层实底色 | ✅ 两新 Dialog dialog_bg/dialog_mask 抽查通过 |

## 六、FilesTab @Link→@Prop 变更——安全（专项核过）

- **进度行刷新链路**：`payloads` 在 Controller 内一律**整数组重赋值**（handlePayloadTransfer L145/147、failInflightReceives L114、markPayloadSettled L240、clearReceivedHistory L201）⇒ @Observed 顶层属性变更驱动 ⇒ FilesTab 的 `@Prop payloads` 同步 ⇒ ForEach 重渲染。**与旧机制（@State 整数组重赋值→@Link 同步）同构**，非降级；
- @Prop 是拷贝，写回会丢失——已核 FilesTab **只读**（3 处 `this.payloads.filter` 均为值读，无赋值/push/splice）⇒ 变更安全；
- 若未来 FilesTab 需要就地增删行，必须改回 @Link 或上提到 Controller 回调——已在坑册层面记录于本评审。

## 七、参数级保真比对（old/new 调用实参多重集）

- 旧侧 109 个 `this.*` 调用点 → 新侧（Index + 4 新文件）39 个（余下为 Dialog 内 `mpris.*`/`payload.*` 调用点，已逐一核过无丢失）；
- LOST/NEW 差值**全部由预期重命名解释**，零真实丢失：
  - 字段重命名：`this.mprisDeviceId` → `this.deviceId`（controller 内，15 处成对）；
  - 方法短化（**与设计文档命名不符，见 P3-2**）：`mprisSnap→snapshot`(17)、`mprisPluginOf→mprisPluginOf` 不变、`mediaAction→action`、`mprisItemOf→itemOf`、`mprisEmpty→isEmpty`、`mprisVol→vol`、`setMprisList→setList`、`setMprisSnapshot→setSnapshot`、`putMpris→put`、`mprisList→playerList`、`toPayloadState→toState`、`toPayloadDirection→toDirection`、`closeMprisDialog→close`、`forgetMpris→forget`、`isMprisPanelFor→isPanelFor`；
  - 未映射的旧调用（actionGate/ensureKdcDir/ensureWritePermission/getUIContext/displayNameOf）全部为**留页面方法**，调用点仍有效。

## 八、P3 ×2 + 注记 ×1

1. **P3-1**：PayloadController 564 行超阈值——建议发送队列拆 `PayloadSendQueue.ets`（不阻塞本批）；
2. **P3-2**：**方法名短化偏离设计文档**（DESIGN_BATCH2_deveco.md 列 23 长名，实现用 24 短名）——改动本身一致且已全量验证，但设计文档与实际实现不符会误导后续批次参照。请 DevEco 更新 DESIGN 文档或在其中加「最终命名以代码为准」注记；
3. **注记**：MprisDialog 页脚两 tab 共用 = 有意修正旧 bug（设备 tab 原无关闭入口），方向正确，真机回归顺带确认。

## 九、提交前置条件（未满足，Omp 执行）

1. `assembleHap` BUILD SUCCESSFUL（本批**尚无构建证据**——我方评审纯静态）；
2. ohemu 冒烟（首屏截图一致 + `plugin routes registered: 7` + native start ok + 无 SyntaxError）；
3. 本评审回执无 P0/P1 ✅（本报告）。

—— Atomcode（glm5.3-flash），评审工作负责人
