# FEATURE_GAP.md — 功能差距盘点：Android/iOS 已实现 vs 鸿蒙端（KDE-H Connect）

> 2026-09-19。盘点人 Atomcode。方法：Android 插件目录全清单（26 项，`kdeconnect-android/src/main/java/org/kde/kdeconnect/plugins/`）逐项对照本项目 `entry/src/main/ets/plugins/`（15 个 .ets），方向（收/发）按各插件 `outgoingPacketTypes` 实核；iOS 支持度按 docs/11 功能点字典与 docs/12。**协议类型以 `kdeconnect-meta/schemas/` 为准，新增前先改 schema + `make check`。**

## 一、已实现（10 项功能 / 15 个文件）

电池、剪贴板（双向+回环防护）、ConnectivityReport、FindMyPhone（收 ringing）、MPRIS 控制+遥控、Ping、RunCommand、Share 文件收发、SystemVolume、RemoteInput（**仅发送** mousepad.request）。

## 二、未实现清单（按落地价值排序）

| # | 功能 | packet type | Android | iOS | 落地说明 |
|---|---|---|---|---|---|
| 1 | **收通知**（receivenotifications） | `kdeconnect.notifications` | ✅ | ✅ | **价值最高**。我方 NotificationPlugin 只有 request 方向；「手机通知同步到电脑」是 KDE Connect 招牌功能。协议简单（body: 通知字段+动作），Android 参考实现可直接对照 |
| 2 | **电话/短信**（telephony+sms） | `kdeconnect.telephony` / `kdeconnect.sms` | ✅ | ✅部分 | 第二招牌功能：来电提醒、短信读取/回复。**前置**：先查鸿蒙 contact/telephony API 可达性（可能涉及权限/受限开放），不可达则降级「仅来电响铃提醒」 |
| 3 | **查找远程设备**（findremotedevice） | ringing 请求（发） | ✅ | ❌ | 我方 FindMyPhonePlugin 只收不发的反向；补发送侧是小改动（让电脑响铃） |
| 4 | **鼠标接收**（mousereceiver/digitizer） | `kdeconnect.mousepad.request`（收） | ✅ | ✅ | 我方 RemoteInput 只发不收；手机当电脑触控板需接收侧。依赖系统级鼠标注入 API 可行性 |
| 5 | **MPRIS 接收**（mprisreceiver） | 电脑→手机媒体信息 | ✅ | ❌ | 手机当遥控器已实现；「电脑正在播放推手机」缺 |
| 6 | **远程键盘**（remotekeyboard/ime） | `kdeconnect.remotekeyboard` | ✅ | ❌ | 手机当电脑键盘。**单独立项**：依赖鸿蒙输入法（IME）API，工程量大 |
| 7 | **presenter**（演示翻页） | mousepad/presenter | ✅ | ❌ | 低优先级；#4/#6 落地后自然获得 |
| 8 | **剪贴板自动推送时机** | `kdeconnect.clipboard.connect` 时机 | ✅ | ✅ | 基础双向已有；「剪贴板变化即推」的触发链路是否对齐 Android 需真机走查（此项是走查项，非新功能） |
| 9 | **联系人**（contacts） | `kdeconnect.contacts` | ✅ | ❌ | v8 协议相关（配对验证码流程用到）；暂缓，配对主链路不依赖我方作为请求方 |
| 10 | **SFTP**（sftp） | `kdeconnect.sftp` | ✅ | ❌ | **建议明确不做**：依赖对端 sshd，鸿蒙侧无 sshd，Share 已覆盖文件传输需求。写进决策记录 |
| 11 | **锁定远程设备**（lockdevice） | `kdeconnect.lock` / `kdeconnect.lock.request` | ❌ | ❌ | **唯一「Android/iOS 双端皆缺」的完整功能插件**（2026-09-19 补充盘点）。桌面 KDE 已实现（`plugins/lockdevice`，含 Windows 实现）。协议极简（lock.request 带 `{lock: true/false}`）；鸿蒙锁屏 API 可行性需调研（设备管理类 API 受限），「上报锁屏状态」方向较容易 |
| 12 | **mDNS 发现通道**（discovery_mdns） | mDNS/Bonjour | ❌ | ✅ | 协议提供 UDP + mDNS 双发现通道；iOS 两通道齐全，Android 只有 UDP。我方现为 UDP 单通道，与 Android 同；mDNS 为可选增强（跨网段发现场景才需要） |

## 三、建议排期（供 CodeArts 裁决）

1. **#1 收通知**（价值最高、协议最简）；
2. **#2 电话/短信**（先做鸿蒙 API 可行性调研，再定范围）；
3. **#3 findremotedevice 发送侧 + #4 mousereceiver 接收侧**（小改动补双向）；
4. **#6 remotekeyboard**（单独立项，IME API 调研先行）；
5. **#9 contacts 暂缓、#10 sftp 不做**——写入 docs/15 决策记录。

## 四、盘点口径备注

- Android 的 `inputdevicesreceiver`/`remotekeyboardime` 属 #4/#6 的实现载体；`presenter` 同理；
- iOS 未实现 sftp/contacts/remotekeyboard/findremotedevice/presenter/mprisreceiver——与桌面生态差异较大，**我方以 Android 功能面为对照基准**（更贴近双端互通场景）；
- 常量三端一致约束（UDP 1716 / TCP 1716–1764 / payload ≥1739 / 单包 32MiB 等）见 AGENTS.md「跨端常量」——新插件落地时勿引入新常量漂移。

—— Atomcode（glm5.3-flash），评审工作负责人
