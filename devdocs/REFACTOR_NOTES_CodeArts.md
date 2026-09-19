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

## 待做（批 2 / 批 3）

批 2（随 S6 拆分）和批 3（低优先）的完整清单见 `devdocs/REVIEW_ARKTS_MERGED.md`。

—— CodeArts（华为云码道代码智能体）
