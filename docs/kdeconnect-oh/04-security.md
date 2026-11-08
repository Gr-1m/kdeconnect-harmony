# 04 安全设计规范

> 上游：`00-README.md`。威胁模型基于 01 §5/§6/§7 的实测防御参数与 KDE Connect 信任模型；OH 平台侧基于 02 §1 已核实事实。本文与 03 §9 红线联动，是代码审查的强制依据。

## 1. 资产与信任边界

| 资产 | 位置 | 威胁主体 |
|---|---|---|
| 设备私钥（身份根） | Asset Store | 本机恶意应用（沙箱隔离 + 系统加密）、物理提取 |
| 已配对设备证书表 | RDB | 本机篡改（换证书=劫持链路） |
| 传输内容（文件/剪贴板/通知/SMS 域） | TLS 信道 | 局域网内的主动攻击者（MITM/注入/DoS） |
| 首次配对信道 | 未验证 TLS | 局域网 MITM（SAS 比对是唯一防线） |
| SFTP 一次性凭据 | TLS 信道 | 已配对设备之外的局域网嗅探者 |
| 用户数据落盘（接收文件/通知缓存） | 应用沙箱 | 本机/物理提取 |
| 供应链（Rust crates / ohpm） | 构建期 | 恶意依赖 |

信任边界：**已配对设备 = 全信任**（KDE 模型：无 per-plugin 鉴权）。因此「配对准入」与「配对后证书 pin」是全部安全的锚点。

## 2. 威胁模型（LAN 攻击者 A）

| 场景 | 攻击 | 现有防御（01 引证） | OH 实现要求 |
|---|---|---|---|
| T1 | A 伪造 UDP identity 冒充他人/刷设备列表 | 限速 500ms/设备、255 条目、SSID 白名单、未配对连接上限 42（kde lanlinkprovider.cpp:42-47） | 全量复刻 + 未配对设备 UI 醒目标识 |
| T2 | A 在首次配对时 MITM（双向代理两条 TLS） | SAS verification key（8 hex）双端显示（kde pairinghandler.cpp:179-198） | **强制 UI 比对流程**：配对对话框双方并排显示 key；不做「自动信任」；文案要求用户比对 |
| T3 | A 重放旧 pair 包 | v8 timestamp ±1800s（kde pairinghandler.cpp:51-63） | 复刻；时钟漂移给用户明确错误提示 |
| T4 | 已配对后 A 尝试降级/换证书 | 证书 pin（DER 相等）+ CN=deviceId + 链路替换证书必须相同 + 协议版本降级拒绝（kde lanlinkprovider.cpp:596-608, 644-648, 660-663） | 全量复刻；**除此之外**加：pin 比较失败即断链 + 记入设备档案告警计数 |
| T5 | 恶意流量打崩引擎（超大包/畸形 JSON/半包/证书炸弹） | 8KiB identity / 32MiB 行 / 逐字节分帧（01 §5） | 复刻 + fuzz 门（§6）；解析面在 Rust 安全抽象内 |
| T6 | A 伪造 payload 端口/抢连 | payload 通道同证书校验（and LanLink.java:204-205） | payload TLS 与主链路同 pin 逻辑；连接先做证书校验再进入传输 |
| T7 | SFTP 凭据泄露后爆破 | 一次性密码 28 字符 + 恒时比较 + 公钥白名单（and SimpleSftpServer.kt:195-218） | 复刻；密码仅经 TLS 信道发送；浏览结束即失效 |
| T8 | 配对设备被攻陷后横向利用（runcommand 执行/文件读） | KDE 模型接受此风险（全信任） | OH 沙箱天然限制爆炸半径；runcommand 仅沙箱内 childProcess；命令列表无远程写入口 |
| T9 | 恶意 HAP 重打包 | OH 强制签名 + 完整性校验 | 只做标准签名流程；release 关闭 hdc 调试面 |

