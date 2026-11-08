# 05 语言选型收益风险模型分析

> 上游：`00-README.md`。决策对象：OH 客户端各模块的语言分配。约束输入：用户既定方向「APP 渲染 ArkTS，KDE 原生 C++，可用 Rust 提升安全与性能」。本文回答「哪里用 C++、哪里换 Rust、哪里必须 ArkTS」，并给出结论对权重假设的敏感性。
> 修订记录：2026-10-09 复核——加权分数按公式全部重算（初版有算术错误，结论方向不变）；G1 依官方 API 参考改判为「ArkTS 引擎结构性不可行」；补敏感性分析与 Go 实测证据。

## 1. 分析框架

### 1.1 评分维度与权重

本项目特征：输入来自**不可信局域网**（解析层崩溃 = 远程 DoS）；协议已冻结且小（约 45 个包类型）；流量 = 低频小 JSON + 偶发大文件流；人力 = 1 名工程师（Go 强 / C 可读 / Rust 在学）+ Agent 批量开发；长期维护诉求高于上市速度。

| 维度 | 权重 | 理由 |
|---|---|---|
| S1 内存安全/攻击面收敛 | 25% | 恶意 LAN 输入是主威胁面（04 T5） |
| S2 交付效率（含 Agent 可自动化度） | 20% | 协议已完全文档化（01），模式固定、适合批量生成 |
| S3 平台能力可达性 | 20% | OH Kit 全部 ArkTS 优先；NDK 覆盖子集；Rust 经 NAPI 间接；**也包括「该语言的平台 API 能否表达协议语义」** |
| S4 测试/CI 可行性 | 15% | 协议兼容回归是生命线（iOS 无协议测试的教训，01 §7） |
| S5 维护性（含人力匹配） | 10% | 6 个月后的可读性与依赖升级成本 |
| S6 运行性能 | 10% | 诚实定级：KDE 流量不大，性能是次要收益（§3.3） |

加权分 = Σ(维度分 × 权重)，维度分 1-5（5 优）。§2 表中每个数都可由该公式复算；§4 给出换权重后的结论稳定性。

### 1.2 候选方案

- **方案 A：ArkTS 引擎**（对齐 Android 的 Kotlin 引擎形态）——协议/网络/配对在 ArkTS，native 仅 SFTP。
- **方案 B：Rust 核心引擎**（rustls + russh + tokio，napi-rs OHOS fork 桥接）——ArkTS 只做 UI/适配/持久化。
- **方案 C：C++ 核心引擎**（NDK + OpenSSL，对应「KDE 原生 C++」直觉）。
- 排除项 **Go**：本机 Go 1.27.1 实测 `go tool dist list` 无任何 ohos/openharmony 目标（rustc 则有官方 Tier 2 目标）；无 NAPI 绑定生态；Go 运行时（自有调度器/GC/信号处理）嵌入宿主进程无先例。用户 Go 强项在本平台无法变现。
- 「KDE 原生 C++ 复用」预期管理：桌面核心（`kde/core/`）深绑 Qt（QSslSocket/QJson/事件循环），**可移植代码量约等于零**；三端从未共享协议实现——「复用 KDE C++」实际是「重写 C++」。

## 2. 模块 × 语言评分矩阵

| 模块 | 方案 | S1 | S2 | S3 | S4 | S5 | S6 | 加权 |
|---|---|---|---|---|---|---|---|---|
| UI + 系统适配（通知/剪贴板/Picker/联系人） | ArkTS | 4 | 5 | 5 | 3 | 4 | 3 | **4.15** |
| 同上 | Rust | 4 | 2 | 1 | 3 | 3 | 4 | 2.75 |
| 协议引擎（分帧/JSON/状态机/路由） | ArkTS | 4 | 4 | 4 | 2 | 3 | 3 | 3.50 |
| 同上 | Rust | 5 | 4 | 3 | 5 | 4 | 4 | **4.20** |
| 同上 | C++ | 2 | 2 | 3 | 2 | 2 | 4 | 2.40 |
| TLS + LAN 后端（TOFU/pin/发现） | ArkTS | 4 | 3 | **1** | 2 | 3 | 3 | 2.70 |
| 同上 | Rust(rustls) | 5 | 4 | 3 | 5 | 4 | 4 | **4.20** |
| 同上 | C++(OpenSSL) | 2 | 2 | 4 | 2 | 2 | 4 | 2.60 |
| SFTP 服务器 | Rust(russh) | 5 | 4 | 3 | 5 | 4 | 4 | **4.20** |
| 同上 | C++(libssh) | 3 | 2 | 4 | 2 | 2 | 4 | 2.85 |
| 同上 | ArkTS | 1 | 1 | 1 | 1 | 1 | 1 | 1.00（无 SSH 库，不可行） |
| payload/文件 IO | Rust | 5 | 4 | 3 | 5 | 4 | 5 | **4.30** |
| 同上 | C++ | 3 | 3 | 4 | 2 | 3 | 5 | 3.25 |
| 持久化（Asset/RDB） | ArkTS | 4 | 5 | 5 | 3 | 4 | 3 | **4.15** |
| 视频解码缝隙（后期 virtualmonitor） | C++(NDK AVCodec) | 3 | 3 | 5 | 3 | 3 | 5 | **3.60**（该 NDK API 仅 C） |

