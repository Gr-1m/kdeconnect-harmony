# REFACTOR_NOTES_deveco — DevEco 侧 ArkTS 重构说明（分支 `refactor/arkts-deveco`）

> 2026-09-19。按 `AgentsConversion/ARKTS_REFACTOR_BRANCHES.md` §3 要求留档：**动机 / 删掉了什么 / 改了哪些结构 / 验证到什么程度**。
> 基线 `1ecdb78`；范围 `entry/src/main/ets/**` + `entry/src/main/resources/*/element/**`（**未碰 `cpp/**`**）。

## 1. 本轮动机（来自评审，不是自选）

- 用户判断「Bug 多」+ 评审 `REVIEW_ARKTS_FULL.md` 的三个结构性根因：
  ①`Index.ets` 过大（会话状态机 + 插件事件总线 + 8 业务域状态 + 全部 UI 混一处）；
  ②插件层"自造状态机"（未先抄上游协议状态机再适配）；
  ③UI 状态装饰器半套用（`@Prop`/`@ObjectLink` 分批试错补齐）。
- 我的落点：**先在"结构边界"上把这几类问题的样本改干净**（用可复制到其它模块的范式），再做立即批 bug 修复。

## 2. 改掉的结构（范式，可被其它模块照抄）

| 主题 | 之前 | 之后 |
|---|---|---|
| **系统音量数据流** | 插件缓存 + 页面 `@State` 两份真相，靠 `syncSysVolume()` 拉取补丁；`"<vol>\|<muted>"` 自造字符串通道；全局单例 `maxVolume`（做不了多 sink） | **单一数据源**（每 sink 各自刻度）+ **单一派生**（`syncRows()` 唯一换算点）+ **单一通道**（`PluginEvent.svSinks` 推整份行数组，幂等） |
| **列表行刷新** | `ForEach` + 标量 `@Prop` ⇒ 键不变→子组件不重建→**值冻结在首帧**（实测症状：点静音对端有效果、按钮文案不变） | `@Observed class SystemSinkUi` + 行组件 `@ObjectLink`；**实例稳定**（同名复用、字段原地更新），仅成员变化才换数组引用 ⇒ 只重建该行 |
| **多 sink 选择** | 无（只有一个隐式"主输出"） | 对齐 Android：`Radio` 单选钮（互斥）+ `{name, enabled:true}` 单独发包；默认标记**只认协议 `enabled`**（删除平行状态 `defaultName`） |
| **日志状态** | 页面级 `@State logText` ⇒ 每次合并刷新**整页重建** | `common/LogStore.ets`（`@Observed`）+ `LogsTab` 用 `@ObjectLink` ⇒ 只重建日志组件 |
| **多选发送** | 单文件、`connectedDevices[0]` 发错人（实测：选 win10dev 却发到 cachyos） | `maxSelectNumber:9`；`sendTargetDevice()`（选中设备优先/唯一在线才自动/否则提示不猜）；**事件驱动串行队列**（上一个终态事件才发下一个，替代固定 sleep） |
| **状态文案** | 完成态不分方向；进行中把"发送中"写成"接收中" | 按方向区分：发送=**已发送**/接收=已保存（已处置）或已完成；进行中=发送中/接收中 |

## 3. 删掉了什么（净减，避免"补丁叠补丁"）

- 自造字符串通道 `"<vol>|<muted>"` + `?` 哨兵 + UI 侧 `split('|')` 解包；
- `hasData()/volume()/isMuted()` 三个"给页面抄状态"的 getter 与页面 `syncSysVolume()` 拉取路径；
- 平行状态 `defaultName`（默认输出只认协议 `enabled`）；
- 取证日志 `push sinks [...]` / `increment overwrites muted` 及其支撑代码 `uiSig()/lastPushSig`（问题已修；经 CodeArts MSG22 §1 确认**不恢复**）；
- 批2 死代码 9 个符号 + 5 处调用点（`mprisNowMs`/`mprisTickerId`/`startMprisTicker`/`stopMprisTicker`/`mprisPos`/`mprisPosPermille`/`mprisPermilleToMs`/`mprisMaxPos`/`mprisSeekDragging`）；
- 页面级 `clearLog()` 与 `LogsTab.onClearLogs` 纯转发层；
- 未再被引用的字符串 `sys_default_sink` / `sys_set_default`；
- **code=110 重试机制**（含 `attempt` 字段与 superseded 机制）—— 按 Omp MSG29 §4-B / CodeArts MSG22 §3 **暂撤**（真因未定位前重试会掩盖问题），注释里留了恢复条件。

## 4. Bug 修复（立即批 + 用户实测项）

