# 密钥管理架构评估：HUKS vs PEM（AtomCode — 安全架构与协议约束视角）

> 2026-10-11，AtomCode（qwen3.8-27b）。响应 CodeArts MSG138 §3 的 AtomCode 部分指派
> （安全架构与协议约束：威胁模型 / 证书钉扎 / 配对安全 / 跨端对齐）。
> Omp 部分 = `devdocs/KEY_MANAGEMENT_ANALYSIS_OMP.md`（native 实现可行性，MSG148 上报）。
> **本文是独立分析**：证据链与论证独立取证，对 Omp 文档有 2 处引文修正、3 处补充、1 处结论措辞更正（§5），
> 并给出 Omp 文档未覆盖的 **方案 A+（PEM + HUKS 保险库密钥）** 建议（§8.3）。
> 所有代码证据均带 `文件:行`（主线 `ea244d3` 状态）；平台证据为 `/opt/ohos-sdk/26` 头文件**独立核验**
> （未引用 Omp 转述）+ OpenHarmony 官方文档。

---

## 1. 范围与方法

- **范围**：方案 A（PEM 存应用沙箱，现状）vs 方案 B（HUKS TEE 密钥）；方案 C（混合：HUKS 生成 +
  握手时导出内存）——A/B 双方均已否定，本文 §7 给否定理由的独立确认。
- **视角分工**：Omp = 实现可行性（改造量/回调/维护）；**本文 = 安全架构（威胁建模）+ 协议约束
  （跨端对齐 / KDE 上游语义 / 用户体验）**。CodeArts 裁决时两文互为输入。
- **方法**：源码取证（file:line）→ 平台头文件独立核验 → 官方文档 → 跨端参考仓对比（Android 全证据；
  KDE 桌面参考仓本地不全，相应项如实标注未验证）。

## 2. 事实基础 A：现工程密钥链（取证）

| 环节 | 实现 | 证据 |
|---|---|---|
| 密钥生成 | `getrandom(2)` 熵（`/dev/urandom` 兜底）→ `br_ec_keygen` **EC P-256** → 手工 X.509 DER（CN=deviceId, secp256r1）→ ECDSA 自签 → PEM 双件 | `cert_gen.cpp:17-35, 137-138, 155-158, 247-250, 303-304` |
| 私钥存储 | **Preferences 明文**（`keyPem`/`certPem` 字符串，沙箱 `el2` 目录）；启动回读 | `Index.ets:159-160, 213-214, 234-243` |
| TLS 使用 | PEM→DER→`br_skey_decoder_get_ec`→内存 `br_ec_private_key`；**同一 EC 键双用途**：`BR_KEYTYPE_KEYX \| BR_KEYTYPE_SIGN`（ECDH 交换 + ECDSA 签名） | `tls_engine.cpp:137-178, 247-255` |
| 钉扎 | 首见 identity：**证书 DER 全字节相等**比较（TOFU+钉扎），不符 ⇒ 断链 + EACCES；入向连接派发前复核；payload 仅 trusted 设备 | `net_stack_link.cpp:330-346, 579-585, 460-475` |
| 信任持久化 | ArkTS TrustStore（`{schemaVersion, devices:[{id,name,certPem,pairedAt,paired}]}`）→ NAPI 回灌内存 `trustedCertPem_` | `TrustCodec.ets`、`net_stack.h:53-57` |
| 配对验证码 | `SHA256(按字节序排序的双方 SPKI DER ‖ 十进制 ts)` 前 8 位 hex 大写（v8 追加 ts） | `CRYPTO_VECTORS.md`（9 组向量独立来源复算 MATCH） |
| 证书有效期 | 日历周年 -1y → +10y（C2 修复，含闰日） | `cert_gen.cpp:247-250` |

**架构关键点（方案 B 必须回答）**：同一 EC 私钥同时承担 **SIGN**（TLS 1.2 ECDHE_ECDSA 证书签名）
与 **KEYX**（ECDH 密钥交换）两个用途 ⇒ 方案 B 的 HUKS 路径必须同时覆盖 SIGN 与 AGREE 两条操作链
（HUKS 头文件确认两者均支持，见 §3）。

## 3. 事实基础 B：HUKS 平台约束（独立核验，/opt/ohos-sdk/26）

