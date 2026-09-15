# 功能规划：与 Android 版差距分析 + APP 端按钮调整 + caps 声明改进

> 2026-09-14。基于用户反馈和确认。最终方案：6 个按钮 = 发送文件 / 剪贴板 / 查找设备 / 媒体控制 / 远程命令 / 远程输入。

---

## 一、差距分析：电脑端三标签页

| 标签页 | Android 版 | 我们当前 | 缺失原因 |
|---|---|---|---|
| **Controls** | 媒体控制 + 远程输入 + 通知读取 + 远程命令 | ❌ 完全缺失 | 没有声明任何 Controls 类 outgoing caps |
| **Actions** | 响铃 + 文件分享 + 剪贴板 | 部分有 | 有 ping/share/clipboard，但 findmyphone 只 incoming |
| **Information** | 电量 + 网络状态 + 地址 | 只有地址 | BatteryPlugin outgoing=`[]`，无 ConnectivityReportPlugin |

---

## 二、最终按钮布局（用户确认）

| 序号 | 按钮 | key | 功能 | 替换/变更 |
|---|---|---|---|---|
| 1 | 发送文件 | `send_file` | 跳转文件页 | 不变 |
| 2 | 剪贴板 | `clipboard` | 卡片点击→读取对端剪贴板；PasteButton→发送本机剪贴板 | 改语义 |
| 3 | 查找设备 | `find_device` | 发送 `kdeconnect.findmyphone.request` 让对端响铃 | 改名（原"查找手机"） |
| 4 | 媒体控制 | `media` | 打开 MPRIS 控制面板 | 不变（P2 实现 UI） |
| 5 | 远程命令 | `run_command` | 显示对端预设命令列表，点击执行 | 替换"电量" |
| 6 | 远程输入 | `remote_input` | 打开触控板/键盘页面 | 替换"响铃" |

### 剪贴板双向操作

- **PasteButton**（卡片底部安全控件）→ 获取临时读权限 → 读取本机剪贴板 → 发送 `kdeconnect.clipboard` 给对端
- **卡片整体点击** → 发送 `kdeconnect.clipboard.connect`（timestamp=0）→ 对端回复其剪贴板内容 → UI 展示

### 远程命令协议

| Packet Type | 方向 | body 字段 |
|---|---|---|
| `kdeconnect.runcommand` | 对端→我们（incoming） | `commandList`: string（序列化命令字典，key=命令ID，value={name, command}） |
| `kdeconnect.runcommand.request` | 我们→对端（outgoing） | `key`: string（执行指定命令） |
| `kdeconnect.runcommand.output` | 对端→我们（incoming） | `id`/`commandStarted`/`commandOutput`/`stdout`/`stderr`/`commandFinished`/`success`/`exitCode` |

插件 caps：
- `supportedPacketTypes = ['kdeconnect.runcommand', 'kdeconnect.runcommand.output']`
- `outgoingPacketTypes = ['kdeconnect.runcommand.request']`

---

## 三、caps 声明修改汇总

### 修改后完整 caps

| 类别 | incoming caps | outgoing caps |
|---|---|---|
| 基础 | `kdeconnect.identity`, `kdeconnect.pair` | `kdeconnect.identity`, `kdeconnect.pair` |
| Actions | `kdeconnect.ping`, `kdeconnect.share.request`, `kdeconnect.clipboard`, `kdeconnect.clipboard.connect`, `kdeconnect.findmyphone.request` | `kdeconnect.ping`, `kdeconnect.share.request`, `kdeconnect.clipboard`, `kdeconnect.clipboard.connect` |
| Information | `kdeconnect.battery` | `kdeconnect.battery`, `kdeconnect.connectivity_report` |
| Controls | `kdeconnect.mpris`, `kdeconnect.mousepad.keyboardstate`, `kdeconnect.notification`, `kdeconnect.runcommand`, `kdeconnect.runcommand.output` | `kdeconnect.mpris.request`, `kdeconnect.mousepad.request`, `kdeconnect.notification.request`, `kdeconnect.runcommand.request` |

### 新增/修改项

| 变更 | 类型 | 说明 |
|---|---|---|
| `kdeconnect.battery` outgoing | 新增 | BatteryPlugin 改双向，发送本机电量 |
| `kdeconnect.connectivity_report` outgoing | 新增 | ConnectivityReportPlugin，上报网络状态 |
| `kdeconnect.clipboard.connect` outgoing | 新增 | 剪贴板请求对端内容 |
| `kdeconnect.mpris` incoming | 新增 | MprisPlugin 接收桌面播放器状态 |
| `kdeconnect.mpris.request` outgoing | 新增 | MprisPlugin 发送控制命令 |
| `kdeconnect.mousepad.keyboardstate` incoming | 新增 | RemoteInputPlugin 接收键盘状态 |
| `kdeconnect.mousepad.request` outgoing | 新增 | RemoteInputPlugin 发送输入事件 |
| `kdeconnect.notification` incoming | 新增 | NotificationPlugin 接收桌面通知 |
| `kdeconnect.notification.request` outgoing | 新增 | NotificationPlugin 请求通知列表 |
| `kdeconnect.runcommand` incoming | 新增 | RunCommandPlugin 接收命令列表 |
| `kdeconnect.runcommand.output` incoming | 新增 | RunCommandPlugin 接收命令输出 |
| `kdeconnect.runcommand.request` outgoing | 新增 | RunCommandPlugin 请求执行命令 |

---

## 四、实现优先级