| 来源 | 修复 |
|---|---|
| 用户实测 | **发错设备**：`connectedDevices[0]` → `sendTargetDevice()`（选中优先；多台且未选则不猜、给 toast），并打 `send file target:` 日志 |
| 用户实测 | 静音按钮 UI 不刷新（`ForEach`+标量 `@Prop` 冻结）→ `@ObjectLink` 方案（见 §2） |
| 用户指定 | 历史/详情状态文案按方向区分（见 §2） |
| 用户裁决 | 重试不留痕（superseded 行不入列表/历史）—— **随重试一起暂撤** |
| AtomCode L-P1-1 | **剪贴板回环死循环**：新增 `lastReceivedContent`，`sendClipboard()` 遇同内容即抑制（对齐 Android `lastContents`；返回 true = 已处理，不弹失败提示） |
| AtomCode L-P1-2 | **`acceptPair` 失败仍标已配对**：改为仅在接受帧真的发出（`ok`）时 `onPaired`，否则打日志说明不标记 |
| AtomCode U-P1-1 | **锁竖屏实验开关未回收**（`EntryAbility` 里排查 THREAD_BLOCK_6S 时改成 `false` 忘还原）→ 恢复 `true`（手机锁竖屏/大屏跟系统） |
| AtomCode L-P2-2（安全） | **`requestedPeers` 无超时** ⇒ 一次用户确认整会话有效、之后可跳过确认自动接受 → 改 `Map<deviceId, 时刻>` + **120s 有效期** + 过期清理 |

## 5. 验证到什么程度（如实）

- **构建**：`devecocli build` = BUILD SUCCESSFUL（每次改动后都跑；Win10 侧等价于 `assembleHap`）。
- **真机验证（MatePad Mini `5KPBB25901205531`，对端 KDE 在线）**：
  - 系统音量：设备 tab **两行真实 sink**（analog 62% / HDMI 85%）、单选钮可选默认输出、静音按钮文案即时翻转且**逐行隔离**、首帧即有读数（旧 bug 消失）；
  - 多选发送：3 文件发送**当时 3/3 成功**（带重试兜底时）；`已发送`/`已保存` 文案正确；
  - 卡片忙碌态、共用页脚（设备 tab 也能关面板）等回归正常。
- **尚未验证**（本轮新增/撤回，需后续补）：
  1. 剪贴板回环抑制（需双端各复制一次观察是否互刷）；
  2. `acceptPair` 失败路径（需构造未加密链路/发送失败）；
  3. 配对确认 120s 窗口（需等窗口过期后再让对端请求，确认**不再**自动接受）；
  4. 重试暂撤后的多选发送表现（预期：会如实出现 `失败` 行）；
  5. **连续 payload `code=110`**：等 Omp 阶段诊断数据（复跑抓 `send listen: port=` / `send accepted:` / `timeout stage:`）。

## 6. 未做的（下一轮候选，均出自评审）

- **S6：`Index.ets` 拆分**（结构性根因①，评审列为"必要"）—— 本轮**未动**，避免与另两份重构副本产生大范围冲突；建议三方对比后再统一拆法；
- L-P2-5/6（音量乐观更新不回滚、增量未知 sink 的注释与实现矛盾）、U-P2-1（`avoidAreaChange` 监听）、U-P2-2（`PayloadRow` 按钮冒泡）、U-P2-3（手动连接输入校验）、U-P2-4（`Radio` 程序化回环）—— 归"结构批"；
- L-P2-1/3（`clock-skew` 不回拒绝帧、`frameBuffers` 无上限）、L-P2-10（`PayloadHistory` 串行化）—— 归结构批。

## 7. 提交状态

Win10 侧**无 `.git`（Syncthing 只同步文件）** ⇒ 本副本的改动**无法自行 commit**，需 Omp 按惯例代为提交（或 CodeArts 授权）。在途文件见 MSG42 类回报中的清单。

## 8. 结构批（第二批，2026-09-19 完成）

出自 `REVIEW_ARKTS_FULL.md` 的 P2 清单，逐条落地（全部 `BUILD SUCCESSFUL` + 装机 + 启动正常）：