### 3.1 API 面（头文件证据）

| 事实 | 证据 | 对方案 B 的意义 |
|---|---|---|
| 公钥可导出（X.509 DER 格式），**私钥无导出 API** | `native_huks_api.h:186` 仅 `OH_Huks_ExportPublicKeyItem`；全头无 `ExportPrivateKey` | 证书仍可自签生成（导出公钥→手工 X.509，同现路径） |
| NDK API 为**同步**会话式：`OH_Huks_InitSession` / `UpdateSession` / `FinishSession`，直接返回 `OH_Huks_Result`，**无回调参数** | `native_huks_api.h:361-453` | BearSSL 同步回调桥接**不需要异步改造**（修正 Omp"异步 API"表述）；真实代价 = 同步 TEE 调用阻塞 TLS 握手线程（§5 修正②） |
| 用途：ENCRYPT=1 / **SIGN=4** / **AGREE=256** | `native_huks_type.h:190/198/222` | SIGN+AGREE 双链均可表达（§2 架构关键点满足） |
| 算法：AES=1 / **ECC=2** / RSA=3 / **ECDH=100** / X25519=101 / ED25519=102 … | `native_huks_type.h:463-531` | 覆盖所需全集 |
| ECC 曲线：KEY_SIZE **224/256/384** | `native_huks_type.h:381-387`；官方文档 ECC 256/384/521（API 8+） | **P-256 与现工程一致** |
| 协商键生成/标记：`KEY_GENERATE_TYPE_AGREE=2` / `KEY_FLAG_AGREE_KEY=3` | `native_huks_type.h:596/617` | AGREE 链专用键可建 |
| `libhuks_ndk.z.so` 存在（aarch64-linux-ohos） | sysroot `usr/lib/` 实测 | OpenHarmony 侧链接可行 |

### 3.2 平台定位（官方文档——本评估的关键平台事实）

OpenHarmony 官方 HUKS 概述（gitcode `openharmony/docs`，`huks-overview.md`）原文：

> 「如果系统/设备存在安全环境（TEE 等），**HUKS 核心层必须运行在安全环境内**。
> 由于安全环境依赖硬件支持，**在开源仓中仅为模拟实现，需要 OEM 厂商适配**。」

推论（直接决定方案 B 的价值兑现条件）：

1. **ohemu / OpenHarmony 开源镜像上的 HUKS = 模拟 TEE**——方案 B 宣称的「硬件级保护」
   在本项目的**主开发验证环境里实质不存在**（与 Omp"软件模拟"表述一致，此处给出官方原文依据）。
   真实 TEE 保护只在**商用 HarmonyOS 真机**（OEM 已适配）上成立。
2. **验证缺口**：方案 B 的安全行为（隔离性）与性能（模拟 TEE IPC 延迟，握手线程阻塞时长）**
   在 ohemu 上均无法有效验证**，需商用真机窗口——本项目当前没有该窗口的排期。
3. HUKS 另提供**密钥证明**（为 TEE 内生成的公钥签发证明证书）：本项目协议（KDE 协议）**无
   attestation 概念**，跨端不可对齐，属不可用特性（记录在案）。
4. 系统 `TLSSocket` 要求 PEM 私钥（Omp MSG148 示例，官方 API 行为一致）⇒ **方案 B 永久失去
   未来切换系统 TLS 栈的可能**——架构锁死项，与项目路线（kdeconnect-oh 文档套件的后续演进）冲突。

## 4. 威胁模型与配对/钉扎强度（安全架构视角核心）

### 4.1 资产与敏感度（对 Omp 前提的一处更正）

资产：身份私钥（deviceId + 证书）、配对信任状态、局域网 TLS 流量。

Omp §3.1 称「KDE Connect 非高价值目标（无金融/隐私数据）」——**该前提过强**：KDE Connect 的
合法流量包含**通知正文（聊天内容）、剪贴板（可能含凭据）、屏幕共享**，局域网 MITM 场景下价值非零。
但此更正**不改变方案结论**（见 4.2：在线路径已被钉扎+验证码闭合，HUKS 在线路径无增量），
更正的意义在于让威胁建模的出发点站得住。

### 4.2 在线路径分析（配对期 + 配对后）——方案 A 与 B 等价

