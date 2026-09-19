# REVIEW_ARKTS_MERGED.md — ArkTS 全量评估总结论（CodeArts + AtomCode 合并）

> 2026-09-19。本文件合并 CodeArts（37 个 .ets 全量读取+评估）与 AtomCode（`devdocs/REVIEW_ARKTS_FULL.md`）两路独立评审结果，去重、排序、形成统一行动清单。各 agent 原报告保留不动。

## 一、三个结构性根因（双方共识）

| # | 根因 | CodeArts | AtomCode | 性质 |
|---|---|---|---|---|
| R1 | **Index.ets 4156 行巨石文件**（占全代码 47%）：会话状态机 + 插件事件总线 + 8 业务域状态 + 全部 UI 混在一处，状态缺陷无处隔离 | A1（给出拆分方案：MprisPanel/PairSession/PayloadManager/DrawerOverlay/各 Dialog） | 根因 1（定性：S6 拆分从「债」升级为「必要」） | **双方共识** |
| R2 | **插件层自造状态机**：剪贴板回环、MPRIS 焦点劫持、音量乐观更新不回滚——共性是「未先抄上游协议状态机再适配鸿蒙」 | L1+L2（字符串通道违反类型化约定）等具体发现 | 根因 2（定性归纳） | **互补**：AtomCode 归纳结构，CodeArts 给具体实例 |
| R3 | **UI 事件无统一冒泡/回环防护约定**：@Prop/@ObjectLink 分批试错补齐，仍有 PayloadRow 冒泡、Radio 回环等残留 | U3+U4（弹窗硬编码颜色）、N3（弹窗未用系统组件） | 根因 3（定性归纳） | **互补**：AtomCode 归纳结构，CodeArts 给具体实例 |

## 二、合并缺陷清单（去重 + 统一编号）

### P1 — 功能错误，用户可直接踩到

| # | 位置 | 问题 | 来源 | 上游对照 |
|---|---|---|---|---|
| **P1-1** | ClipboardPlugin:41-58 | **剪贴板回环死循环**：收到对端内容 setDataSync 后无去重记录，sendClipboard 会把刚收到的内容原样发回，双端互刷 | AtomCode L-P1-1 | Android ClipboardPlugin 有 lastContents/timestamp 比对防回环 |
| **P1-2** | PacketRouter:92-98 | **acceptPair 失败仍标记已配对**：sendFrame 失败（未加密链路）时无条件 onPaired，UI 已配对但帧没发出 | AtomCode L-P1-2 | requestPair 同类已修，acceptPair 漏网 |
| **P1-3** | EntryAbility:46 | **锁竖屏实验开关 `LOCK_PHONE_PORTRAIT=false` 未回收**——手机跟随系统旋转会进平板布局 | CodeArts L5 + AtomCode U-P1-1 | **双方共识** |
| **P1-4** | BatteryPlugin:45-62, RunCommandPlugin | **仍用字符串通道**（`"85|1"` 格式），违反批1 类型化事件约定 | CodeArts L1+L2 | 批1 已确立类型化事件通道 |

### P2 — 结构/边界（含 1 条安全相关）