## 3. 平台安全设计决策

1. **私钥**：v1 = 私钥（PKCS#8 DER）存 Asset Store Kit（TEE 托管密钥加密，仅本应用可解）；证书（公开数据）存应用沙箱 `filesDir`。约束：Asset Store 单条秘密上限 1024 字节（[Asset 文档](https://github.com/pablezhang/harmonyOS/blob/master/en/application-dev/reference/apis-asset-store-kit/js-apis-asset-sys.md)），P-256 私钥 PEM 实测 241 字节、DER 138 字节可存；**RSA-2048 私钥超限**——因此本端只生成 P-256（与三端当前默认一致，01 §4），RSA 仅作为**对端**证书类型被接受。v2 演进 = HUKS 非导出密钥 + rustls 自定义 `SigningKey`（握手签名在 TEE 内完成）——旧套件 15 号文档问题 1 的「方案 B」在 Rust 栈下有了实现路径，因为签名不再经过 ArkTS `TLSSecureOptions.key`。禁止：明文 Preferences、明文文件。
2. **证书重生成 -> 全部解配对**（对齐 kde kdeconnectconfig.cpp:296-339，防止新旧身份混用）。
3. **权限最小集**（对照 Android 的 40+ 项做裁剪）：

| 权限 | 用途 | 级别 |
|---|---|---|
| ohos.permission.KEEP_BACKGROUND_RUNNING | 长时任务 | normal/system_grant |
| ohos.permission.GET_WIFI_INFO | 信任网络 SSID | normal/system_grant |
| ohos.permission.INTERNET | socket | normal |
| 通知授权（requestEnableNotification，非静态权限） | findmyphone/notifications RX | 用户动态授权 |
| 相册写入（photoAccessHelper 用户授权） | share 保存选项 | 用户动态授权 |
| 联系人（仅 Phase 2 末评估 contacts 时申请） | contacts 插件 | 用户动态授权 |
| ohos.permission.READ_PASTEBOARD | clipboard 后台读取（OH->桌面方向自动同步） | **受限 user_grant（ACL）**：需应用市场 ACL 审批，普通应用默认拿不到 |

  声明即申请的权限只有 3 个 normal 级；其余全部运行时按需。**不得**申请与本能力矩阵无关的权限（04 §8 红线 4）。
  剪贴板读取的 v1 方案：用 `PasteButton` 安全控件（用户点击即授权单次读取，无需声明权限），即 OH->桌面方向为「用户点一次发一次」；`READ_PASTEBOARD` 仅在 ACL 审批通过后启用自动同步。桌面->OH 方向（写剪贴板）不受限。来源：[剪贴板权限指南](https://gitcode.com/openharmony/docs/blob/weekly_20250414/en/application-dev/basic-services/pasteboard/get-pastedata-permission-guidelines.md)。
4. **网络**：除协议固有的 UDP 1716 明文 identity（内容本就是公开宣告信息）外，全部流量 TLS。版本策略：作为 TLS 服务端接受 1.2/1.3；作为 TLS 客户端最高 1.2（对齐 Android 端 `SSLContext("TLSv1.2")` 的兼容性注释，01 §2）；rustls 只含 AEAD 套件，无需额外禁用弱套件。
5. **剪贴板/通知/文件等隐私数据**：不落明文日志；接收文件默认沙箱 + 用户显式选择才入公共媒体库。

## 4. 代码规范（按语言）

**Rust（kc-core/kc-lan/kc-sftp）**：
- `unsafe` 禁止，除非 NAPI 边界必需且逐行注释理由 + 审查清单通过。
- 无 `unwrap/expect` 于任何处理远端输入的路径（错误统一 `thiserror` 枚举上抛）。
- 解析前先限额（长度/计数/深度），serde 严格模式；拒绝未知字段可放宽（前向兼容）但字段类型不符必须报错。
- panic = bug：NAPI 边界 catch_unwind + 上抛事件 + 断链该设备（不崩宿主进程）。
- 随机数只用 `getrandom`/`ring`（一次性密码、deviceId）。

**ArkTS**：
- 全部 `arkts-*` lint 规则开满；不用 ESObject 兜协议类型。
- NAPI 回调里的异常不得静默吞掉——一律转 `onLog` 事件。
- 敏感字段（剪贴板内容、通知正文、SFTP 密码）不进 hilog。

**C++（仅缝隙）**：RAII；无 raw new；边界类型显式宽度（int32_t 等）；与 NAPI 交界处全部判空。

## 5. 日志与可观测性

- 分级：error/warn/info/debug；release 构建强制 >= warn 且**不打印包 body**（只打 type 与 deviceId）。debug 构建打印 body 需编译期开关 + 设置页二次确认（对齐桌面 `KDECONNECT_DEBUG` 惯例但更严格）。
- `onLog` 事件统一走 NAPI 上抛 ArkTS hilog，禁止 native 侧直接 fprintf 到 stdout。

## 6. 供应链

- Rust：`Cargo.lock` 提交；`cargo deny`（licenses/bans/duplicates/sources）+ `cargo audit` CI 必跑；crate 引入需在 PR/任务卡登记用途与替代评估；rustls/ring/russh/serde_json/tokio 之外的依赖逐一审查。
- ohpm：`oh-package-lock` 提交；依赖最小化（UI 层尽量只用系统 Kit）。
- 构建环境：锁 Rust 工具链版本（rust-toolchain.toml）；CI 不允许构建期联网拉新依赖。

## 7. 验证要求（Phase 4 门，部分前置）

- **Fuzz 目标清单**（cargo-fuzz，coverage 记录阈值：分帧器 90%+，JSON 映射 85%+）：行分帧、unserialize、identity 校验、pair timestamp 边界、SFTP 子系统封装、证书 DER 提取。
- **渗透用例**（L2 Go 对端编排，03 §7）：T1-T7 逐场景脚本化，断言「被拒且不崩」；半开连接泄漏检查（fd 计数）；配对中暴力 cancel/unpair 竞态。
- **回归红线**：任何 fuzz crash、任何 ASAN 报告 = 阻断发布。

## 8. 红线清单（NEVER，违反即任务失败）

1. NEVER 弱化/跳过 SAS verification key 的用户比对流程（不得「为了体验」自动接受配对）。
2. NEVER 在未配对状态下接受非 `kdeconnect.identity/pair` 的包。
3. NEVER 私钥明文落盘或写日志；NEVER 证书 pin 比较降级为「忽略错误继续」。
4. NEVER 申请能力矩阵之外的系统权限；NEVER 在用户未触发时请求运行时授权。
5. NEVER 解析先于限额（任何来自网络的字节先进长度/条数检查）。
6. NEVER 在 release 日志输出 body/凭据/剪贴板/通知正文。
7. NEVER 引入未经登记与审查的网络来源依赖；NEVER 构建期拉新依赖。
8. NEVER 对上游 KDE 树做任何修改或提交；NEVER 绕过决策门实现受门控功能。

## 9. 已知并明确接受的风险（诚实披露，写入应用文档）

1. 配对后设备全信任：runcommand/sftp 等能力对已配对设备无二次鉴权（KDE 模型固有；缓解=命令列表本地配置 + SFTP 沙箱范围）。
2. 协议无包级时间戳/防重放（`id` 字段三端均不校验）：接受，与上游一致；影响限于幂等包的重复投递。
3. UDP identity 明文广播（协议固有）：泄露设备名/能力清单，不含密钥材料；SSID 白名单可缓解。
4. OH 侧无开机自启（第三方限制）：设备重启后连接需用户打开应用一次。
5. inputEventClient 系统应用限制：桌面控制手机方向功能不存在（能力矩阵已裁剪）。