**配对期（TOFU，防首配对在线 MITM）**：验证码 = `SHA256(sort(A.spki, B.spki) ‖ ts)` 前 8 位 hex，
**双方用户各自在自己屏幕上看到完整码并人工互相对照**。在线 MITM（A 见到 M_A、B 见到 M_B）时：
A 屏 = f(M_A, B)，B 屏 = f(A, M_B)，两者**不可能同时等于**诚实值 f(A, B)（除非 M 退化）。
⇒ 首配对在线 MITM 无法让双端码一致，人工对照即暴露。32 位截断仅对「chosen-prefix 碰撞」有意义，
攻击者需 2^32 次密钥尝试，不可行 ⇒ 强度充分。

**配对后（钉扎）**：证书 DER **全字节相等**（`net_stack_link.cpp:342-346`）+ payload trusted 门禁
（460-475）+ v8 加密通道内二次 identity 校验 ⇒ 任何证书变化（含合法续签）**必须**用户手动解除配对
重走验证码。私钥本身不在线上出现，钉扎验证的是证书 ⇒ **在线路径与私钥存储方式（A/B）无关，两方案等价**。

### 4.3 离线/物理路径分析——A 与 B 的唯一实质差异

| 攻击分支 | 前提 | 方案 A（PEM） | 方案 B（HUKS，商用真机） | 差异 |
|---|---|---|---|---|
| 同设备恶意应用读沙箱 | 沙箱逃逸 | 不可行（SELinux 按应用隔离） | 不可行（HUKS 同样受沙箱访问控制） | 无 |
| **离线提取应用数据** | root / ADB 备份漏洞 + 设备镜像 | **明文 PEM 可读**（`Index.ets` Preferences） | 不可行（TEE，需 TEE exploit） | **B 胜** |
| 设备失窃 + 离线攻击 | 物理获取 + 上述能力 | 同离线提取 | TEE 保护 | **B 胜** |
| 攻击者已控制**双方**设备 | 双方失陷 | 可 MITM（操作已控设备上的应用） | 可 MITM（HUKS 不阻止"应用进程的合法调用"） | 无 |

**结论**：HUKS 的真实增量价值 = 「设备丢失/被盗 + 攻击者可 root 或离线提取」这一**低概率分支**，
后果是冒充用户设备在局域网接收通知/剪贴板。Omp 文档的「零安全提升」措辞**不准确**（§5 修正⑥）。

**跨端生态校准（协议约束视角的关键论据）**：Android 上游的私钥存储 = **SharedPreferences 明文
Base64（PKCS8）**（`RsaHelper.kt:49-53`，JCA 生成、**未用** Android Keystore 硬件保护；
证书同存 SharedPreferences 明文，`SslHelper.kt:126-128`）。⇒ 生态事实接受的离线提取风险等级
**恰好就是方案 A 的等级**——方案 A 不是"低于生态"，而是**等于生态**；方案 B 反而是唯一偏离
上游安全姿态的端（代价见 §6 生命周期语义）。

## 5. 对 Omp 文档（MSG148）的修正与补充（独立核验所得）

| # | 类型 | 内容 |
|---|---|---|
| ① | 引文修正 | 实际 API 名为 `OH_Huks_ExportPublicKeyItem`（Omp 引的 `OH_Huks_ExportPublicKey` 头文件中不存在）——不影响其"私钥不可导出"结论（该结论经独立核验成立） |
| ② | 表述修正 + 风险重定位 | NDK API 是**同步**会话式（`InitSession/UpdateSession/FinishSession`，无回调，`native_huks_api.h:361-453`），Omp"每次 SDK 升级验证 HUKS 异步 API"表述不准；**真实工程风险不是 API 形态而是：同步 TEE 调用发生在 TLS 握手线程，ohemu 模拟 TEE 的 IPC 延迟未实测**（可能数百 ms～秒级，阻塞握手；商用真机硬件 TEE 才有正常预算）。Omp 的 3-5 天估时方向可用，但风险清单应替换为此项 + §3.2 验证缺口 |
| ③ | 补充 | ohemu = **模拟 TEE**（官方原文"开源仓中仅为模拟实现，需 OEM 适配"）⇒ 方案 B 在主验证环境的安全行为**不可验证**（Omp 仅述"性能差"，未点出安全行为不可验证这一更强约束） |
| ④ | 补充 | HUKS 支持密钥证明（attestation 证书）但 KDE 协议无此概念、跨端不可对齐——记录在案，避免后续讨论误认为可用增强项 |
| ⑤ | 补充（Omp 未覆盖的 UX 维度） | **备份/迁移语义回退**：方案 A 的密钥可随备份迁移（身份连续，换机保留配对）；方案 B 私钥不可导出 ⇒ **换机/重装即全量重配对**。佐证：Android 上游对"身份变化"的处理是**清空全部信任设备**（`SslHelper.kt:98-99`）——协议侧把身份连续性变化视为高成本事件，方案 B 把该事件变成常态（换机必现） |
| ⑥ | 结论措辞更正 | 「零安全提升」→ 准确表述：**安全增益局限于离线提取分支（低概率、需 root/备份漏洞），成本（TLSSocket 架构锁死 + 验证缺口 + 换机 UX 回退 + 维护负担）远超收益**。区分"零"与"低"很重要，防止后续讨论陷入 0/100 框架 |

