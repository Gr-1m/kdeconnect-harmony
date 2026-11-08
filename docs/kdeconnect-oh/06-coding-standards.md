# 06 编码规范教学（Agent 执行编码任务的唯一标准）

> 本文教「怎么写对」，`04-security.md` §4 定「什么不能写」，`03-development-plan.md` §9 定「任务怎么发起」，`07-development-walkthrough.md` 定「按什么顺序做」。编码任务开工前，执行者必须读完本文对应层的小节；评审者必须用 §8 清单逐项过。
> 教学立场：模板都给「骨架 + 不变式 + 测试」。**模板中的 API 名属于设计意图，落地前必须以实际 crate/SDK 版本核对签名**（尤其 napi-rs OHOS fork 与 ArkTS SDK）；核对差异记入任务卡，不得「照抄编不过就随手改」。
> 修订记录：2026-10-09 复核——修正 SAS 拼接顺序（初版写反，会导致与三端验证码不一致）、配对状态机改为逐条对照桌面实现、补 TLS 角色与 verifier 模板、ArkTS 模板改为合规写法、Cookbook 改用无门控的 runcommand。
> 与 08 的关系：`08-interface-contract.md` 是冻结接口（签名/事件/错误码唯一权威）；本文是「怎么实现得规范」。冲突时以 08 为准并走 CCR（09 §2）。

## 1. 通用工程原则：反补丁五律（跨所有语言）

**P1 不变式优先**。每个模块的核心是一组可陈述的不变式（§2.1、各 crate `lib.rs` 头部清单）。修 bug = 指出违反了哪条不变式 -> 修复落在不变式的定义处或维护处，而不是在出错调用点加特判。

```rust
// 反面：发现 mousepad dx 为 NaN 导致对端异常，于是在发送调用点包一层
if dx.is_nan() { dx = 0.0; }   // 补丁：掩盖了「协议数值字段必为有限数」这一不变式的破口
```

规范做法：NaN 能出现 = `MousepadRequest` 的构造/解析没做有限性校验 -> 在类型构造函数里拒绝非有限数 -> 补回归测试。调用点代码不动。

**P2 契约先行**。先改契约（02 §3 NAPI 接口 / 模块 `pub` API / 01 协议字段），再写实现，最后同步测试。「实现先行、事后补接口」的任务卡直接打回。

**P3 单向依赖与状态唯一持有者**。依赖方向固定 `app(ArkTS UI) -> adapters -> bridge(ArkTS 封装) -> kc-bridge(NAPI) -> engine crates`；引擎内 `kc-lan/kc-sftp -> kc-core`，禁止反向。

| 状态 | 唯一持有者 | 其余方只见只读快照/事件 |
|---|---|---|
| socket/TLS/重连 | kc-lan | onLinkEstablished/Lost |
| 配对状态机 | kc-core `Pairing` | 事件 + 查询 |
| 设备档案（持久） | ArkTS 持久层 | 引擎启动注入，运行期经事件回写 |
| UI 展示状态 | ArkTS @ComponentV2 store | - |

出现「两处都在写同一个字段」= 结构错误，重构而不是加锁。

**P4 错误必须旅行到边界**。Rust 错误沿 `Result` 传到 NAPI 边界统一转错误码；ArkTS 统一转 `KcException`。禁止中途「log 后继续」、禁止协议路径上「就地兜底默认值」。可以降级（DropPacket），但必须按 §2.2 分级显式声明。

**P5 注册表扩展**。新插件/事件/错误码 = 在对应注册表加一行 + 新文件，禁止在既有函数里加 if-else 散弹。能力集、路由表、适配器注册表三处必须由同一份插件声明生成（§6 第 4 步）。

**补丁味清单**（评审命中任一即退回）：

1. 调用点特判（本应在类型/校验层）；
2. catch 后空继续或只打日志；
3. 同一协议常量在第二个文件以字面量出现；
4. 跨层 import（UI 引 native 模块等）；
5. 测试断言「没崩」而不是「契约成立」；
6. 为单个设备/单个场景硬编码；
7. 注释掉的错误处理或测试。

