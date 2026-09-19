# REVIEW_ARKTS_FULL.md — ArkTS 全量评估（AtomCode，与 CodeArts 并行）：8778 行 / 25 文件，逻辑层 2×P1 确认 + 10×P2，UI 层 1×P1 + 4×P2；总评「整体逻辑未做好」的三个结构性根因

> 2026-09-19。任务书：用户指令——AtomCode 与 CodeArts 并行全量评估 ArkTS；逻辑对照 Android/iOS/上游，UI 对照 ohtotptoken（胶囊导航/沉浸光感）。本报告为 AtomCode 侧结论（子代理两路评审 + 我本人对全部 P1 逐条源码复核）。CodeArts 侧结果合并时以双方去重为准。

## 一、总评：用户判断成立——「Bug 多」不是零散笔误，而是三个结构性根因

1. **Index.ets 4156 行 = 全代码 47%**（S6 旧债）：页面同时承担「会话状态机 + 插件事件总线 + 8 个业务域状态 + 全部 UI」——任何一处状态机缺陷都无处隔离，这是「整体逻辑没做好」的最大单点（本次多数 P2 都源于「同一份数据在页面/插件/组件三层各有一份」）；
2. **插件层「自造状态机」偏多**：剪贴板回环、MPRIS 焦点劫持、音量乐观更新不回滚——共性是「没有先抄上游协议状态机，再适配鸿蒙」，而是按现象写；
3. **UI 状态装饰器半套用**：@Prop/@ObjectLink/@Observed 是分批试错补上的（ForEach 冻结、LogStore 都是踩坑后改），仍有 PayloadRow 冒泡、Radio 回环等同类残留——UI 交互事件**没有统一的冒泡/回环防护约定**。

## 二、逻辑层发现（均已对照上游确认）

### P1（功能错误，用户可直接踩到）

| # | 位置 | 问题 | 上游对照 |
|---|---|---|---|
| L-P1-1 | ClipboardPlugin:41-58 | **剪贴板回环死循环**：收到对端内容 setDataSync 后无去重记录，sendClipboard 会把刚收到的内容原样发回，双端互刷 | Android ClipboardPlugin 有 lastContents/timestamp 比对防回环 |
| L-P1-2 | PacketRouter:92-98 | **acceptPair 失败仍标记已配对**：sendFrame 失败（未加密链路）时无条件 onPaired，UI 已配对但帧没发出 | MSG77 在 requestPair 已处理同类，acceptPair 漏网 |

### P2（结构/边界）

| # | 位置 | 问题 |
|---|---|---|
| L-P2-1 | PacketRouter:160-170 | clock-skew 超限只 log+return，**不回拒绝帧**——对端停在等待态直到超时（Android 拒绝时发拒绝帧） |
| L-P2-2 | PacketRouter:170-178 | requestedPeers **无超时清理**：过期残留 + 对端任意新请求命中 race 分支 → **跳过用户确认直接接受**，绕过配对裁决 |
| L-P2-3 | PacketRouter:118-124 | frameBuffers **无上限**：对端持续发无换行数据 → 按设备无界增长（内存泄漏点） |
| L-P2-4 | MprisPlugin:310-314 | 增量包劫持 currentPlayer（`currentPlayer` 为空时白名单旁路 + 后台播放器 pos 包抢焦点） |
| L-P2-5 | SystemVolumePlugin:188-212 | setVolume/toggleMute **乐观更新在 send 前落盘，失败不回滚** |
| L-P2-6 | SystemVolumePlugin:266-270 | 增量包未知 sink 直接丢弃——注释声称「占位自愈」与实现矛盾（对端先推增量则变化静默丢失） |
| L-P2-7 | PluginHost:113-128 | matches 对「声明了 outgoing 但 incoming 为空」的对端过宽（仍装载全部发送插件） |
| L-P2-8 | BatteryPlugin:45-62 | thresholdEvent（低电量告警）被吞，桌面低电提醒缺失 |
| L-P2-9 | ConnectivityReportPlugin:41-46 | onCreate 重入不清旧 interval → 定时器泄漏、持续发包 |
| L-P2-10 | PayloadHistory:57-105 | save() 读-合并-写无串行化：两传输同时完成交错写 → 先完成者历史丢失 |

### P3（8 条，略）：NetworkPacket 有损 replace、PluginRegistry aggregate 全实例化、MprisProgress 暂停期陈旧 nowMs、DevicesTab 去抖 timer 不清理、TrustStore 静默吞错 + schemaVersion 不读、safeFileName 不滤控制字符/`..` 夹心等——全表随 CodeArts 汇总去重后入缺陷库。

## 三、UI 层发现（对照 ohtotptoken）

**对齐良好（勿动）**：HdsTabs 悬浮胶囊 + barOverlap + barFloatingStyle.systemMaterialEffect(ADAPTIVE) + BottomTabBarStyle(SymbolGlyph) + barBackgroundBlurStyle(Regular) + 300ms 切换——与 ohtotptoken 基线（HdsNavigation/HdsTabs + ADAPTIVE 材质 + barOverlap）同构，且本工程多了「navBarHeight 自适应 margin」「渐隐遮罩显式置透明」两个实测修正，质量高于参考稿。

| # | 位置 | 级别 | 问题 |
|---|---|---|---|
| U-P1-1 | EntryAbility:46 | P1 | **锁竖屏实验开关 `LOCK_PHONE_PORTRAIT=false` 未回收**——手机跟随系统旋转会进平板布局（与既有决策相悖），排查代码忘了还原 |
| U-P2-1 | EntryAbility:42-44 | P2 | avoidArea 只在启动时取一次，**无 avoidAreaChange 监听**——旋转/折叠/隐藏导航栏后安全区错位 |
| U-P2-2 | PayloadRow:103-146 | P2 | 行内按钮点击**冒泡到整行 onClick**，保存后误弹详情；需 stopPropagation 统一约定 |
| U-P2-3 | DevicesTab:825-827 | P2 | 手动连接无输入校验（空 host / NaN 端口静默回退 1716），违反「系统边界必须校验」 |
| U-P2-4 | SystemSinkRow:40-48 | P2 | Radio 程序化回环：onChange 不比对当前值，对端回推 isDefault 时可能重复发 onSelect |
| U-P3 | Index:3205 vs ohtotptoken:1449 | P3 | 卡片区仍用 backgroundBlurStyle 而非 systemMaterialEffect 分层——ohtotptoken 是「导航/底栏沉浸材质 + 卡片 HdsListItemCard」体系；建议 S6 拆分时统一到官方材质分层 |

## 四、修复排序建议（给 CodeArts 汇总用）

1. **立即批**：L-P1-1（回环，一行去重）、L-P1-2（acceptPair 失败回滚）、U-P1-1（开关闭回归）；L-P2-2（requestedPeers 过期清理——安全相关，建议升级同批）；
2. **结构批（随 S6 拆分）**：L-P2-1/3（PacketRouter 状态机补全）、L-P2-5/6、L-P2-10（History 串行化）、U-P2-1/2/3；
3. **低优先**：其余 P3 + U-P3 材质分层（S6 时统一）。

—— Atomcode（glm5.3-flash），评审工作负责人
