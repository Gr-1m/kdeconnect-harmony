# 01 参考实现分析（Android / iOS / 桌面 / 协议规范）

> 本文是 kdeconnect-oh 的**事实底座**：全部结论均带源码引用，供 clean-room 实现与后续 Agent 任务直接引用。
> 路径前缀：`kde/` = `kdeconnect-kde-master/`，`and/` = `kdeconnect-android-master/src/main/java/org/kde/kdeconnect/`，`ios/` = `kdeconnect-ios-master/KDE Connect/KDE Connect/`，`meta/` = `kdeconnect-meta-work-protocol-schemas/`。
> 上游四棵树为只读参考，禁止修改（见 `03-development-plan.md` §9 与工作区 AGENTS.md 贡献政策）。

## 1. 协议线规格（EXACT，clean-room 实现必须逐字节对齐）

三端一致的公共规格（各端实现差异见 §5）：

| 项 | 值 | 证据 |
|---|---|---|
| 包格式 | 紧凑 JSON 对象 + 单个 `\n`(0x0A) 终止符 | kde/core/networkpacket.cpp:43-60；and/NetworkPacket.kt:204-219；ios NetworkPacket.m:160-183 |
| 顶层键 | `id`（发送方毫秒 Unix 时间戳）、`type`、`body`；有 payload 时追加 `payloadSize`、`payloadTransferInfo` | kde networkpacket.cpp:45-52 |
| 键序 | 插入顺序 `id, type, body[, payloadSize, payloadTransferInfo]`（JSON 对象键序不影响解析，但保持一致便于 diff） | 同上 |
| payloadSize 语义 | qint64；`-1` 表示无尽流（fire-and-forget）；`0` 视为无 payload | kde networkpacket.h:120-148；and NetworkPacket.kt:226-228 |
| payloadTransferInfo | LAN 后端为 `{"port": <int>}` | kde compositeuploadjob.cpp:100-105；and LanLink.java:139-142 |
| payload 通道 | **独立的每传输 TLS 连接**（不复用主 socket）：发送方监听 1739-1764 端口并把端口写进包；接收方主动连入后按 payloadSize 读原始字节流（4096 字节块写，无应用层帧头） | kde landevicelink.cpp:126-146、compositeuploadjob.cpp:76-105、uploadjob.cpp:64-69；and LanLink.java:203-255 |
| 协议包类型 | 仅 `kdeconnect.identity` 与 `kdeconnect.pair` 可在未配对时收发 | kde networkpacket.h:150-153 |
| 发现 | UDP 1716 广播 identity 包（明文），body 额外含 `tcpPort` | kde lanlinkprovider.cpp:214-216；and LanLinkProvider.java:506-509 |
| 主链路 | TCP 1716 起顺序绑定至 1764；所有包走此 TLS 连接，按行读取 | kde lanlinkprovider.h:67-69；and LanLinkProvider.java:447-483 |
| 多文件头包 | 发送方在 header 包中附加 `numberOfFiles`、`totalPayloadSize`；进度用 `kdeconnect.share.request.update` | kde compositeuploadjob.cpp:92-94, 211-218 |
| 协议版本 | 当前 8（三端一致）；identity schema 枚举 `[7,8]` | kde networkpacket.cpp:33；and DeviceHelper.kt:30；ios KdeConnectSettings.swift:22；meta/schemas/kdeconnect.identity.json:84-87 |

## 2. 发现、建链与 TLS 角色矩阵（实现者最易踩的坑）

流程（v8）：

1. 设备 A 向 `255.255.255.255:1716` 广播 identity（含 `tcpPort`）；仅在可信网络时广播（and LanLinkProvider.java:366-368）。
2. 设备 B 收到广播：丢弃非私有地址源、限速检查、解析并校验 identity（tcpPort 必须在 1716-1764），然后**主动向 A 的 tcpPort 发起 TCP 连接**，连接成功后立即写入自己的 identity，附加 `targetDeviceId`（对方 id）与 `targetProtocolVersion`（对方版本） | and LanLinkProvider.java:214-261；kde lanlinkprovider.cpp:328-373。
3. A 的 TCP 监听端先读到 B 的 identity，校验 `targetDeviceId`（若存在必须是自己）与 `targetProtocolVersion`（若存在必须等于自己的版本），否则断开 | and LanLinkProvider.java:174-183；kde lanlinkprovider.cpp:536-546。
4. TLS 握手（角色见下表）。
5. **v8 增补**：TLS 建立后双方在加密信道内**再各发一次 identity** 并互相校验 deviceId / protocolVersion 与明文阶段一致，防止中途替换 | kde lanlinkprovider.cpp:411-445；and LanLinkProvider.java:311-340（iOS LanLinkProvider.m:46-70, 622-630）。
6. 对端证书取自 TLS 握手（`event.getPeerCertificates()[0]`），**不进 identity 包** | and LanLinkProvider.java:341-345。