## 2. Rust 引擎规范（kc-core / kc-lan / kc-sftp）

### 2.1 crate 组织与文件职责

```
kc-core/src/
  lib.rs           不变式清单（头部注释）+ 模块导出
  limits.rs        全部防御限额常量（01 §5 的 OH 取值），唯一来源
  error.rs         KcError + 分级（§2.2）
  packet.rs        NetworkPacket 信封 + 行分帧 + 序列化
  types/           每个包类型一个文件：body 结构 + 校验构造函数（§2.3）
  identity.rs      identity 构造/校验/名称过滤
  pairing.rs       Pairing 状态机（§2.4）
  sas.rs           verification key（§2.5，含已知答案测试）
  device.rs        DeviceSnapshot + 能力协商（纯数据）
  routing.rs       包类型 -> handler 归属注册表
  io.rs            Clock / Rng trait（§2.6）
kc-lan/src/        socket + rustls + 发现 + 重连 + payload 通道（IO 编排，不含协议判定）
kc-sftp/src/       russh 服务器（认证模型见 01 §6）
```

规则：`kc-core` 无 IO、无 async、无全局状态，**在 host 上可全量单测**；`kc-lan`/`kc-sftp` 的函数要么薄（喂 IO 给 kc-core），要么显式属于「IO 策略」（超时/重连参数）。

`lib.rs` 头部不变式清单示例（kc-core，起始版本）：

```rust
//! Invariants (any change requires 02/06 doc update first):
//! I1. No byte from the network is parsed before passing a size check in `limits`.
//! I2. Only `kdeconnect.identity` / `kdeconnect.pair` are accepted from unpaired peers.
//! I3. PairState changes only inside `Pairing::on_*`; no other code writes it.
//! I4. Every outgoing packet type is checked against the peer's incomingCapabilities.
//! I5. Verification key bytes are computed from exactly the SPKI DER used in TLS.
```

`limits.rs` 是全部协议常量的唯一来源（补丁味第 3 条的根治手段），值取自 01 §1/§5：

```rust
// kc-core/src/limits.rs
use std::time::Duration;
pub const PROTOCOL_VERSION: u32 = 8;
pub const UDP_PORT: u16 = 1716;
pub const TCP_PORT_RANGE: std::ops::RangeInclusive<u16> = 1716..=1764;
pub const PAYLOAD_PORT_RANGE: std::ops::RangeInclusive<u16> = 1739..=1764;
pub const MAX_IDENTITY_BYTES: usize = 8 * 1024;
pub const MAX_PACKET_BYTES: usize = 32 * 1024 * 1024;
pub const MAX_UNPAIRED_LINKS: usize = 42;
pub const SAME_DEVICE_RECONNECT_GAP: Duration = Duration::from_millis(500);
pub const PAIR_CLOCK_SKEW_SECS: i64 = 1800;
pub const PAIR_TIMEOUT: Duration = Duration::from_secs(30);
pub const PAYLOAD_ACCEPT_TIMEOUT: Duration = Duration::from_secs(30);
```

### 2.2 错误模型（全 crate 共用骨架）

```rust
// kc-core/src/error.rs
/// Disposition is part of the contract: handlers MUST act as declared.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Disposition { FatalLink, DropPacket, Ignorable, Infra }

#[derive(Debug, thiserror::Error)]
pub enum KcError {
    #[error("line exceeds {limit} bytes")]
    LineTooLong { limit: usize },
    #[error("malformed json: {0}")]
    MalformedJson(String),
    #[error("identity invalid: {0}")]
    InvalidIdentity(&'static str),
    #[error("peer certificate mismatch")]
    CertMismatch,
    #[error("body of {ty} invalid: {reason}")]
    InvalidBody { ty: &'static str, reason: String },
    #[error("packet type {0} not accepted in current state")]
    UnexpectedType(String),
    #[error("duplicate identity (rate limited)")]
    RateLimited,
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

impl KcError {
    /// Single source of truth for error handling policy; exhaustive on purpose.
    pub fn disposition(&self) -> Disposition {
        match self {
            KcError::LineTooLong { .. } | KcError::MalformedJson(_)
            | KcError::InvalidIdentity(_) | KcError::CertMismatch => Disposition::FatalLink,
            KcError::InvalidBody { .. } | KcError::UnexpectedType(_) => Disposition::DropPacket,
            KcError::RateLimited => Disposition::Ignorable,
            KcError::Io(_) => Disposition::Infra,
        }
    }
}
```