「TLS+LAN / ArkTS」的 S3 记 1 而非 3：依据 §3.1 的 API 级结论——不是「接口难用」，是「接口表达不出协议语义」。

关键读数：**网络核心（协议/TLS/SFTP/payload）Rust 全面领先；系统适配与持久化 ArkTS 不可替代；C++ 只在 NDK 独占缝隙与 G2 失败回退时出场。**

## 3. 关键论据

### 3.1 G1 已判定：ArkTS TLS 结构性不可行（决定性论据）

依据 [@ohos.net.socket API 参考](https://gitee.com/openharmony/docs/blob/master/en/application-dev/reference/apis-network-kit/js-apis-socket.md)（2026-10 master，覆盖 API 26）逐项核对：

| KDE 协议要求（01 §2） | ArkTS API 现状 | 结论 |
|---|---|---|
| TCP 发起方在**同一条已建立的 TCP 连接上**充当 **TLS server** | `constructTLSSocketInstance(tcpSocket)` 只把 TCPSocket 升级为 TLS **客户端**；`TLSSocketServer` 只能自己 `bind/listen` 接受新连接，**不存在把已连接 TCPSocket 升级为 TLS 服务端的入口** | **不可表达** |
| TCP 监听方在**已接受的连接上**充当 TLS client | 服务端接受得到的是 `TCPSocketConnection`，而升级函数参数类型是 `TCPSocket` | 不可表达（类型不匹配） |
| TLS 服务端要求**任意自签客户端证书**并取出（未配对 TOFU） | `TLSConnectOptions.skipRemoteValidation`(API 12+) 文档语义为「跳过**服务端**证书认证」（客户端侧开关）；服务端侧无「接受任意客户端证书」开关 | 未配对时服务端角色无法完成 mTLS |
| payload 通道：发送方 listen + TLS server，接收方连入 + TLS client | 发送方可用 `TLSSocketServer`；接收方可用 `TLSSocket` + `skipRemoteValidation` 再 `getRemoteCertificate()` 手动 pin | **唯一可表达的子场景** |

结论：主链路的「TCP 角色与 TLS 角色反转」在 ArkTS 层**无法实现**——这不是工程量问题而是 API 形状问题。交叉验证（本机实测）：Go `crypto/tls` 用 `tls.Server(conn)` + `RequireAnyClientCert` 一次跑通该语义；Python 标准库 `ssl` 的服务端模式对自签客户端证书直接报 `CERTIFICATE_VERIFY_FAILED`——即「能否在已连接 socket 上自由选择 TLS 角色并自定义信任」是 TLS 库的结构属性，rustls（`ServerConnection`/`ClientConnection` 可包装任意 `Read+Write` 流 + `danger::ServerCertVerifier`/`ClientCertVerifier` 自定义）具备，ArkTS TLSSocket 不具备。

iOS 也印证了「必须绕开平台默认 TLS 信任」：GCDAsyncSocket 显式设 `kCFStreamSSLIsServer=YES` 于 TCP 发起方（ios LanLinkProvider.m:456-465）+ 手动 trust 评估。

### 3.2 测试与 CI（第二论据）

Rust 引擎可在 host 上 `cargo test` + `cargo fuzz`（零设备依赖，直接进 CI）；ArkTS 引擎的协议逻辑只能在 DevEco/模拟器内测，fuzz 与覆盖率基建基本不存在。Phase 1 DoD（03 §3）把 L1/L2 设为硬门——方案 A 必然妥协此项。

### 3.3 性能（诚实定级：次要）

- 小 JSON 包（<4KB，低频）：任何语言都够用。
- 文件流：瓶颈在 TLS 与 IO；不构成选型主因。
- 真实收益点：60Hz mousepad 事件尾延迟、后台空闲功耗（常驻 socket 在 native 线程）——存在但量级有限。

### 3.4 Rust-on-OHOS 现状证据（G2 的客观基础）

- rustc 官方：`aarch64/armv7/x86_64-unknown-linux-ohos` **Tier 2 with host tools**（[rustc 平台支持](https://doc.rust-lang.org/beta/rustc/platform-support/openharmony.html)）。
- NAPI 绑定：OpenHarmony TPC 托管的 [ohos_napi_rs](https://gitcode.com/openharmony-tpc/ohos_napi_rs) + 社区 [ohos-rs](https://github.com/ohos-rs/ohos-rs)，均为 napi-rs fork。
- **密码学后端选择**：rustls 0.23 默认 provider 为 `aws-lc-rs`（C/汇编，需 cmake + 目标 C 交叉工具链），在 ohos 目标上属高风险构建；本项目指定 `default-features = false, features = ["ring", "std", "tls12", "logging"]`，ring 为纯 Rust + 少量 C/asm、交叉编译更成熟。**ring 能否在 ohos 目标构建是 G2 的必测子项**。
- 风险留痕：TPC fork 社区规模小、与 API 26 SDK 兼容未验证——G2 spike 的存在理由；两个 fork 互为备份。

## 4. 敏感性分析（权重换成什么，结论才会翻转）

| 权重方案 | 协议引擎胜者 | TLS+LAN 胜者 | SFTP 胜者 | UI+适配胜者 | 引擎 Rust-ArkTS 分差 |
|---|---|---|---|---|---|
| 基准（25/20/20/15/10/10） | Rust 4.20 | Rust 4.20 | Rust 4.20 | ArkTS 4.15 | 0.70 |
| 交付优先（S2=40%） | Rust 4.10 | Rust 4.10 | Rust 4.10 | ArkTS 4.35 | 0.50 |
| 平台可达优先（S3=40%） | Rust 3.85 | Rust 3.85 | Rust 3.85 | ArkTS 4.35 | 0.25 |
| 性能优先（S6=35%） | Rust 4.10 | Rust 4.10 | Rust 4.10 | ArkTS 3.85 | 0.75 |
| 等权 | Rust 4.17 | Rust 4.17 | Rust 4.17 | ArkTS 4.00 | 0.84 |

读法：五种权重下每个模块的胜者都不变；最接近翻转的是「平台可达优先」下协议引擎（分差 0.25）——但 TLS+LAN 在该档下 ArkTS 因 S3=1 反而更差，而协议引擎与 TLS 层必须同语言（帧读写直接跑在 TLS 流上，跨 NAPI 拆开等于每个字节过桥），所以整体结论稳健。**结论对权重假设不敏感；只对 G2（Rust 工具链）敏感。**

## 5. 风险量化与缓解

| 风险 | 方案 B 暴露面 | 缓解 | 残余 |
|---|---|---|---|
| 工具链不兼容（R2/G2，含 ring 交叉编译） | NAPI ABI、构建集成 | G2 前置（03 §2）；回退 C++（§6） | 中低 |
| NAPI 边界复杂度 | ~1k LoC 桥接层 | 接口契约冻结（02 §3）；panic 隔离（06 §3） | 中 |
| Rust 学习曲线（R7） | 核心逻辑需本人可审 | 引擎刻意小（预估 4-6k LoC）、模式化；Agent 写初稿、用户按「能解释每行」验收 | 中 |
| 三语言栈调试成本 | crash 跨边界 | `onLog` 统一通道；panic 事件化 | 低 |
| 依赖治理 | crates 供应链 | 04 §6 | 低 |
| 方案 A（对照） | §3.1 结构性不可行 | - | 不可接受 |

## 6. 决策结论

```mermaid
flowchart TD
    UI[UI/系统适配/持久化] --> ARK[ArkTS]
    CORE[协议引擎/TLS/LAN/SFTP] --> G1R[G1 已判定: ArkTS TLS 不可表达角色反转]
    G1R --> G2{G2: Rust 工具链 + ring 可用?}
    G2 -- 通过 --> RUST[Rust 核心: kc-core/kc-lan/kc-sftp<br/>rustls(ring) + russh + NAPI 桥]
    G2 -- 失败 --> CPP[C++ 引擎: OpenSSL 交叉编译<br/>+ libssh SFTP + fuzz/ASAN 补偿]
    RUST --> GAP[NDK 独占缝隙: C++ 薄层]
```

1. **主路径**：ArkTS（UI/适配/持久化）+ **Rust**（kc-core/kc-lan/kc-sftp）+ C++ 仅 NDK 独占缝隙。对应 02 §2。
2. **唯一回退**：G2 失败 -> C++ 引擎（OpenSSL 自行交叉编译，旧套件 15 号文档问题 2 已评估其成本）。**「ArkTS 引擎」不再是回退选项**（§3.1）。
3. **「KDE 原生 C++」的修正**：C++ 保留于缝隙与回退；不在协议/TLS/SFTP 主干用 C++。
4. **Go 不引入**（§1.2 实测）。
5. 本结论只能被 G2 实测推翻（03 §9 红线 5）。

## 7. 量化预估（容量规划）

| 项 | 方案 A（已否决，作对照） | 方案 B（主） | 方案 C（回退） |
|---|---|---|---|
| 引擎侧 LoC | 不可行 | ~5k Rust + ~1k 桥 | ~8k C++ |
| Host 可测代码占比 | - | ~90%（除 NAPI 桥） | ~60%（需自建 harness） |
| 解析面内存安全 | - | 编译期+运行时 | 仅纪律+ASAN |
| 协议 fuzz 基建 | - | cargo-fuzz 现成 | libFuzzer 手工接 |
| 主要阻塞 | §3.1 | G2 | OpenSSL 交叉编译 |

## 8. 反方观点与回应

- 「ArkTS 单语言更简单」——前提已被 §3.1 否定；且 SFTP 本来就强制 native 层。
- 「Rust 生态在 OH 是社区级」——成立，这正是 G2 前置的原因；Tier 2 官方目标使其不属于自维护工具链级风险。
- 「C++ 更贴 KDE 传统」——三端（Kotlin/Swift/C++）从未共享实现；跟随语言传统无工程收益，且把不可信输入解析放进 C++ 违背 04 §8 红线 5 的精神。
