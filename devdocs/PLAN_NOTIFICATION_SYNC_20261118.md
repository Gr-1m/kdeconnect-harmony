# 通知互通（双向）现状与方案 —— 2026-11-18

> 依据：用户 2026-11-18 指令「系统分享先不用测试，推进主线：双方互相获取通知功能」。
> 结论先行：**收方向（桌面→手机）可做且大部分已具备；发方向（手机→桌面）受 HarmonyOS 平台限制，三方应用无法实现**。

## 1. 平台事实（已核对官方文档）

| 能力 | 接口 | 权限/限制 | 三方应用可用 |
|---|---|---|---|
| 发布本应用通知 | `notificationManager.publish` | 首次需用户 `requestEnableNotification` 授权 | ✅ |
| **订阅/读取其它应用通知** | `notificationSubscribe.subscribe` / `subscribeNotification` | `ohos.permission.NOTIFICATION_CONTROLLER`（system_basic）/ `NOTIFICATION_SYSTEM_SUBSCRIBER`；**系统接口，三方应用不支持**（错误码 201/202） | ❌ |

⇒ 「手机通知同步到桌面」（KDE Connect 的 sendnotifications TX 方向）在 HarmonyOS 上需要系统签名应用，**KDE Connect 作为普通应用做不到**。
⇒ 本主线只做**收方向增强**，把「本机通知转发对端」明确标记为平台不支持（与 SMS/通话监听同类）。

## 2. 现状盘点

| 面 | 现状 |
|---|---|
| 收包解析 | `NotificationPlugin` + `NotificationModels.normalizeNotification`：已解析 `id/appName/ticker/isClearable/time`，未知字段忽略 |
| 应用内展示 | `NotificationStore`（每设备 50 条、整体替换触发刷新）+ `NotificationList`（设备详情页区块）+ Index 消费 `notification` 事件 |
| 字段缺口 | `title` / `text` / **`isCancel`** / `actions` / `requestReplyId` 未解析 |
| 取消同步 | 未实现：对端关闭通知（`isCancel:true`）时本机列表不消失 |
| 系统通知栏 | **未实现**：对端通知只出现在 app 内列表，锁屏/通知栏看不到 |
| 回复/动作 | 未实现（且桌面 `sendnotifications` 只收 `notification.request`，回传方向在既有勘误中判为不可用） |

## 3. 方案（只做可做的）

### N1 解析扩字段 + 取消同步（P0，纯逻辑可宿主回归）
- `NotificationBody`/`NotificationItem` 增 `title`、`text`、`isCancel`、`actions`、`requestReplyId`（全部可选，前向兼容）；
- `normalizeNotification`：`isCancel:true` ⇒ 产出「取消意图」（不新增条目）；
- Index 消费：`isCancel` ⇒ `notificationStore.remove(deviceId, id)` + 取消系统通知（N2 落地后）；
- 保留既有不变量：空 id/deviceId 丢弃、time 双兼容、未知字段忽略。

### N2 系统通知栏展示（P0）
- 新增 `common/PeerNotificationPublisher.ets`（**唯一 Kit 依赖层**）：
  - 首次 `notificationManager.requestEnableNotification(context)`；拒绝则只保留 app 内列表并记一次日志（不反复弹）；
  - `publish`：通知 id 用 `deviceId + ':' + peerId` 的稳定哈希（同条更新而不再发新条）；
  - 标题/正文：`appName` +（`title`/`text`，缺则 `ticker`）；
  - 分组：按 `deviceId` 聚合（同设备通知归组），点击回到 app 对应设备详情；
  - `cancel`：对端 `isCancel` 或本机列表关闭时同步取消；
  - 断链（`disconnected`）⇒ 取消该设备全部系统通知（与 `clearDevice` 同批）。
- 纯逻辑（id 计算、文案拼装、是否可发判定）抽到 `common/NotificationPublishPlan.ets`（零 Kit，宿主测试）。
- 设置：**默认开**（与 `receivenotifications` 插件开关联动：插件关 ⇒ 不发系统通知）。

### N3 回复/动作（P1，先核实再决定）
- 既有结论：桌面 `sendnotifications` 方向**只收 `notification.request`**，不支持 reply 回传（`docs/kdeconnect-oh/08` §勘误）。
- 处置：**本期不做回复 UI**；`actions` 仅作为文本/只读展示（可选），并在文档标注「桌面端不支持回传」。
- 若将来对端支持，再按 `kdeconnect.notification.reply` 补。

### N4 TX 方向（不发方向）
- 文档化平台限制（本文件 §1），README/设置页文案标注「本机通知转发需系统权限，当前仅支持接收」；
- 不投入 `notificationSubscribe` 尝试（三方签名必失败）。

## 4. 验收

- 宿主：`NotificationModels`/`NotificationPublishPlan` 单测（字段解析、isCancel、id 稳定、文案拼装、未知字段忽略）；
- 门禁：`hvigorw` + `run.sh` + 宿主通道；
- 真机（待设备）：桌面 `notify-send` → 手机通知栏出现（含 appName/正文）→ 关闭桌面通知 ⇒ 手机通知栏同步消失；断链 ⇒ 该设备通知全部消失。

## 4bis. 实施记录（2026-11-18）

| 项 | 状态 |
|---|---|
| N1 解析扩字段 + 取消同步 | ✅ 入库 `e4430ad`：`parseNotification`（item/cancel/drop 三分）+ `NotificationCancelPayload` + Index 消费；宿主 +7 例 |
| N2 系统通知栏 | ✅ 入库 `74a8755` / `4e845be`：`NotificationPublishPlan`（零 Kit：稳定 id/分组/文案/可发判定）+ `PeerNotificationPublisher`（唯一 Kit 层：授权一次、publish/cancel/cancelDevice、按设备追踪已发 id）+ Index 接线（发布/取消/断链/清理/插件开关）；宿主 +5 例 |
| 插件级用例 | ✅ 入库 `2ae4367`：`isCancel` ⇒ `notificationCancel`（带 deviceId+id）、无 id 丢弃、title/text/ticker 映射 |
| 设备侧（ohemu） | ✅ 218 例 / 0 失败（含上述新增；`aa test` 需先 `aa start` 应用，见 EMULATOR_NOTES §7） |
| **真机通知栏行为** | ⏳ **待设备**：桌面 `notify-send` → 手机通知栏出现（`KDC-Notif published`）→ 桌面关闭 ⇒ 同步消失（`cancelDevice`）→ 断链清空；hilog 判据已加（`KDC-Notif system notifications enabled=… / published id=… / cancelDevice dev=… count=…`） |

## 5. 明确不做

- 手机通知 → 桌面（平台系统接口，三方不可用）；
- 通知回复/动作回传（桌面端方向不支持）；
- 通知持久化（沿用会话内，桌面版同口径）。