处理策略：FatalLink -> 断链 + `onLinkLost` 带原因；DropPacket -> 丢弃 + warn 日志（链路内的格式错误包不是致命错误，对齐桌面行为）；Ignorable -> debug；Infra -> kc-lan 重连策略。**`disposition()` 必须穷举不带 `_`**：新增变体编译即报错，逼迫作者显式分级。

### 2.3 协议类型化（类型即校验）

```rust
// kc-core/src/types/pair.rs
use serde::Deserialize;
use crate::error::KcError;

#[derive(Debug, Deserialize)]
pub struct PairBody {
    pub pair: bool,
    #[serde(default)]
    pub timestamp: Option<i64>,   // v8: required on requests; Pairing validates presence
}

impl TryFrom<serde_json::Value> for PairBody {
    type Error = KcError;
    fn try_from(v: serde_json::Value) -> Result<Self, KcError> {
        serde_json::from_value(v).map_err(|e| KcError::InvalidBody {
            ty: "kdeconnect.pair", reason: e.to_string(),
        })
    }
}
```

```rust
// kc-core/src/types/mousepad.rs —— P1 的正面示范：不变式落在类型构造处
pub struct Delta(f64);
impl Delta {
    pub fn new(v: f64) -> Result<Self, KcError> {
        if v.is_finite() { Ok(Delta(v)) }
        else { Err(KcError::InvalidBody { ty: "kdeconnect.mousepad.request", reason: "non-finite delta".into() }) }
    }
}
```

规则：所有入站 body 经 `TryFrom<Value>`；数值有限性/范围、字符串长度在构造处完成；未知字段忽略（前向兼容）；`payloadSize`/`payloadTransferInfo` 属于信封（`NetworkPacket`），不进 body 类型。**协议允许的宽松要在类型里写明**：例如 `kdeconnect.runcommand` 的 `commandList` 在 schema 是 JSON 字符串，但 iOS 兼容过 GSConnect 发 dict 的历史 bug（ios RunCommand.swift:38-44），解析侧两种都接受、发送侧只发字符串。

### 2.4 状态机：逐条对照上游，不自创语义

配对状态机必须与桌面 `kde/core/backends/pairinghandler.cpp` 逐转移一致（行号即对照表）：

| 当前状态 | 事件 | 动作与新状态 | 上游 |
|---|---|---|---|
| NotPaired | 用户请求 | 记 timestamp，发 `{pair:true,timestamp}`，-> Requested，启动 30s 超时 | :109-118 |
| RequestedByPeer | 用户请求 | 视同接受 -> acceptPairing | :99-102 |
| Paired | 用户请求 | 失败「已配对」，状态不变 | :94-98 |
| Requested | 收 pair=true | -> Paired | :34-36 |
| RequestedByPeer | 收 pair=true | 忽略（重复请求） | :37-39 |
| NotPaired | 收 pair=true | 校验 timestamp（缺失->NotPaired；偏差>1800s->失败「时钟不同步」），-> RequestedByPeer，启动超时，上抛请求 | :51-68 |
| Paired | 收 pair=true | **先 unpair**，再按 NotPaired 处理（同形包无法区分请求/接受） | :40-49 |
| RequestedByPeer | 用户接受 | 发 `{pair:true}`，-> Paired | :129-145 |
| Requested/RequestedByPeer | 用户取消 | 发 `{pair:false}`，-> NotPaired | :147-154 |
| Requested/RequestedByPeer | 收 pair=false | -> NotPaired，失败「对端取消」 | :77-81 |
| Paired | 收 pair=false / 用户解配对 | -> NotPaired | :82-85、:156-162 |
| Requested/RequestedByPeer | 超时 | 发 `{pair:false}`，-> NotPaired | :164-170 |