### P1（先做 — 让电脑端正确显示三标签页 + APP 端按钮布局正确）

| 任务 | 归属 | 复杂度 | 说明 |
|---|---|---|---|
| BatteryPlugin 改双向 | DevEco Code | 低 | `@ohos.batteryInfo` → 发送 `kdeconnect.battery` |
| ConnectivityReportPlugin | DevEco Code | 中 | `@ohos.radio` + `GET_NETWORK_INFO` 权限 |
| RunCommandPlugin | DevEco Code | 中 | 接收命令列表 + 执行请求 + UI 展示 |
| APP 端按钮调整 | DevEco Code | 中 | 改名/替换/剪贴板双向 |
| caps 声明修复 | DevEco Code | 低 | 新增 outgoing/incoming caps |
| 剪贴板读取对端 | DevEco Code | 中 | 发送 `clipboard.connect` + 展示对端内容 |

### P2（后续 — 填充 Controls 类按钮的 UI）

| 任务 | 归属 | 复杂度 |
|---|---|---|
| MprisPlugin UI（媒体控制面板） | DevEco Code | 中 |
| RemoteInputPlugin UI（触控板/键盘） | DevEco Code + native | 高 |
| NotificationPlugin UI（通知列表） | DevEco Code | 高 |

### 策略说明

P1 中，"媒体控制"和"远程输入"按钮在 APP 端先做占位（toast "功能开发中"），但 caps 中声明对应的 outgoing/incoming。这样：
- 电脑端会显示 Controls 标签页（因为声明了 outgoing caps）
- APP 端按钮布局正确（6 个按钮已就位）
- P2 再填充实际 UI

**注意**：声明 caps 但没有插件处理 incoming packet 时，对端发送的 packet 会被 PacketRouter 丢弃（无对应插件）。这是安全的，不会导致错误。

---

## 五、新增权限

| 权限 | 级别 | 用途 |
|---|---|---|
| `ohos.permission.GET_NETWORK_INFO` | normal（三方可申请） | ConnectivityReportPlugin 读取网络类型和信号强度 |

---

## 六、协议字段参考

### BatteryPlugin（`kdeconnect.battery`）

| 字段 | 类型 | 说明 |
|---|---|---|
| `currentCharge` | number (-1~100) | 电池百分比，-1=无电池 |
| `isCharging` | boolean | 是否充电 |
| `thresholdEvent` | enum 0/1 | 1=低于阈值 |

HarmonyOS API：`@ohos.batteryInfo`（`batterySOC` 百分比 + `isCharging`）

### ConnectivityReportPlugin（`kdeconnect.connectivity_report`）

| 字段 | 类型 | 说明 |
|---|---|---|
| `signalStrengths` | object | `{ subscriptionId: { networkType, signalStrength } }` |
| `networkType` | enum | GSM/CDMA/UMTS/LTE/5G/Unknown 等 |
| `signalStrength` | number (0-4) | 信号强度等级 |

HarmonyOS API：`@ohos.radio`（`getNetworkState` + `getSignalStrength`）

### RunCommandPlugin

**`kdeconnect.runcommand`**（对端→我们）：
| 字段 | 类型 | 说明 |
|---|---|---|
| `commandList` | string（序列化 JSON） | 命令字典：key=命令ID，value={name, command} |

**`kdeconnect.runcommand.request`**（我们→对端）：
| 字段 | 类型 | 说明 |
|---|---|---|
| `key` | string | 要执行的命令ID |

**`kdeconnect.runcommand.output`**（对端→我们）：
| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | number | 命令实例ID |
| `commandStarted` | boolean | 命令已启动 |
| `command` | string | 命令行 |
| `commandOutput` | boolean | 包含输出 |
| `stdout` | string[] | 标准输出行 |
| `stderr` | string[] | 标准错误行 |
| `commandFinished` | boolean | 命令已完成 |
| `success` | boolean | 是否成功 |
| `exitCode` | number | 退出码 |

### MprisPlugin（`kdeconnect.mpris` / `kdeconnect.mpris.request`）

字段表见 `MSG106_OMP_TO_DEVECO.md` §3。

### RemoteInputPlugin（`kdeconnect.mousepad.request`）

| 字段 | 类型 | 说明 |
|---|---|---|
| `key` | string | 按下并释放的字符 |
| `specialKey` | number (0-32) | 非打印字符（Backspace=1, Tab=2, ...） |
| `alt`/`ctrl`/`shift`/`super` | boolean | 修饰键 |
| `singleclick`/`doubleclick`/`middleclick`/`rightclick` | boolean | 鼠标点击 |
| `singlehold`/`singlerelease` | boolean | 鼠标按下/释放 |
| `dx`/`dy` | number | 指针位移 |
| `scroll` | boolean | 滚动事件 |

### NotificationPlugin（`kdeconnect.notification` / `kdeconnect.notification.request`）

**`kdeconnect.notification`**（对端→我们）：
| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 通知ID |
| `appName` | string | 应用名称 |
| `title` | string | 通知标题 |
| `text` | string | 通知正文 |
| `ticker` | string | 标题+内容合并 |
| `isCancel` | boolean | 通知已关闭 |
| `isClearable` | boolean | 可关闭 |
| `actions` | string[] | 动作列表 |
| `requestReplyId` | string | 可回复通知的UUID |

**`kdeconnect.notification.request`**（我们→对端）：
| 字段 | 类型 | 说明 |
|---|---|---|
| `request` | boolean | 请求所有通知 |
| `cancel` | string | 关闭指定通知 |