| # | 位置 | 问题 | 来源 | 备注 |
|---|---|---|---|---|
| **P2-1** | PacketRouter:170-178 | **requestedPeers 无超时清理**：过期残留 + 对端任意新请求命中 race 分支 → **跳过用户确认直接接受**，绕过配对裁决 | AtomCode L-P2-2 | **安全相关，建议升级首批** |
| **P2-2** | PacketRouter:160-170 | clock-skew 超限只 log+return，**不回拒绝帧**——对端停在等待态直到超时 | AtomCode L-P2-1 | Android 拒绝时发拒绝帧 |
| **P2-3** | PacketRouter:118-124 | frameBuffers **无上限**：对端持续发无换行数据 → 按设备无界增长（内存泄漏） | AtomCode L-P2-3 | |
| **P2-4** | MprisPlugin:310-314 | 增量包劫持 currentPlayer（空时白名单旁路 + 后台播放器 pos 包抢焦点） | AtomCode L-P2-4 | |
| **P2-5** | SystemVolumePlugin:188-212 | setVolume/toggleMute **乐观更新在 send 前落盘，失败不回滚** | AtomCode L-P2-5 | |
| **P2-6** | SystemVolumePlugin:266-270 | 增量包未知 sink 直接丢弃——注释声称「占位自愈」与实现矛盾 | AtomCode L-P2-6 | |
| **P2-7** | PluginHost:113-128 | matches 对「声明了 outgoing 但 incoming 为空」的对端过宽（仍装载全部发送插件） | AtomCode L-P2-7 | |
| **P2-8** | BatteryPlugin:45-62 | thresholdEvent（低电量告警）被吞，桌面低电提醒缺失 | AtomCode L-P2-8 | |
| **P2-9** | ConnectivityReportPlugin:41-46 | onCreate 重入不清旧 interval → 定时器泄漏、持续发包 | AtomCode L-P2-9 | CodeArts L6 也发现轮询间隔差异（60s vs Android 30s） |
| **P2-10** | PayloadHistory:57-105 | save() 读-合并-写无串行化：两传输同时完成交错写 → 先完成者历史丢失 | AtomCode L-P2-10 | |
| **P2-11** | Index.ets | **缺少 HdsNavigation**：参考实现 ohtotptoken 每个 Tab 都用 HdsNavigation + titleBar（含安全区沉浸、渐变模糊滚动效果、systemMaterialEffect），本项目自绘标题区 | CodeArts U1+A2 | 对照 ohtotptoken |
| **P2-12** | Index.ets 卡片区 | **卡片沉浸光感未生效**：`immersive: false` 硬编码，所有卡片走毛玻璃降级 | CodeArts U2 | |
| **P2-13** | Index.ets 弹窗/遮罩 | **硬编码颜色** `#F2111A36`/`#99000000`，不适配主题 | CodeArts U3+U4 | |
| **P2-14** | Index.ets | **`if (this.trustedDevices.length !== before || true)` 恒真条件**，调试代码未删 | CodeArts L4 | |
| **P2-15** | EntryAbility:42-44 | avoidArea 只在启动时取一次，**无 avoidAreaChange 监听**——旋转/折叠/隐藏导航栏后安全区错位 | AtomCode U-P2-1 | |
| **P2-16** | PayloadRow:103-146 | 行内按钮点击**冒泡到整行 onClick**，保存后误弹详情 | AtomCode U-P2-2 | 需 stopPropagation |
| **P2-17** | DevicesTab:825-827 | 手动连接无输入校验（空 host / NaN 端口静默回退 1716） | AtomCode U-P2-3 | 违反「系统边界必须校验」 |
| **P2-18** | SystemSinkRow:40-48 | Radio 程序化回环：onChange 不比对当前值，对端回推 isDefault 时可能重复发 onSelect | AtomCode U-P2-4 | |
| **P2-19** | Index.ets 抽屉 | 抽屉用 BACKGROUND_THICK（性能隐患） | CodeArts U6 | |

### P3 — 低优先 / 随 S6 拆分统一处理

| # | 位置 | 问题 | 来源 |
|---|---|---|---|
| **P3-1** | NetworkPacket.ets | 死代码（无人 import） | CodeArts A3 |
| **P3-2** | PluginRegistry | aggregate() 每次实例化全部插件只为读静态声明 | CodeArts A4 + AtomCode P3 |
| **P3-3** | SystemVolumePlugin | svSinks 单槽过滤用 mprisDeviceId 而非 svDeviceId（语义混淆） | CodeArts L3 |
| **P3-4** | SharePlugin | 不处理 url/text 类型 | CodeArts L7 |
| **P3-5** | Index.ets 弹窗 | 弹窗自绘条件渲染，未用系统 CustomDialogController/bindSheet | CodeArts N3 |
| **P3-6** | 卡片区 | 仍用 backgroundBlurStyle 而非 systemMaterialEffect 分层——ohtotptoken 是「导航/底栏沉浸材质 + 卡片 HdsListItemCard」体系 | AtomCode U-P3 + CodeArts U2 |
| **P3-7** | NetworkPacket.ets | 有损 replace | AtomCode P3 |
| **P3-8** | MprisProgress | 暂停期陈旧 nowMs | AtomCode P3 |
| **P3-9** | DevicesTab | 去抖 timer 不清理 | AtomCode P3 |
| **P3-10** | TrustStore | 静默吞错 + schemaVersion 不读 | AtomCode P3 |
| **P3-11** | safeFileName | 不滤控制字符/`..` 夹心 | AtomCode P3 |