```rust
// kc-core/src/pairing.rs —— 骨架：事件驱动、输出动作，不直接做 IO
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairState { NotPaired, Requested, RequestedByPeer, Paired }

pub enum PairInput { UserRequest, UserAccept, UserCancel, UserUnpair, Received(PairBody), Timeout }

pub enum PairAction {
    Send(PairBody),                       // engine serializes and sends
    StartTimer(std::time::Duration),
    StopTimer,
    Emit(PairEvent),                      // to UI via bridge
}

pub struct Pairing { state: PairState, timestamp: Option<i64>, peer_version: u32 }

impl Pairing {
    /// The only mutator of `state` (invariant I3). Returns actions instead of
    /// performing them, so every row of the table above is a unit test.
    pub fn on_input(&mut self, input: PairInput, clock: &dyn Clock) -> Vec<PairAction> {
        use PairState::*;
        match (self.state, input) {
            // Worked example = table row "NotPaired + 收 pair=true" (upstream :51-68).
            (NotPaired, PairInput::Received(PairBody { pair: true, timestamp })) => {
                let Some(ts) = timestamp else { return vec![] };          // missing -> stay NotPaired
                if (clock.now_unix() - ts).abs() > limits::PAIR_CLOCK_SKEW_SECS {
                    return vec![PairAction::Emit(PairEvent::Failed(FailReason::ClockSkew))];
                }
                self.timestamp = Some(ts);
                self.state = RequestedByPeer;
                vec![PairAction::StartTimer(limits::PAIR_TIMEOUT),
                     PairAction::Emit(PairEvent::Requested)]
            }
            // ...one arm per remaining table row; no `_ =>` fallback, so a new
            // state or input fails to compile until it is handled explicitly.
        }
    }
    pub fn state(&self) -> PairState { self.state }
}
```

教学要点：状态机返回「动作列表」而不是自己发包/开定时器——表中每一行都能写成「给定状态+输入 -> 断言动作序列」的纯函数测试。`match` 禁止 `_ =>` 兜底。

### 2.5 验证码（SAS）参考实现与已知答案

上游三端的拼接顺序是**较大的公钥 DER 在前**（按无符号字节序比较），初学者最容易写反：

- 桌面：`if (a < b) std::swap(a, b);` 后先加 a 再加 b（kde pairinghandler.cpp:181-189）
- Android：`compareUnsigned(a, b) < 0` 时返回 `b + a`（and PairingHandler.kt:231-236）
- iOS：`remote.lexicographicallyPrecedes(local)` 时 `local + remote`（ios CertificateService.swift:112-116）

```rust
// kc-core/src/sas.rs
use sha2::{Digest, Sha256};

/// `a`, `b`: SubjectPublicKeyInfo DER of both devices, order-independent.
/// `timestamp`: pairing timestamp (seconds) for protocol >= 8, None for v7.
pub fn verification_key(a: &[u8], b: &[u8], timestamp: Option<i64>) -> String {
    let (hi, lo) = if a >= b { (a, b) } else { (b, a) };   // slice Ord = unsigned lexicographic
    let mut h = Sha256::new();
    h.update(hi);
    h.update(lo);
    if let Some(ts) = timestamp {
        h.update(ts.to_string().as_bytes());               // decimal ASCII, no padding
    }
    hex::encode_upper(&h.finalize()[..4])                  // 4 bytes = 8 hex chars
}
```

已知答案测试向量（2026-10-09 用 OpenSSL 生成两把 P-256 公钥，`openssl dgst -sha256` 独立复核）：

```
A_SPKI_DER = 3059301306072a8648ce3d020106082a8648ce3d0301070342000488f63038e53859087a4a092f00d1f0f7eb082d7d2479bfa7dc1226a9a58ca84d9715365f20dbe8b11e5f4a5bf8d8dee881a4c16612bca9740c40fccb79f0efe1
B_SPKI_DER = 3059301306072a8648ce3d020106082a8648ce3d03010703420004a5fdc7ce3f137c788a6450ff797a4444e116af1c55b3244a8ea14fe0738cbcf9cce0dc1b921641316635d0c191f62b06ab96d34b38de2840b5877b2a31bf6139
timestamp  = 1700000000
期望       = A82E8F8A   （B > A，拼接 B||A||"1700000000"）
错误顺序   = 71A26CF5   （A||B，测试必须断言 != 此值，防回归）
```