| 评审项 | 处理 |
|---|---|
| **L-P2-6** 增量未知 sink 被静默丢弃（注释声称"占位自愈"与实现矛盾） | 改为**真占位**：记 volume/muted/enabled，`maxVolume` 留 0 ⇒ `pct()=-1`（UI 显示「—」、滑杆禁用），列表到达时被 `applyList` 整体替换并补刻度 ⇒ **变化不再丢** |
| **L-P2-5** 音量/静音乐观更新在 send 前落盘、失败不回滚 | `setVolume`/`toggleMute` 均记前值，**发送失败即回滚并重推**（UI 不再长期显示未生效值） |
| **L-P2-8** Battery `thresholdEvent` 被吞（桌面低电量提醒缺失） | 不再静默丢弃：推独立事件 `battery.threshold` + 日志留痕。**跨阈值即刻上报**的完整语义需与对端行为对齐后再做（注释已写明） |
| **L-P2-7** `PluginHost.matches` 对"声明 outgoing 但 incoming 为空"过宽 | 发送类能力**只在 `peerIncoming` 明确包含该 type 时**匹配（原先 `peerIncoming.length===0` 会装上全部发送插件）；"两端都没声明"的兜底保留 |
| **L-P2-3** `frameBuffers` 无上限（对端只发无换行数据 ⇒ 无界增长） | 新增 `MAX_FRAME_BUFFER = 256 KiB`，超限丢弃该设备半帧缓冲 + 日志 |
| **L-P2-9** `ConnectivityReportPlugin.onCreate` 重入不清旧 interval | 入口先 `clearInterval` 再新建（防定时器泄漏 + 持续发包） |
| **L-P2-10** `PayloadHistory.save()` 读-合并-写无串行化（并发丢历史） | 改为 **Promise 链排队**（`save()` 入队 → `saveNow()` 执行），调用方签名不变 |
| **U-P2-2** `PayloadRow` 行内按钮冒泡到整行（保存后误弹详情） | 按钮所在 Row 加 `.hitTestBehavior(HitTestMode.Block)` 阻断命中测试上浮 |
| **U-P2-1** `avoidArea` 只在启动取一次（旋转/折叠后安全区错位） | EntryAbility 增加 `win.on('avoidAreaChange')` 监听，`TYPE_SYSTEM` 变化即刷新 `statusBarHeightPx/navBarHeightPx` |
| **U-P2-3** 手动连接无输入校验（空 host / NaN 端口静默回退 1716） | DevicesTab：只有**输入框为空**才用默认 1716，非数字原样上传；页面边界校验（空 host / 端口非 1-65535）→ toast 提示，不再静默连。新增文案 `toast_manual_bad_host` / `toast_manual_bad_port` |

**仍未做（下一批）**：S6 `Index.ets` 拆分（等三方副本对比后统一拆法）、L-P2-1（clock-skew 超限不回拒绝帧）、L-P2-4（MPRIS 增量劫持 `currentPlayer`）、U-P3（卡片材质分层，随 S6）。

**验证程度**：以上多为**边界/失败路径**，本轮验证到「构建通过 + 装机 + 启动无异常 + 既有回归（设备列表/媒体卡片）正常」；逐条构造失败场景（如手工制造帧溢出、强制 send 失败）属后续真机验证项，未声称已验证。
### 8.1 追加两项（同日，第二批续）

| 评审项 | 处理 |
|---|---|
| **L-P2-1** clock-skew 超限只 log+return ⇒ 对端停在等待态直到超时 | 复用既有 `rejectPair(deviceId)` 回 `{pair:false}`（Android 同做法），让对端立即得到明确结果 |
| **L-P2-4** MPRIS 增量包劫持 `currentPlayer` | 收紧判定：①删除"currentPlayer 为空即放行"的白名单旁路；②已有当前播放器时只接受**同一个播放器**的包 ⇒ 后台播放器的周期 pos 包不再抢焦点（面板不再来回跳）。数据仍并入各自桶（既有别名合并逻辑保留） |

至此 `REVIEW_ARKTS_FULL.md` 中**除 S6 拆分与 U-P3 材质分层之外**的 P1/P2 项已全部处理完毕。
## 9. S6 第 1 步：弹窗抽离（2026-09-19，已真机验证）

**范围**：只抽**自包含弹窗**，风险最低、与另两份副本冲突面最小（拆法是本次三方对比的重点，先用一小步把"范式"立住）。

| 动作 | 内容 |
|---|---|
| 新增 | `components/PayloadDetailDialog.ets` —— 「文件详情」弹窗独立组件 |
| 依赖方向 | **Index 算好展示文案**（复用既有 `fmtBytes` / `timeTextOf` / `payloadStateText` / `resText`），组件只做**渲染 + 回调**（`@Prop` + `onSaveAs/onDiscard/onClose`），组件内不碰插件、不持页面状态；范式对齐既有 `MprisProgress` / `SystemSinkRow` |
| Index 侧 | 66 行内联弹窗块 → 20 行组件调用（**行为保持**：只搬结构；丢弃后关弹窗、点遮罩关闭等语义原样保留） |
| 顺带清理 | 删除因此失效的页面级 `@Builder infoLine`（死代码，组件内自持等价属性行渲染） |

**真机验证（MatePad Mini，对端在线）**：
```
文件页行： ms_test_1.txt / 已发送   ms_test_2.txt / 已发送 …
点行 → 弹窗（抽出的组件）显示： 大小 / 时间 / 状态 / 方向 + [另存为] [丢弃] [取消]
点「取消」→ 弹窗节点全部消失 ✓（关闭路径正常）
回归：文件页「发送文件 / 已接收」正常 ✓
```

**下一步（待定，见 §6）**：第 2 步域状态抽离（`state/*.ets` + `@ObjectLink`）、第 3 步插件事件总线路由、第 4 步会话状态机、第 5 步 Index 收尾；U-P3 卡片材质分层随 S6。
**建议**：等 CodeArts / AtomCode 两份副本的拆法出来后再推进 2-5 步，避免三条分支在"怎么拆"上分叉而无法合并。