### 确认良好（勿动）

- **沉浸光感底栏**：HdsTabs 悬浮胶囊 + barOverlap + barFloatingStyle.systemMaterialEffect(ADAPTIVE) + BottomTabBarStyle(SymbolGlyph) + barBackgroundBlurStyle(Regular) + 300ms 切换——与 ohtotptoken 基线同构，且本工程多了「navBarHeight 自适应 margin」「渐隐遮罩显式置透明」两个实测修正，**质量高于参考稿**（AtomCode 确认）。

## 三、统一行动清单（三批排期）

### 批 1 — 立即修复（P1 + 安全相关 P2）

| 序号 | 缺陷 | 负责方 | 修复要点 |
|---|---|---|---|
| 1 | **P1-1** 剪贴板回环 | DevEco | 加 lastContents/timestamp 去重（对照 Android ClipboardPlugin） |
| 2 | **P1-2** acceptPair 失败回滚 | DevEco | sendFrame 失败时不调 onPaired（对照 requestPair 已修模式） |
| 3 | **P1-3** 锁竖屏开关回归 | DevEco | `LOCK_PHONE_PORTRAIT = true` |
| 4 | **P1-4** BatteryPlugin/RunCommandPlugin 字符串通道 | DevEco | 改为类型化事件通道（批1 约定） |
| 5 | **P2-1** requestedPeers 超时清理（安全） | DevEco | 加过期清理 + race 分支防护 |
| 6 | **P2-14** `|| true` 恒真条件 | DevEco | 删除调试代码 |

### 批 2 — 结构修复（随 S6 拆分）

| 序号 | 缺陷 | 负责方 | 修复要点 |
|---|---|---|---|
| 7 | **R1** Index.ets 拆分 | DevEco | 拆为 MprisPanel/PairSession/PayloadManager/DrawerOverlay/各 Dialog |
| 8 | **P2-2** clock-skew 回拒绝帧 | DevEco | 对照 Android 发拒绝帧 |
| 9 | **P2-3** frameBuffers 上限 | DevEco | 加容量限制 + 丢弃超限数据 |
| 10 | **P2-5** 音量乐观更新回滚 | DevEco | send 后再落盘，失败回滚 |
| 11 | **P2-6** 增量未知 sink 占位 | DevEco | 创建占位 sink 而非丢弃 |
| 12 | **P2-10** PayloadHistory 串行化 | DevEco | 读-合并-写加锁/队列 |
| 13 | **P2-11** HdsNavigation 引入 | DevEco | 对照 ohtotptoken 每个 Tab 用 HdsNavigation |
| 14 | **P2-12** 卡片沉浸光感 | DevEco | `immersive` 改为探测结果而非硬编码 false |
| 15 | **P2-13** 弹窗硬编码颜色 | DevEco | 改用主题资源 |
| 16 | **P2-15** avoidAreaChange 监听 | DevEco | 加 avoidAreaChange 回调 |
| 17 | **P2-16** 按钮冒泡 | DevEco | stopPropagation 统一约定 |
| 18 | **P2-17** 手动连接校验 | DevEco | 空 host/NaN 端口校验 |
| 19 | **P2-18** Radio 回环 | DevEco | onChange 比对当前值 |
| 20 | **P2-4** MPRIS 焦点劫持 | DevEco | 增量包不劫持空 currentPlayer |
| 21 | **P2-7** PluginHost matches 收窄 | DevEco | 对端 incoming 为空时不装载发送插件 |
| 22 | **P2-9** ConnectivityReport 定时器清理 | DevEco | onCreate 清旧 interval + 间隔改 30s |
| 23 | **P2-19** 抽屉材质降级 | DevEco | BACKGROUND_THICK → THIN |

### 批 3 — 低优先（S6 后统一）

