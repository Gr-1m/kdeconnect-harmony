# REFACTOR_NOTES_CodeArts — ArkTS 重构笔记（CodeArts 侧）

> 2026-09-19。分支 `refactor/arkts-codearts`，基于 `1ecdb78`。
> 重构依据：`devdocs/REVIEW_ARKTS_MERGED.md`（CodeArts + AtomCode 合并评估总结论）。

## 批 1 — 立即修复（已提交 `3e2744b`）

| 缺陷 | 文件 | 改动 | 行为变化 |
|---|---|---|---|
| **P1-1** 剪贴板回环 | ClipboardPlugin.ets | 加 `lastReceivedContent` + `lastReceivedTime` 字段；`sendClipboard` 在 5s 内同内容抑制发送 | 修复双端互刷死循环（对照 Android lastContents/timestamp 防回环） |
| **P1-2** acceptPair 失败回滚 | PacketRouter.ets:92-98 | `sendFrame` 失败时不调 `onPaired` | 修复 UI 显示已配对但帧没发出（对照 requestPair 已修模式） |
| **P1-3** 锁竖屏开关 | EntryAbility.ets:46 | `LOCK_PHONE_PORTRAIT = true` | 回归排查实验遗留 |
| **P1-4** 字符串通道 | BatteryPlugin.ets, RunCommandPlugin.ets, PluginEvent.ets, Index.ets | BatteryPlugin 用 `notifyEvent` 传 `{batteryCharge, batteryCharging}`；RunCommandPlugin 用 `notifyEvent` 传 `{runcommandSuccess, runcommandExitCode, runcommandOutput}`；Index.ets 消费侧直读字段 | 消除 `"85|1"` / `"1|0|text"` 自造格式，对齐批1 类型化事件约定 |
| **P2-1** requestedPeers 超时 | PacketRouter.ets | `Set<string>` → `Map<string, number>` 带时间戳；`cleanExpiredRequestedPeers()` 60s 过期清理；`handlePair` 入口调用清理 | 修复过期残留可跳过用户确认自动接受（安全相关） |
| **P2-14** `\|\| true` 恒真 | Index.ets:1236 | 删除 `\|\| true` | 删除调试代码 |

### 验证

- `hvigorw assembleHap`：**BUILD SUCCESSFUL**（4.7s，17 executed / 16 up-to-date）
- 只有预期 WARN（ADAPTIVE API 兼容性，与本次修改无关）
- pre-commit 编码守卫通过

## 批 2 — 逻辑层 P2 修复（已提交 `ab7444b`）

| 缺陷 | 文件 | 改动 |
|---|---|---|
| **P2-2** clock-skew 回拒绝帧 | PacketRouter.ets | 超限时发 `{pair:false}`（对照 Android） |
| **P2-3** frameBuffers 上限 | PacketRouter.ets | 1MB 超限丢弃防内存泄漏 |
| **P2-4** MPRIS 焦点劫持 | MprisPlugin.ets | 增量包不再在 currentPlayer 为空时抢焦点 |
| **P2-5** 音量乐观更新回滚 | SystemVolumePlugin.ets | setVolume/toggleMute send 失败时回滚旧值 |
| **P2-6** 增量未知 sink 占位 | SystemVolumePlugin.ets | 创建占位 SysSinkState 而非丢弃 |
| **P2-7** PluginHost matches 收窄 | PluginHost.ets | 对端 incoming 为空不再匹配 outgoing-only 插件 |
| **P2-8** thresholdEvent 低电量告警 | BatteryPlugin.ets | 处理 thresholdEvent 并推 UI |
| **P2-9** ConnectivityReport 定时器清理 | ConnectivityReportPlugin.ets | onCreate 先清旧 interval |
| **P2-10** PayloadHistory 串行化 | PayloadHistory.ets | Promise 链防并发交错写丢失历史 |

## 批 2 — UI 层 P2 修复（已提交 `ab4d3d9`）

| 缺陷 | 文件 | 改动 |
|---|---|---|
| **P2-12** 卡片沉浸光感 | Index.ets | `immersive` 从硬编码 false 改为 `isImmersiveMaterialSupported()` 探测结果 |
| **P2-13** 弹窗硬编码颜色 | Index.ets, color.json | `#F2111A36`/`#99000000` 改为 `dialog_bg`/`dialog_mask` 主题资源 |
| **P2-15** avoidAreaChange | EntryAbility.ets | 加 `windowSizeChange` 监听，旋转/折叠后安全区不再错位 |
| **P2-16** 按钮冒泡 | PayloadRow.ets | 按钮行加空 onClick 拦截冒泡到整行 onOpen |
| **P2-17** 手动连接校验 | Index.ets | 空 host / NaN 端口 / 越界端口拒绝并 toast |
| **P2-18** Radio 回环 | SystemSinkRow.ets | onChange 加 `!isDefault` 条件，对端回推不重复发 onSelect |
| **P2-19** 抽屉材质 | Index.ets | `BACKGROUND_THICK` → `BACKGROUND_THIN` |

### 验证

- 批 2 逻辑层：**BUILD SUCCESSFUL**（5.0s）
- 批 2 UI 层：**BUILD SUCCESSFUL**（4.0s）
- pre-commit 编码守卫通过

## 待做（批 3）

批 3（低优先 / S6 后统一）的完整清单见 `devdocs/REVIEW_ARKTS_MERGED.md`。
R1（Index.ets 4156 行拆分）是最大工程，需单独规划。

—— CodeArts（华为云码道代码智能体）
