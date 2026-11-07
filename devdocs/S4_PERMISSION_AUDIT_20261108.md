# S4 权限实测报告 — notification.reply/action + contacts.* 鸿蒙权限可行性

- 日期：2026-11-08
- 作者：CodeArts
- 依据：MSG179 §3 CodeArts 第 2 项派单（D+3–D+5=11-10~11-12）
- 结论落点：`devdocs/`（本文件）

## 1. 总结论

| 功能方向 | 协议支持 | 鸿蒙可行性 | 关键障碍 |
|---|---|---|---|
| 通知回复（发送方）：向对端通知发回复 | ✅ `notification.reply` schema | **✅ 可行** | 需实现包发送逻辑 |
| 通知动作（发送方）：激活对端通知动作按钮 | ✅ `notification.action` schema | **✅ 可行** | 需实现包发送逻辑 |
| 通知同步（发送方向）：本机通知 → 对端 | ✅ `kdeconnect.notification` | **❌ 不可行** | `NOTIFICATION_CONTROLLER` = system_basic，第三方不可获取 |
| 通知同步（接收方向）：对端通知 → 本机展示 | ✅ `kdeconnect.notification` | **✅ 已实现** | 当前 NotificationPlugin 已完成 |
| 联系人同步（双向） | ✅ 4 个 contacts schema | **❌ 不可行** | `READ_CONTACTS`/`WRITE_CONTACTS` = system_basic |

## 2. 通知权限详细分析

### 2.1 当前项目状态

- **已有实现**：`NotificationPlugin.ets` 接收 `kdeconnect.notification` 包并展示（纯协议层解析，不涉及系统通知 API）
- **未声明权限**：`module.json5` 中无 `NOTIFICATION_CONTROLLER`
- **未使用系统 API**：项目中无 `@ohos.notificationManager` import

### 2.2 `notification.reply` 可行性

**协议**（`kdeconnect.notification.reply` schema）：
- body: `{requestReplyId: string, message: string}`
- 用途：向对端的可回复通知发送回复消息（如回复聊天通知）

**鸿蒙可行性**：
- **作为发送方（本机向对端通知发回复）**：✅ 可行——只需构造 `kdeconnect.notification.reply` 包通过现有 packet 发送通道发出，不涉及任何系统通知权限
- **作为接收方（本机通知被对端回复）**：❌ 不可行——需要读取本机其他应用的通知、识别可回复通知、注入回复，这需要 `NOTIFICATION_CONTROLLER`（system_basic 级）

**实施建议**：可实现发送方逻辑（用户在通知列表中点击"回复"按钮 → 发 `notification.reply` 包给对端），接收方向不可实现。

### 2.3 `notification.action` 可行性

**协议**（`kdeconnect.notification.action` schema）：
- body: `{key: string, action: string}`
- 用途：激活对端通知上的动作按钮（如"Open"、"Ignore"）

**鸿蒙可行性**：
- **作为发送方（本机触发对端通知动作）**：✅ 可行——构造 `kdeconnect.notification.action` 包发出
- **作为接收方（本机通知动作被对端触发）**：❌ 不可行——同 `notification.reply`，需要 `NOTIFICATION_CONTROLLER`

**实施建议**：可实现发送方逻辑（通知列表中显示动作按钮 → 点击发 `notification.action` 包），接收方向不可实现。

### 2.4 通知同步（本机 → 对端）不可行原因

鸿蒙 Notification Kit 的能力边界：
- 应用只能**发布/管理自己的通知**
- **无法读取其他应用的通知**（系统无 NotificationListener 等价能力）
- `NOTIFICATION_CONTROLLER` 权限是 system_basic 级，第三方应用无法声明和获取

这意味着"手机通知同步到电脑"这个 KDE Connect 核心功能在鸿蒙第三方应用框架下**无法实现**。

### 2.5 docs1105/ArkTS-doc/chunks/17 关键结论

> 系统没有向第三方开放 NotificationListener 等价能力；Notification Kit 的能力范围是"发布/管理自己的通知"。

## 3. 联系人权限详细分析

### 3.1 当前项目状态

- **无任何实现**：项目中无 `@ohos.contacts` import，无联系人相关代码
- **未声明权限**：`module.json5` 中无 `READ_CONTACTS`/`WRITE_CONTACTS`

### 3.2 协议 schema（4 个）

| Schema | type | 用途 |
|---|---|---|
| `kdeconnect.contacts.request_all_uids_timestamps` | 请求所有联系人 UID + 时间戳 | 发送方向 |
| `kdeconnect.contacts.response_uids_timestamps` | 返回 UID + 时间戳列表 | 接收方向 |
| `kdeconnect.contacts.request_vcards_by_uid` | 请求指定 UID 的 vCard | 发送方向 |
| `kdeconnect.contacts.response_vcards` | 返回 vCard 数据 | 接收方向 |

### 3.3 鸿蒙可行性

- `READ_CONTACTS`：**system_basic 级**，第三方应用无法获取 → 本机联系人发送到对端**不可行**
- `WRITE_CONTACTS`：**system_basic 级**，第三方应用无法获取 → 对端联系人写入本机**不可行**

**结论**：联系人同步双向都不可行。

## 4. 当前 module.json5 已声明权限

| 权限 | 级别 | 用途 |
|---|---|---|
| `ohos.permission.INTERNET` | normal | 网络通信 |
| `ohos.permission.VIBRATE` | normal | 振动反馈 |
| `ohos.permission.WRITE_IMAGEVIDEO` | normal | 写图片/视频 |
| `ohos.permission.WRITE_AUDIO` | normal | 写音频 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | normal | 后台长时任务 |
| `ohos.permission.GET_NETWORK_INFO` | normal | 网络状态 |
| `ohos.permission.GET_WIFI_INFO` | normal | WiFi 信息 |

所有已声明权限均为 **normal 级**，无需系统应用身份。

## 5. 可推进 vs 不可推进

### 可推进（不需 system_basic 权限）

1. **`notification.reply` 发送方**：用户在本机通知列表中对对端通知点击"回复" → 发 `kdeconnect.notification.reply` 包
2. **`notification.action` 发送方**：用户在本机通知列表中对对端通知点击动作按钮 → 发 `kdeconnect.notification.action` 包
3. **通知接收展示**：已有实现，可继续完善 UI

### 不可推进（需 system_basic 权限，第三方应用无法获取）

1. **通知同步发送方向**（本机通知 → 对端）：`NOTIFICATION_CONTROLLER` system_basic
2. **联系人同步双向**：`READ_CONTACTS`/`WRITE_CONTACTS` system_basic
3. **远程输入/鼠标键盘注入**：`inputEventClient` 仅系统应用

### KDE Review 替代项说明

对于不可推进的功能，在 KDE Review 阶段需在 README/文档中显式写明"鸿蒙平台因系统权限限制无法实现以下功能"，并提供替代方案建议：
- 通知同步 → 用户手动复制通知内容到对端（非自动化）
- 联系人同步 → 通过文件分享发送 vCard 文件
- 远程输入 → 无替代方案

## 6. 建议排期

| 功能 | 可行性 | 建议排期 |
|---|---|---|
| `notification.reply` 发送方 | ✅ | S4 窗口内可实现（纯协议层，不涉及系统 API） |
| `notification.action` 发送方 | ✅ | S4 窗口内可实现（纯协议层，不涉及系统 API） |
| 通知同步发送方向 | ❌ | 不排期，文档标注平台限制 |
| 联系人同步双向 | ❌ | 不排期，文档标注平台限制 |