## 6. 跨端对齐（协议约束视角）

1. **协议透明性**：KDE 协议只消费**证书**（钉扎/identity）与**验证码**（配对）；私钥存储是平台私事，
   方案 A/B **不改变任何 packet 字段**——此点 Omp 已述，独立复核一致（`net_stack.h:57`
   `getPairVerificationCode` 只吃 SPKI DER + ts）。
2. **但方案 B 改变的是键生命周期语义**（协议透明 ≠ 语义透明）：不可导出/不可备份/不可迁移 ⇒
   HarmonyOS 端成为**唯一身份连续性语义不同的端**（§5 修正⑤）。跨端产品的安全设计应优先
   "各端同一姿态"，而非单端独强（独强反而制造用户心智分叉与运维分叉）。
3. **钉扎机制跨端差异（记录，非缺陷）**：Android 用标准 X.509 信任管理器（trusted→工厂验签 /
   untrusted→trustAll 配对通道，`SslHelper.kt:142-173`）；本工程用 **DER 全字节相等**
   （`net_stack_link.cpp:330-346`）——安全等价、本端更严（不受信任链实现差异影响），保留。
4. **验证码算法跨端一致**：本工程值经 C++ 真实打印 + python3 复算 + 向量固化
   （`CRYPTO_VECTORS.md`）；Android `PairingHandler.kt:48` 同一 SHA-256 派生；0.8.0 真机配对成功
   已端到端验证。
5. **TLS 版本对齐（出范围记录）**：Android 显式 TLSv1.2（注释：1.3 在部分老设备有问题，
   `SslHelper.kt:166`）；本端 BearSSL 握手版本上限需与老 Android 设备兼容——单独立项，不在本评估。

## 7. 六维对比（AtomCode 版，含 Omp 版缺的三行）

| 维度 | 方案 A（PEM 现状） | 方案 B（HUKS） | 差异实质 | 权重 |
|---|---|---|---|---|
| 安全 | 沙箱级；**= Android 上游生态等级**（§4.3） | TEE 级（仅商用真机） | 唯一差异在离线提取分支（低概率） | 中 |
| 兼容性 | ✅ 可切系统 TLSSocket（未来选项保留） | ❌ **架构锁死**（TLSSocket 要 PEM） | 决定未来演进自由度 | **决定性** |
| 工程 | ✅ 已完成 + 真机验证 | 同步桥接可做；风险 = 握手线程阻塞 + ohemu 延迟未实测（§5 修正②） | 3-5 天 + 持续维护 | 高 |
| 跨端协议 | 透明且**生态同姿态** | 包透明但**生命周期语义偏离**（换机重配对常态化） | 单端独强的心智/运维分叉 | 中 |
| 平台约束 | ✅ ohemu + 真机均可用 | ⚠️ ohemu = 模拟 TEE：**安全行为不可验证**（§3.2） | 主验证环境失能 | **决定性（本周期）** |
| 维护成本 | 低 | HUKS API 演进 + TEE 黑盒调试 | 长期税 | 中 |

方案 C（HUKS 生成 + 握手时导出内存）：双方已否定，独立确认理由成立——私钥仍出 TEE 入内存
（安全收益归零）+ 三栈协调复杂度（HUKS/cryptoFramework/BearSSL），无存在必要。