TLS 角色矩阵（**桌面/Android/iOS 三端源码交叉验证一致**）：

| 场景 | TCP 角色 | TLS 角色 | 证据 |
|---|---|---|---|
| 我发广播，对方来连我 | TCP server（监听 1716-1764） | **TLS client**（`startClientEncryption` / clientMode=true / `kCFStreamSSLIsServer=0`） | kde lanlinkprovider.cpp:565-573；and LanLinkProvider.java:305-307 + tcpPacketReceived 传 `ConnectionStarted.Locally`(:185)；ios LanLinkProvider.m:519-529 |
| 我收到广播，我去连对方 | TCP client | **TLS server**（`startServerEncryption` / clientMode=false / `kCFStreamSSLIsServer=YES`） | kde lanlinkprovider.cpp:384-391；and LanLinkProvider.java:216-261 传 `ConnectionStarted.Remotely`(:261)；ios LanLinkProvider.m:436-465 |

> 这是**有意的角色反转**：TCP 发起方在同一条已建立的 TCP 连接上做 TLS 服务端。任何「TCP 发起方 = TLS 客户端」的直觉实现都会与三端握手失败。该反转也决定了平台 TLS API 能否胜任（05 §3.1：ArkTS TLSSocket 不能）。

> 命名陷阱：Android 的 `ConnectionStarted.Locally` 指「这条链路因**我方**广播而建立」（对方连我），不是「我发起了 TCP 连接」。clean-room 实现不要沿用该命名。

TLS 信任模型（TOFU + 配对后 pin）：

- 本端始终提供自签证书 + 私钥（mTLS 双向）；TLS 服务端一侧**要求**客户端证书（Android 未配对 `wantClientAuth`、已配对 `needClientAuth`，and SslHelper.kt:181-185；iOS `kAlwaysAuthenticate`，ios LanLinkProvider.m:459） | kde lanlinkprovider.cpp:589-595
- 协议版本：Android 的 `SSLContext.getInstance("TLSv1.2")` 注明「TLS 1.3 在部分（较老）设备有问题」，即 Android 端实际上限 TLS 1.2 | and SslHelper.kt:166
- **未配对**：不校验对端证书（Qt `QueryPeer`；Android 自定义 TrustManager；iOS 手动 trust 评估直接放行新设备） | kde lanlinkprovider.cpp:596-602；ios CertificateService.swift:187-204
- **已配对**：以存储的对端证书为唯一 CA + `VerifyPeer`；`setPeerVerifyName(deviceId)`；iOS 为 DER 逐字节比对且要求 trust 链恰好 1 张证书 | kde lanlinkprovider.cpp:596-599, 604；ios CertificateService.swift:187-227
- 附加校验：证书 `subjectDisplayName()` == identity 的 deviceId，否则断开 | kde lanlinkprovider.cpp:644-648
- 链路替换时新旧证书必须相同，否则中止（防重放换证书） | kde lanlinkprovider.cpp:660-663；and LanLinkProvider.java:371-373
- Qt 侧 sslErrors：仅 `SelfSignedCertificate` 可忽略，其余 fatal | kde lanlinkprovider.cpp:456-473
- payload 通道的 TLS 同样按「已配对」模式校验 | and LanLink.java:204-205, 253-255

## 3. 配对状态机与 verification key