```rust
#[test]
fn verification_key_matches_upstream_ordering() {
    let a = hex::decode(A_SPKI_DER).unwrap();
    let b = hex::decode(B_SPKI_DER).unwrap();
    assert_eq!(verification_key(&a, &b, Some(1_700_000_000)), "A82E8F8A");
    assert_eq!(verification_key(&b, &a, Some(1_700_000_000)), "A82E8F8A"); // symmetric
    assert_ne!(verification_key(&a, &b, Some(1_700_000_000)), "71A26CF5"); // wrong-order guard
}
```

L3 终验：与桌面真实配对时两端显示的 8 位码逐位一致（旧套件 15 号文档 P0 清单同项）。

### 2.6 IO 抽象与可测性

```rust
// kc-core/src/io.rs
pub trait Clock { fn now_unix(&self) -> i64; }
pub trait Rng { fn fill(&mut self, buf: &mut [u8]); }
```

```rust
// kc-core/src/packet.rs —— 分帧器是纯状态机：喂字节、吐完整行，可脱离 socket 测试
pub struct LineFramer { buf: Vec<u8>, limit: usize }
impl LineFramer {
    pub fn new(limit: usize) -> Self { Self { buf: Vec::new(), limit } }
    /// Feeds bytes; returns complete lines. Errors once the pending line exceeds `limit`.
    pub fn push(&mut self, chunk: &[u8]) -> Result<Vec<Vec<u8>>, KcError> { /* ... */ }
}
```

规则：时间、随机、socket 全经 trait/纯状态机；生产实现在 `kc-lan`。半包、粘包、超限三类用例必须对 `LineFramer` 直接测试（旧套件 15 号文档问题 8 的对策落点）。

### 2.7 TLS 角色与信任（kc-lan 骨架）

角色由 01 §2 矩阵决定：**TCP 发起方 = TLS server，TCP 监听方 = TLS client**。rustls 在已连接的 `TcpStream` 上任选角色：

```rust
// kc-lan/src/tls.rs —— 骨架；以实际 rustls 0.23.x 文档核对签名
use rustls::client::danger::{ServerCertVerifier, ServerCertVerified};
use rustls::server::danger::{ClientCertVerifier, ClientCertVerified};

/// Trust decision is per peer, decided before the handshake starts.
pub enum PeerTrust {
    /// Unpaired: accept any self-signed cert, capture it for pairing (TOFU).
    Unpaired,
    /// Paired: accept only this exact certificate (DER equality).
    Pinned(rustls::pki_types::CertificateDer<'static>),
}

pub struct KdeServerCertVerifier { trust: PeerTrust, provider: std::sync::Arc<rustls::crypto::CryptoProvider> }

impl ServerCertVerifier for KdeServerCertVerifier {
    fn verify_server_cert(&self, end_entity: &rustls::pki_types::CertificateDer<'_>,
        intermediates: &[rustls::pki_types::CertificateDer<'_>], _name: &rustls::pki_types::ServerName<'_>,
        _ocsp: &[u8], _now: rustls::pki_types::UnixTime) -> Result<ServerCertVerified, rustls::Error> {
        if !intermediates.is_empty() { return Err(rustls::Error::General("chain must be exactly one cert".into())); }
        match &self.trust {
            PeerTrust::Unpaired => Ok(ServerCertVerified::assertion()),
            PeerTrust::Pinned(want) if want.as_ref() == end_entity.as_ref() => Ok(ServerCertVerified::assertion()),
            PeerTrust::Pinned(_) => Err(rustls::Error::General("pinned certificate mismatch".into())),
        }
    }
    // verify_tls12_signature / verify_tls13_signature: delegate to
    // rustls::crypto::verify_tls1x_signature with self.provider.signature_verification_algorithms
    // supported_verify_schemes: delegate to the same algorithms
}
// KdeClientCertVerifier mirrors this for the TLS-server role; client auth is mandatory (offer_client_auth = true).
```