| 序号 | 缺陷 | 负责方 | 修复要点 |
|---|---|---|---|
| 24 | **P3-1** NetworkPacket 死代码 | DevEco | 删除或接入 |
| 25 | **P3-2** PluginRegistry 性能 | DevEco | aggregate 改为静态声明读取 |
| 26 | **P3-3** svSinks 语义混淆 | DevEco | 改用 svDeviceId |
| 27 | **P3-4** SharePlugin url/text | DevEco | 加 url/text 处理 |
| 28 | **P3-5** 弹窗用系统组件 | DevEco | CustomDialogController/bindSheet |
| 29 | **P3-6** 卡片材质分层 | DevEco | S6 时统一到 systemMaterialEffect + HdsListItemCard |
| 30 | **P3-7** NetworkPacket 有损 replace | DevEco | |
| 31 | **P3-8** MprisProgress 陈旧 nowMs | DevEco | |
| 32 | **P3-9** DevicesTab 去抖 timer 清理 | DevEco | |
| 33 | **P3-10** TrustStore 错误处理 | DevEco | |
| 34 | **P3-11** safeFileName 过滤 | DevEco | 滤控制字符/`..` |
| 35 | **P2-8** thresholdEvent 低电量告警 | DevEco | |

## 四、双方发现交叉矩阵

| 维度 | CodeArts 独有 | AtomCode 独有 | 双方共识 |
|---|---|---|---|
| Index.ets 巨石 | A1（拆分方案） | 根因 1（定性） | ✅ |
| 插件自造状态机 | L1+L2（字符串通道） | 根因 2（归纳） | ✅ 互补 |
| UI 回环防护 | U3+U4, N3 | 根因 3（归纳） | ✅ 互补 |
| 剪贴板回环 | — | L-P1-1 | AtomCode 独有 |
| acceptPair 漏网 | — | L-P1-2 | AtomCode 独有 |
| 锁屏开关 | L5 | U-P1-1 | ✅ |
| 字符串通道 | L1+L2 | — | CodeArts 独有 |
| requestedPeers 安全 | — | L-P2-2 | AtomCode 独有 |
| HdsNavigation 缺失 | U1+A2 | — | CodeArts 独有 |
| 卡片沉浸光感 | U2 | U-P3（P3 级） | ✅ 互补 |
| 弹窗硬编码颜色 | U3+U4 | — | CodeArts 独有 |
| `|| true` 恒真 | L4 | — | CodeArts 独有 |
| NetworkPacket 死代码 | A3 | — | CodeArts 独有 |
| PluginRegistry 性能 | A4 | P3 | ✅ |
| ConnectivityReport | L6（间隔差异） | L-P2-9（定时器泄漏） | ✅ 互补 |
| 沉浸光感底栏 | — | 「对齐良好，勿动」 | AtomCode 确认 OK |
| avoidAreaChange | — | U-P2-1 | AtomCode 独有 |
| 按钮冒泡 | — | U-P2-2 | AtomCode 独有 |
| 手动连接校验 | — | U-P2-3 | AtomCode 独有 |
| Radio 回环 | — | U-P2-4 | AtomCode 独有 |

## 五、统计

- **合并后总缺陷数**：6×P1 + 19×P2 + 11×P3 = **36 条**
- **双方共识**：6 条（Index 巨石、锁屏开关、PluginRegistry 性能、ConnectivityReport、卡片沉浸光感、UI 回环防护结构）
- **CodeArts 独有**：10 条（HdsNavigation、弹窗颜色、`|| true`、字符串通道、NetworkPacket 死代码、svSinks 语义、SharePlugin、抽屉材质、弹窗系统组件）
- **AtomCode 独有**：14 条（剪贴板回环、acceptPair、requestedPeers 安全、clock-skew、frameBuffers、MPRIS 焦点、音量回滚、增量 sink、PluginHost matches、thresholdEvent、PayloadHistory、avoidAreaChange、按钮冒泡、手动连接校验、Radio 回环）
- **确认良好勿动**：沉浸光感底栏（含两处实测修正）

—— CodeArts（华为云码道代码智能体），评审总指挥