- 状态：`NotPaired / Requested / RequestedByPeer / Paired` | and PairingHandler.kt:23-28；ios Device.h:51-57
- pair 包：`{"pair": bool}`；v8 起请求方附加 `timestamp`（Unix 秒） | meta/schemas/kdeconnect.pair.json:33-51
- `pair=true` 同时表示「请求」与「接受」（同形包），因此不能对已配对设备的再次 pair 请求自动接受，需先 unpair 再处理 | kde pairinghandler.cpp:42-49
- v8 校验：timestamp 必须存在且与本地时钟差 <= 1800s（30 分钟），否则配对失败 | kde pairinghandler.cpp:51-63；and PairingHandler.kt:71-80；ios Device.m:261-270
- 超时：接收方等用户 25s；发起方等对端 30s | and PairingHandler.kt:88-92, 167-171
- **verification key（SAS，v8 已三端实现）**：`SHA-256( 较大公钥DER ‖ 较小公钥DER ‖ timestamp 十进制字符串 )` 取**前 8 个 hex 字符大写**。「较大」按无符号字节序比较，**较大者在前**（桌面 `if (a < b) swap` 后先 a 后 b；Android `compareUnsigned(a,b) < 0` 时返回 `b + a`；iOS `remote.lexicographicallyPrecedes(local)` 时 `local + remote`）。双端各自显示同一值供用户肉眼比对。已知答案向量与「写反顺序」的错误值见 06 §2.5 | kde pairinghandler.cpp:179-198；and PairingHandler.kt:231-250；ios CertificateService.swift:103-124（iOS UI：DevicesView.swift:220, 319-321）
- 收到非协议包且未配对 -> 主动 unpair 并丢弃 | kde device.cpp:396-399；and Device.kt（Device.m:288-295 iOS 同）
- 未配对设备不可达 1s 后从列表删除 | and KdeConnect.kt:188-210

## 4. 身份与密钥材料

- deviceId：UUIDv4 去连字符（32 字符），必须匹配 `^[a-zA-Z0-9_-]{32,38}$` | and DeviceHelper.kt:34, 135-136；meta identity schema:52-55；iOS 用 `identifierForVendor`（ios KdeConnectSettings.swift:65-66）
- deviceName：过滤 `["',;:.!?()\[\]<>]` + 截 32 字符，非空 | kde deviceinfo.h:144-149
- deviceType 枚举：desktop/laptop/phone/tablet/tv（`smartphone` 兼容映射 phone） | meta identity schema:60-70；kde deviceinfo.h:34-35
- identity body 必填：`deviceId, deviceName, deviceType, incomingCapabilities, outgoingCapabilities, protocolVersion` | meta identity schema:39-46
- 密钥对：**当前默认 EC P-256**（三端），RSA-2048 为兼容保留 | kde sslhelper.cpp:24-97；and RsaHelper.kt:21-40；ios CertificateServiceHelper.m:49-73
- 自签证书：X.509 v3；Subject=Issuer：`CN=<deviceId>, O=KDE, OU=KDE Connect`；notBefore = 现在-1 年、notAfter = 现在+10 年；SHA-512 签名 | kde sslhelper.cpp:113-230；and SslHelper.kt:83-97；ios Helper.m:76-113
- 证书损坏/过期/ID 不匹配 -> 重新生成并**清空全部已配对设备** | kde kdeconnectconfig.cpp:296-339；and SslHelper.kt:57-71
- 能力协商：`incomingCapabilities` = 本端能**收**的包类型集合，`outgoingCapabilities` = 本端能**发**的集合；插件匹配 = 插件的 supportedPacketTypes 与对端 outgoing 求交，或插件的 outgoingPacketTypes 与对端 incoming 求交，任一非空即支持（不要求两端都启用插件） | and PluginFactory.kt:62-69；kde device.cpp:321-328
- 发送前校验：非协议包必须在对端 incomingCapabilities 中，否则不发 | kde device.cpp:368-372
- 插件启用：per-device 配置，键 `<pluginKey>Enabled`，缺省取插件元数据 `isEnabledByDefault`；加载条件 `(已配对 || listensToUnpaired) && 可达 && enabled` | kde device.cpp:433-455；and Device.kt:641

## 5. 三端防御参数对照（安全基线，OH 实现直接采用）

| 参数 | 桌面 | Android | iOS | OH 采用 |
|---|---|---|---|---|
| identity 收包上限 | 8192B | 512KiB | 8192B | **8192B**（更严格；正文 identity 实测约 2000B） |
| 普通包上限 | 32MiB | 32MiB | 32MiB | 32MiB |
| 未配对并发连接上限 | 42 | 未显式 | 未显式 | 42 |
| 同设备重连限速 | 500ms | 1000ms | 500ms | 500ms |
| 限速表条目上限 | - | 255 | - | 256 |
| UDP 源地址 | - | 仅私有地址 | 忽略 IPv4-mapped | 仅私有地址 |
| 逐字节行读（防缓冲读越界） | - | 是 | - | 是 |
| 私钥存储 | PEM 文件（strict 权限） | SharedPreferences Base64（**明文**，未用 Keystore） | Keychain（PKCS12） | Asset Store Kit（加密），见 04 |
| 对端证书存储 | KConfig 按 deviceId 存 PEM | SharedPreferences | Keychain | RDB/Preferences + native 侧副本 |
| 协议降级拒绝（已配对设备版本回退） | 是 | 是 | 是 | 是 |
| 信任网络（SSID 白名单） | - | 是（默认 trust_all，无定位权限时强制 trust_all） | - | 是（默认 trust_all） |