不变式与对照：

1. 证书比对是**整张证书 DER 相等**（iOS 做法，ios CertificateService.swift:187-227），并要求链长恰好 1；未配对时捕获证书交给 identity 校验与配对。
2. 握手后必须校验证书 CN == identity 的 deviceId（kde lanlinkprovider.cpp:644-648）；**rustls 不替你做这一步**（`ServerName` 被忽略），这是 kc-lan 的显式步骤。
3. 签名校验**不能**省：自定义 verifier 只替换「信任谁」，握手签名仍用 provider 的算法校验，否则私钥持有证明失效。
4. 版本：服务端角色同时接受 TLS 1.2/1.3；客户端角色限制最高 TLS 1.2——Android 端 `SSLContext.getInstance("TLSv1.2")` 注明 1.3 在部分设备有问题（and SslHelper.kt:166），保守对齐，Phase 4 再评估放开。
5. payload 通道复用同一套 verifier，信任状态必为 `Pinned`（payload 只在已配对后发生）。

### 2.8 测试规范

- 命名 `unit_condition_expected`；每个公开函数 >= 1 正例 + >= 1 协议违例例。
- table-driven（与 Go 惯例一致）：用例表 + 循环断言；状态机按 §2.4 表逐行一个 case。
- 测试数据放 `testdata/`，注明来源（上游 file:line 或自造向量及生成命令）。
- 禁止删除失败测试；`#[ignore]` 必须带原因与跟踪任务卡。

### 2.9 Rust 其余硬规则

- `unsafe`：仅 `kc-bridge` NAPI 边界，逐处 `// SAFETY:` 注释（04 §4）。
- `unwrap/expect/panic!`：仅测试与不可达断言；生产路径一律 `Result`。
- 依赖：rustls 必须 `default-features = false` 并启用 `ring`（05 §3.4）；新 crate 走 04 §6 登记。
- 公开 API 文档注释含：契约出处（01 章节）、错误分级、示例。

## 3. NAPI 桥规范（kc-bridge）

### 3.1 导出函数形态（所有函数长一个样）

```rust
// kc-bridge/src/lib.rs —— 设计意图模板；属性宏与类型以所选 OHOS fork 版本为准
#[napi]
pub fn send_packet(session: &SessionHandle, device: String, ty: String,
                   body_json: String) -> napi::Result<()> {
    guarded(|| {
        let body: serde_json::Value = serde_json::from_str(&body_json)
            .map_err(|e| to_napi(ErrCode::BadParam, e))?;             // E1xx
        session.engine().send_packet(&device, &ty, body)               // 命令即入队（08 §1 原则3）
            .map_err(|e| to_napi(ErrCode::from(&e), e))                // §3.4 / 08 §4
    })
}

fn guarded<T>(f: impl FnOnce() -> napi::Result<T>) -> napi::Result<T> {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(p) => { log_panic(&p); Err(to_napi(ErrCode::EnginePanic, "engine panicked")) }
    }
}
```

规则：函数体只做「反序列化 -> 转调 -> 错误码翻译」三件事，出现第四件事就是放错层；引擎经 `SessionHandle` 访问，无全局 static；`kcStop` 幂等。

**panic 策略（必须二选一并写进构建配置）**：`catch_unwind` 只在 `panic = "unwind"` 时生效；若 release 配置 `panic = "abort"`（体积更小），则 panic 直接终止宿主进程——本项目定为 **`unwind`**，并在 G2 中验证 OHOS 目标的 unwind 行为；后台线程（tokio 任务）的 panic 不经过 `guarded`，由 runtime 的 panic hook 捕获后转 `EnginePanic` 事件 + 断链。

### 3.2 事件通道（唯一模式）