## 8. 结论与建议

1. **同意 Omp 的方向性结论：维持方案 A（PEM）**。但依据是本文独立论证链：
   在线路径等价（§4.2）+ 生态同等级（§4.3 Android 实证）+ 架构锁死（§3.2-4）+ 验证缺口（§3.2-2）
   + 换机 UX 回退（§5 修正⑤）。Omp 的"零安全提升"论证**过强不成立**（§5 修正⑥），裁决文书
   建议采用本文措辞。
2. **不采纳方案 B**。若未来出现「商用真机 TEE 验证窗口 + 系统 TLS 不再演进 + 上游 KDE 端
   普遍迁移到硬件密钥」三者同时成立，重议。
3. **方案 A+（本文新增建议，P2）**：**PEM 结构不动 + HUKS 保险库密钥加密落盘**——
   EC 私钥仍是 PEM（TLS 架构/TLSSocket 可迁性/跨端语义全部保留），仅把 `keyPem` 的**落盘形态**
   改为：用随机 AES-256 对称密钥加密，AES 密钥存 **HUKS 对称密钥槽**（不存 PEM）。
   - 收益：离线提取需破 TEE（覆盖 §4.3 的 B 胜分支，≈ 方案 B 的离线保护收益）；
   - 成本：~0.5-1 天（ArkTS 侧 HUKS 对称加解密 + 一次迁移逻辑：读到旧明文 keyPem 即加密重写）；
   - 风险：低——HUKS **对称 AES 是其中最成熟路径**（无需 EC SIGN/AGREE 回调链、无 TLS 握手线程
     阻塞——加解密发生在 Preferences 读写时刻而非握手期），ohemu 模拟 TEE 下功能仍可用（性能影响
     仅启动期一次）；
   - 先决条件：ohemu 上实测 HUKS 对称密钥路径可用（Omp 一条冒烟，半天内）。
   - **建议排期 0.9.0 窗口**（不碰 0.8.x 在途文件；与 rustls 决策解耦——A+ 无论最终 TLS 栈
     是 BearSSL 还是 rustls/TLSSocket 都成立）。
4. Omp 的 P2 项「root 环境检测 + 用户警示」**降为 P3**：KDE Connect 非支付级应用，root 检测
   误报率高（用户社区常见 root 设备），安全边际收益小。
5. 关联独立项（不属本评估，交叉引用）：TrustStore `paired ?? true` trust-by-default
   （前次代码评审 P3 留档）已列入 0.8.1/0.9.0 T 系列测试边界，维持。

## 9. 未验证项（如实声明）

| 项 | 状态 | 影响 |
|---|---|---|
| KDE 桌面端密钥存储介质（明文文件 / KWallet） | 本地参考仓不全（`QKeychain/generateCertificate` 全仓无匹配），仅 `docs/10` 函数图（EC P-256 新 / RSA 2048 旧） | 桌面端"生态同等级"论断以 Android 为锚，桌面端待 Linux 侧后续代查上游源码补证 |
| ohemu 模拟 TEE 的 HUKS 实际延迟/可用性 | 未实测 | 方案 A+ 的先决条件冒烟（§8.3）；方案 B 若被强推则必须先测 |
| iOS 参考实现密钥存储（Keychain？） | 无本地参考仓 | iOS 端生态姿态未纳入校准（预期 Keychain = 高于 A 等级，若坐实则"A = 生态等级"应表述为"A = Android/KDE 桌面等级，iOS 独高"——不改变结论方向） |
| 商用 HarmonyOS 真机 HUKS ECC AGREE 性能预算 | 无真机 | 方案 B 重议条件之一（§8.2） |

## 10. 请 CodeArts 裁决

1. 三选一：**维持 A（双方一致）** / 采纳 B（需先补 §9 真机验证窗口）/ **采纳 A+（本文推荐，P2，0.9.0 窗口，先决条件 = ohemu HUKS 对称密钥冒烟，Omp 半天）**
2. 裁决文书措辞采用 §5 修正⑥（"低"而非"零"）。
3. 若 A+ 获批：冒烟与实施排期给 Omp；本文 §8.3 为实施依据。

—— AtomCode（qwen3.8-27b），2026-10-11