## 6. Android 实现要点（作为「全功能形态」参照）

- 进程模型：`KdeConnect`(Application) 初始化 deviceId/密钥/证书/PluginFactory -> `BackgroundService` 前台服务（`foregroundServiceType=connectedDevice`，`START_STICKY`）持有 LanLinkProvider | and KdeConnect.kt:48-54；BackgroundService.kt:196-215
- 开机自启：`BOOT_COMPLETED`/`MY_PACKAGE_REPLACED`/`CONNECTIVITY_CHANGE` receiver | AndroidManifest.xml:184-197
- 网络监听：ConnectivityManager 回调（WiFi/VPN/以太网/蓝牙传输）触发重广播 | BackgroundService.kt:119-140
- 重连策略：**无独立重连定时器**；依赖 UDP 收包、网络变化、SCREEN_ON 触发重新广播；读线程 socket 关闭后 sleep 300ms 等新 socket | and LanLinkProvider.java:566-570；LanLink.java:78-86
- 插件契约：`setContext -> isCompatible -> checkRequiredPermissions -> onCreate -> onPacketReceived -> onDestroy`；`supportedPacketTypes`(收)/`outgoingPacketTypes`(发) | and Plugin.kt:143-198
- mDNS 辅助发现：`_kdeconnect._udp`，TXT 字段 id/name/type/protocol（**无法携带证书**，仅引导连接） | and MdnsDiscovery.kt:127-135
- 权限面（AndroidManifest.xml:30-67，40+ 项）：INTERNET、ACCESS_LOCAL_NETWORK、FOREGROUND_SERVICE_CONNECTED_DEVICE、READ_PHONE_STATE、READ_CONTACTS、SEND/READ/RECEIVE_SMS、RECEIVE_MMS、READ_CALL_LOG、MANAGE_EXTERNAL_STORAGE、POST_NOTIFICATIONS、SYSTEM_ALERT_WINDOW、CAMERA、RECORD_AUDIO 等

关键插件机制（Android 全功能形态）：

| 插件 | Android 机制 | 包类型 |
|---|---|---|
| mousepad（控制桌面） | 仅发送 `kdeconnect.mousepad.request`（dx/dy/clicks/key/specialKey/修饰键）；键盘经 `KeyListenerView`+IME `commitText` 捕获；无需权限 | mousepad.request / keyboardstate / echo |
| mousereceiver（桌面控手机） | AccessibilityService 注入 | 同上 |
| mpris 接收端（桌面控手机媒体） | `MediaSessionManager.getActiveSessions`，**依赖通知监听权限** | mpris / mpris.request |
| sftp | Apache MINA SSHD 服务器；host key 复用设备密钥对；用户名固定 `kdeconnect`；密码 `randomString(28)` 每次浏览重生成、SHA-256 摘要 + 恒时比较；公钥认证仅接受已配对设备公钥；端口 1739-1764；存储经 MANAGE_EXTERNAL_STORAGE 或 SAF | sftp / sftp.request |
| share | 收文件存公共下载目录（"open" 立即打开的）或用户配置目录；冲突重命名；FileProvider 提供内容 URI | share.request(.update) |
| battery | `ACTION_BATTERY_CHANGED` 粘性广播；字段 currentCharge/isCharging/thresholdEvent | battery(.request) |
| notifications | NotificationListenerService 全量转发 + 图标 payload（SHA-256 哈希校验）+ 回复/动作回传 | notification(.action/.reply/.request) |
| telephony/sms | PHONE_STATE 广播 + SMS 广播 + ContentObserver | telephony / sms.* |
| runcommand | 远程触发本地命令列表（key 索引，无任意命令） | runcommand(.request) |

## 7. iOS 实现要点（**受限平台降级模式的直接范本**）

iOS 与 OpenHarmony 面临同类封锁（无通知监听、无全局输入注入、后台受限），其应对策略是 OH 的首选参照：