引擎事件 -> `tokio::sync::mpsc` -> bridge 线程 -> thread-safe function -> ArkTS `bridge/` 单一监听器 -> store reducer。ArkTS 侧不存在第二个 NAPI 事件入口；新增事件 = 引擎 enum 加变体 + reducer 加 case（P5）。

### 3.3 大数据规则

payload 一律以 fd 或沙箱路径过桥，禁止把 MB 级字节转为 ArrayBuffer；单个字符串参数 <= 64KiB。fd 所有权：谁 open 谁负责 close，跨桥传递时在契约里写明「所有权转移」或「借用」。

### 3.4 错误码表（编号即契约，权威 = 08 §4 errors.v1.json）

| 段 | 来源 |
|---|---|
| E1xx | 参数/状态错误（调用方 bug） |
| E2xx | `Disposition::FatalLink` |
| E3xx | `Disposition::DropPacket` / 超时 |
| E4xx | `Disposition::Infra` |
| E5xx | 桥/工具链（panic、初始化失败） |

只追加不重排；`message` 面向用户可读、不含敏感字段（04 §5）。

## 4. ArkTS 规范（app 侧）

### 4.1 目录与命名

```
app/src/main/ets/
  ui/            页面与组件（@Entry 页面 <= 5 个）
  store/         设备与插件状态（@ObservedV2 类 + 单一 reducer）
  adapters/      每插件一个 PluginAdapter 实现
  bridge/        NAPI 封装：唯一 import native 模块的目录
  persist/       Asset/RDB/Preferences 封装
  lifecycle/     UIAbility / 长时任务
```

文件 PascalCase、目录小写；`bridge/` 是唯一允许 `import kcbridge from 'libkcbridge.so'` 的目录。

### 4.2 PluginAdapter 契约（接口 + 声明分离）

```typescript
// adapters/PluginAdapter.ets
export interface PluginDecl {
  readonly key: string;                       // stable id, e.g. 'runcommand'
  readonly incoming: ReadonlyArray<string>;   // packet types this plugin receives
  readonly outgoing: ReadonlyArray<string>;   // packet types this plugin sends
  readonly enabledByDefault: boolean;
}

export interface PluginAdapter {
  readonly decl: PluginDecl;
  onPacket(deviceId: string, type: string, body: Record<string, Object>): Promise<void>;
  dispose(): void;                            // release subscriptions; called exactly once
}
```

- 能力集、路由表、适配器注册表全部从 `PluginDecl[]` 生成（§6 第 4 步）——这一个数组是插件元数据的唯一来源。
- `onPacket` 收到的 body 必须先过该插件自己的 `parseXxx(body)`（返回类型化对象或抛 `KcException`），禁止在业务逻辑里散读 `body['x']`。
- 失败：抛 `KcException`（旅到 UI）或调用 `ctx.reportDropped(...)`；不允许静默 return。
- 系统 Kit 调用只在 adapter 内；UI 只消费 store。

### 4.3 UI 状态规范

- 组件一律 `@ComponentV2` + `@Local/@Param/@Once/@Event/@Monitor/@Computed`；模型类用 `@ObservedV2` + `@Trace`；**禁止与 V1 装饰器混用**。
- 设备三态列表（connected/visible/remembered）存在 `store/` 的单一 `@ObservedV2` 实例中，只由 bridge 事件经 reducer 更新；组件不得自行拉取或缓存副本。
- 订阅对称：`aboutToAppear` 里注册的监听在 `aboutToDisappear` 里注销，成对书写、评审逐对检查。

### 4.4 异步与错误

```typescript
// bridge/KcBridge.ets —— 唯一的错误转换点
async acceptPair(deviceId: string): Promise<void> {
  try {
    await native.kcAcceptPair(deviceId);
  } catch (e) {
    throw KcException.fromNative(e as BusinessError);
  }
}
```

UI 层 catch 后只做展示；禁止在组件里比对错误码数值（用 `KcException` 的语义字段）。`Promise.then` 链不超过 2 层，优先 `async/await`。

## 5. 编码步骤节奏（每个模块都按此推进）

1. 骨架三件套评审（07 §3）：公开面 + 不变式 + 测试名清单。
2. 先写测试（至少把 §2.4/§2.5 这类表格和向量变成断言），再填实现。
3. L1 绿 -> 接入 L2 对端场景 -> 需要真机的项进 L3 队列。
4. 文档同步与登记（02 矩阵行、03 登记册、`lib.rs` 不变式清单）。

## 6. 插件开发 Cookbook（端到端 7 步，以 runcommand 为例）

> 选 runcommand 作范例：无决策门依赖、两个方向都有、字段少但有真实兼容坑。

1. **读 schema 与上游**：`meta/schemas/kdeconnect.runcommand.json`（`commandList`：必填，**JSON 序列化后的字符串**，键为命令 id，值为 `{name, command}`）与 `kdeconnect.runcommand.request.json`（`key` 执行；`requestCommandList` 请求列表）。桌面实现另有 `setup`、`canAddCommand`（kde plugins/runcommand/runcommandplugin.cpp:57-67, 190-192）。产物：字段表 + 兼容备注（iOS 接受 dict 形态 commandList，ios RunCommand.swift:38-44）。
2. **类型与常量**：`types/runcommand.rs`（或 ArkTS `parseRunCommand`）定义 `CommandList`（解析接受字符串与对象两种形态，发送只产字符串）；包类型常量只在一处定义。
3. **路由归属**：引擎**不处理任何业务包**（08 §1/§10：引擎只做 identity/pair/payload/SFTP）；一切插件（含 runcommand 双向）都是 ArkTS adapter。RX 侧本地命令列表只能在本机 UI 配置，远端按 key 触发（04 T8）。
4. **注册表登记**：`PluginDecl` 数组必须与 `contract/capabilities.v1.json` 逐字段一致（08 §10 权威）；runcommand 行为 `{key:'runcommand', incoming:['kdeconnect.runcommand'], outgoing:['kdeconnect.runcommand.request'], enabledByDefault:true}`。登记产物 = 与 capabilities.v1.json 的 diff 断言（两侧测试各一份）。
5. **实现**：收到 `kdeconnect.runcommand` -> 解析 -> 更新 store 的远端命令列表；用户点击 -> 发 `{key}`；连接建立时发 `{requestCommandList:true}`。触发走 `sendPacket`（08 §2 签名；文件用 `sendFile`）。
6. **测试**：L1 —— commandList 字符串/对象两种输入、非法 JSON、未知 key（bun 逻辑层）；L2 —— Mock 场景 + Rust 车道用 Go protocol-peer 扮演桌面发列表、收 key（09 §7）；L3 —— 真桌面执行一条无害命令（如 `true`）。
7. **文档同步**：02 §7 矩阵行状态、03 插件进度表、若有新兼容坑则补 01 §9。

## 7. 提交物形态

- 一张任务卡 = 一个原子变更：一个模块 + 测试 + 文档 diff；禁止夹带无关重构。
- 提交说明：`[module] one-line summary` + 任务卡 ID/文档章节 + 验证命令与输出摘要。代码/注释/提交说明用英文，文档用中文。
- 每个 crate 的 `lib.rs` 维护不变式清单（3-8 条）；新不变式先入清单再写代码。

## 8. 代码审查清单（逐项通过才合并）

1. 契约先行：接口/类型变更先于实现，并同步 02 §3？
2. 反补丁五律：补丁味清单零命中？
3. 错误分级：新错误归入 `Disposition`，无静默吞错？
4. 状态所有权：只改了唯一持有者？
5. 注册表：新功能是登记式，`PluginDecl[]` 为唯一来源？
6. 协议合规：字段与 schema 及 01 §1 逐字段一致？限额先于解析？
7. 上游对照：状态机/算法类代码附上游 file:line 对照，且有已知答案测试？
8. TLS：角色符合 01 §2 矩阵？CN==deviceId 校验在位？签名校验未被绕过？
9. 测试证据：L1/L2 输出附在任务卡？违例路径有测试？
10. 资源对称：订阅/注销、fd 打开/关闭成对？
11. 文档同步：02/03/04 相关行已更新？
12. 依赖与日志：无未登记依赖；release 不打 body（04 §5）？