- 架构：ObjC 核心（GCDAsyncSocket）+ Swift 插件/UI（SwiftUI），桥接头混编 | ios project.pbxproj:1096
- **TLS 信任 = 自定义手动 trust 评估**（`GCDAsyncSocketManuallyEvaluateTrust` + delegate 比对证书字节），未用系统默认验证 —— 与 KDE 协议的 TOFU+pin 语义唯一可行的对齐方式 | ios LanLinkProvider.m:659-670；CertificateService.swift:187-227
- **后台策略：无 socket 存活方案**——进后台 `stopDiscovery()`（激进断开），回前台 `refreshDiscovery()`；文件传输中依赖 VoIP 类后台 socket（现代 iOS 是否生效存疑） | ios KDE_Connect_App.swift:70-87
- 插件子集（8 个）：Ping、Battery（UIDevice 公开 API）、Share（相册 addOnly + Files）、Clipboard（仅前台）、FindMyPhone（app 内声音/触觉）、RemoteInput（UIKeyInput 捕获 + 发送 mousepad.request）、Presenter、RunCommand —— **全部是「发送方向 + 本地公开能力」** | ios Plugins 目录
- 通知替代：不用 UNUserNotificationCenter 推事件，用 app 内 NotificationCenter + alert（pair 请求、收文件、寻机） | ios ConnectedDevicesViewModel.swift:17-20
- 配对 UI 双端显示 verification key | ios DevicesView.swift:220, 319-321
- 教训：无任何协议单测（模板空壳）—— OH 工程必须补协议层测试 | ios KDE_Connect_Tests.swift:22-36

## 8. 包类型全集（meta/schemas/ 45 个 schema）

顶层：kdeconnect / identity / pair。功能域：battery(.request)、clipboard(.connect)、connectivity_report(.request)、contacts.*（4 个）、findmyphone.request、lock(.request)、mousepad.echo/keyboardstate/request、mpris(.request)、notification(.action/.reply/.request)、ping、presenter、runcommand(.request)、sftp(.request)、share.request(.update)、sms.*（6 个）、systemvolume(.request)、telephony(/.request_mute)。

每个 schema 定义 body 字段类型与必填性；实现某插件前必须先读对应 schema（`meta/schemas/kdeconnect.<type>.json`）并以 `make check` 确认的 `protocol.md` 为对照。

## 9. 三端分歧点与 OH 决策

| 分歧 | 决策 | 理由 |
|---|---|---|
| identity 上限 8KiB vs 512KiB | 取 8KiB | 更严格无害；实测 identity 约 2KB |
| 私钥存储级别 | Asset Store Kit | 高于 Android 基线（明文 Prefs），接近 iOS Keychain |
| 蓝牙后端（桌面/Android master 均有，基于自定义复用协议 `Multiplexing protocol.md`） | v1 不做 | 桌面侧蓝牙后端长期未达稳定；LAN 已覆盖主场景 |
| mDNS 辅助发现 | v1 不做，v2 评估（OH 有 `@ohos.net.mdns`） | UDP 广播已满足发现；mDNS TXT 无法携带证书，仅省广播 |
| mousepad 特殊键表 | 以桌面表为权威（各 remoteinput 实现注释「keep in sync within all the implementations」，kde plugins/mousepad/waylandremoteinput.cpp:26-61）：1=Backspace, 2=Tab, 3=Linefeed, 4=Left, 5=Up, 6=Right, 7=Down, 8=PgUp, 9=PgDn, 10=Home, 11=End, 12=Enter, 13=Delete, 14=Esc, 15=SysRq, 16=ScrollLock, 17=Ctrl, 18=Alt, 19=Shift, 20=Meta, 21..32=F1..F12；接收端只接受 `0 < specialKey < 33`。Android 表（KeyListenerView.java:24-62）用 `++i` 计数，F12 实发 32（行内注释「// 21」是陈旧注释，非行为） | clean-room 兼容必需；OH 发送端按桌面表编码 |
| SFTP 认证 | 复刻 Android：公钥（仅已配对设备）+ 一次性密码（28 字符 CSPRNG），password 字段仍发送（桌面 sshfs 需要） | 协议 schema 标注 password deprecated 但桌面 master 仍消费 |

## 10. 许可证注意

- Android 端 LICENSES 目录含 GPL-2.0-only / GPL-3.0-only / Apache-2.0 / LicenseRef-KDE-Accepted-GPL 混合；桌面核心 GPL-2+；iOS GPL；meta 仓库的 schema2md.py 为 CC0。
- 本项目策略：**协议实现为 clean-room**（依据本文档化的协议事实与 meta 的 JSON schema 重写，不逐行移植源码）。若未来分发且引用/翻译了 GPL 实现代码，需整体按 GPL 处理；协议规格本身（字段/端口/算法常量）不属于任何代码许可的独占内容。
- KDE Connect 商标与名称归属 KDE；分发前确认命名（"kdeconnect-oh" 为内部代号）。
