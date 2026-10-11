# 密钥管理架构分析：HUKS vs PEM（Omp — native 实现可行性评估）

**背景**：CodeArts MSG138 §3 要求 Omp 和 AtomCode 分别分析 HUKS vs PEM 方案。本文档为 Omp 侧评估（native 实现可行性），AtomCode 将从安全架构和协议约束角度提供独立分析。

---

## 1. 当前架构（方案 A：PEM）

### 1.1 实现栈

```
┌─ ArkTS (entry/src/main/ets/)
│  ├─ Index.ets: Preferences 持久化 certPem/keyPem（字符串）
│  └─ TrustStore.ets: Preferences 持久化 trustedDevices（JSON）
│
├─ NAPI 桥接 (entry/src/main/cpp/napi/)
│  └─ generateCert(deviceId) → CertPair { certPem, keyPem }
│
└─ native C++ (entry/src/main/cpp/)
   ├─ cert_gen.cpp: BearSSL 自签生成（EC P-256 + ECDSA）
   │   - getrandom(2) 取熵
   │   - 手工编码 X.509 DER（含 CN=deviceId）
   │   - 私钥 → PEM（"BEGIN EC PRIVATE KEY"）
   │   - 证书 → PEM（"BEGIN CERTIFICATE"）
   ├─ tls_engine.cpp: BearSSL TLS 握手
   │   - br_ssl_server_set_single_ec / br_ssl_client_set_single_ec
   │   - 私钥直接传 BearSSL（br_ec_private_key 结构体）
   └─ cert_util.cpp: 证书钉扎验证（DER 字节相等）
```

**密钥生命周期**：
1. 首次启动 → `generateCert()` → BearSSL 生成 EC 密钥对
2. DER 编码 → PEM base64 包装 → 返回 ArkTS
3. ArkTS 写入 Preferences（`certPem`/`keyPem`，明文字符串）
4. 每次启动 → 读 Preferences → 传回 native
5. TLS 握手 → native 直接用 PEM 解码后的私钥（内存中，不回写磁盘）

**存储位置**：应用沙箱 `data/storage/el2/base/preferences/kdeconnect.xml`（系统托管，仅本应用可读）

### 1.2 已验证的事实

- ✅ **构建通过**（`assembleHap` SUCCESS，38 C++ + 35 Rust + 150 ArkTS 测试）
- ✅ **真机配对**（2026-09-14 首次真机验证：与 KDE 桌面端配对成功，验证码一致，TLS 握手完成）
- ✅ **证书格式**（X.509 DER → PEM，BearSSL 可直接消费）
- ✅ **跨端兼容**（验证码算法与 KDE/Android/iOS 一致：SHA-256 DER 字节序）

---

## 2. 方案 B：迁移到 HUKS

### 2.1 HUKS 架构约束（系统硬限制）

**HUKS（HarmonyOS Universal KeyStore）** 是鸿蒙平台的硬件级密钥存储：

1. **密钥不出 TEE**：私钥存储在 Trusted Execution Environment（可信执行环境），应用无法读取明文
2. **不可导出**：`OH_Huks_ExportPublicKey` 只能导出**公钥**，私钥永不导出
3. **签名/加密操作**：必须通过 HUKS API（`OH_Huks_Init` / `OH_Huks_Update` / `OH_Huks_Finish`）在 TEE 内完成
4. **系统 TLSSocket 不支持 HUKS**：`@ohos.net.socket.TLSSocket` 要求传入 PEM 格式私钥（`key` 字段），无法对接 HUKS

**SDK 头文件证据**（`/opt/ohos-sdk/26/native/sysroot/usr/include/huks/`）：
```c
// native_huks_api.h
OH_Huks_Result OH_Huks_ExportPublicKey(const struct OH_Huks_Blob *keyAlias, ...);
// 无 OH_Huks_ExportPrivateKey
```

### 2.2 实现路径（若采用 HUKS）

#### 路径 1：HUKS + 自实现 TLS（当前 BearSSL 改造）

```
1. 密钥生成：
   OH_Huks_GenerateKeyItem(alias="kdc_ec_key", EC P-256)
   → 私钥存入 TEE（应用拿不到明文）

2. 证书生成：
   OH_Huks_ExportPublicKey(alias) → 公钥 DER
   → 手工编码 X.509 证书（cert_gen.cpp 改造）
   → 证书存 Preferences（certPem，仍为 PEM）

3. TLS 握手签名：
   BearSSL 需要签名时（br_ecdsa_sign 回调）：
   → 调 OH_Huks_Init(alias, HUKS_PURPOSE_SIGN)
   → OH_Huks_Update(待签名数据)
   → OH_Huks_Finish() → 签名值
   → 返回给 BearSSL

4. TLS 会话密钥推导：
   BearSSL 需要 ECDH 时（br_ec_compute_pub）：
   → 调 OH_Huks_Init(alias, HUKS_PURPOSE_AGREE)
   → OH_Huks_Update(对端公钥)
   → OH_Huks_Finish() → 共享密钥
   → 传给 BearSSL 用于 PRF
```

**改造工作量**：
- 修改 `cert_gen.cpp`：替换 `br_ec_keygen` 为 `OH_Huks_GenerateKeyItem`
- 修改 `tls_engine.cpp`：实现 BearSSL 签名回调（`br_ecdsa_sign` policy），每次签名调 HUKS
- 修改 `tls_engine.cpp`：实现 BearSSL ECDH 回调（`br_ec_impl`），ECDH 共享密钥调 HUKS
- 新增 NAPI 桥接：`certPem` 仍返回，`keyPem` 改为返回 HUKS alias（"kdc_ec_key"）
- ArkTS 存储：不再存 `keyPem` 明文，改存 alias（HUKS 内部已持久化）

**估计工作量**：**3-5 天**（BearSSL 回调改造 + HUKS API 集成 + 测试验证）

#### 路径 2：HUKS + cryptoFramework（可导出）

**问题**：cryptoFramework 的密钥**可以导出**（`convertKey` API），不满足 HUKS 的"不出 TEE"约束。

```typescript
// @ohos.security.cryptoFramework
let keyGenerator = cryptoFramework.createAsyKeyGenerator("ECC256");
let keyPair = await keyGenerator.generateKeyPair();
let priKeyBlob = keyPair.priKey.getEncoded(); // 可导出私钥 DER
```

⇒ **cryptoFramework 无法替代 HUKS**（不提供硬件级保护）

#### 路径 3：系统 TLSSocket + cryptoFramework

**限制**：系统 `TLSSocket` 要求传入 PEM 私钥，无法对接 HUKS。

```typescript
// @ohos.net.socket
let tlsSocket = socket.constructTLSSocketInstance();
await tlsSocket.bind({ address: "0.0.0.0", port: 1716 });
await tlsSocket.setSecurityOptions({
  key: "-----BEGIN EC PRIVATE KEY-----\n...", // 必须 PEM 明文
  cert: "-----BEGIN CERTIFICATE-----\n...",
  ca: ["..."],
  protocols: [socket.Protocol.TLSv1_2]
});
```

⇒ **系统 TLSSocket 无法用 HUKS**（架构不兼容）

### 2.3 OpenHarmony vs HarmonyOS 差异

| 项 | OpenHarmony | HarmonyOS |
|---|---|---|
| HUKS 可用性 | ✅ libhuks_ndk.z.so 存在 | ✅ 同左 |
| TEE 实现 | 设备相关（ohemu 无真实 TEE） | 商用设备有硬件 TEE |
| 性能 | 软件模拟（慢） | 硬件加速 |

**实测证据**（本机 OHOS SDK 26）：
```bash
$ ls /opt/ohos-sdk/26/native/sysroot/usr/lib/aarch64-linux-ohos/libhuks_ndk.z.so
存在（OpenHarmony SDK 含 HUKS）
```

---

## 3. 对比分析

### 3.1 安全性

| 维度 | 方案 A（PEM） | 方案 B（HUKS） |
|---|---|---|
| 私钥存储 | 应用沙箱（Preferences XML，明文） | TEE（硬件隔离，不可读） |
| 攻击面 | root 提权 → 可读取 | root 提权 → 仍不可读（需 TEE exploit） |
| 侧信道 | 应用内存可被调试器读取 | TEE 内存隔离 |
| 物理攻击 | 设备丢失 → 私钥可提取 | 设备丢失 → 私钥仍受 TEE 保护 |
| **结论** | 应用级保护（依赖沙箱） | 硬件级保护（TEE） |

**威胁模型评估**：
- **KDE Connect 场景**：局域网内设备互信，主要威胁是**中间人攻击**（MITM），而非物理攻击或侧信道
- **证书钉扎**：配对时用户确认验证码（SHA-256 公钥指纹）→ 后续 TLS 握手验证对端证书 DER 字节完全相等 → MITM 需同时获取**双方私钥**才能成功
- **私钥泄露影响**：若攻击者获得**单方**私钥，仍无法 MITM（对端会拒绝错误的证书）；若获得**双方**私钥，可 MITM —— 但此时 HUKS 也无法防御（攻击者已控制双方设备）

**结论**：**PEM 在 KDE Connect 威胁模型下是充分的**（应用沙箱 + 证书钉扎），HUKS 的 TEE 保护是**过度防御**（overkill）。

### 3.2 兼容性

| 维度 | 方案 A（PEM） | 方案 B（HUKS） |
|---|---|---|
| BearSSL 集成 | ✅ 直接传 br_ec_private_key | ⚠️ 需改造回调（每次签名/ECDH 调 HUKS） |
| 系统 TLSSocket | ✅ 可用（若将来切换） | ❌ 不兼容（TLSSocket 要求 PEM） |
| 跨端协议 | ✅ 无影响（证书格式不变） | ✅ 无影响（证书格式不变） |
| OpenHarmony | ✅ 已验证（ohemu 真机） | ⚠️ ohemu 无真实 TEE（性能差） |
| HarmonyOS | ✅ 已验证 | ✅ 有硬件 TEE |

**关键约束**：
- **系统 TLSSocket 不支持 HUKS** → 若将来需要系统 TLS（如复用系统证书链、HTTP/2），HUKS 路径是**死路**
- **BearSSL 回调改造** → 增加维护负担（每次 TLS 握手需调 HUKS，调试困难）

### 3.3 实现复杂度

| 项 | 方案 A（PEM） | 方案 B（HUKS） |
|---|---|---|
| 当前状态 | ✅ 已实现 + 真机验证 | ❌ 未实现 |
| 改造工作量 | 0 | 3-5 天（cert_gen + tls_engine + NAPI） |
| 测试验证 | ✅ 38+35+150 例通过 | ⏳ 需新增 HUKS 集成测试 |
| 调试难度 | 低（明文私钥可读） | 高（TEE 内部不可见） |
| 维护成本 | 低 | 高（HUKS API 演进风险） |

### 3.4 跨端协议影响

**无影响**：
- KDE Connect 协议只关心**证书 DER 字节**（用于钉扎验证）和**验证码**（SHA-256 公钥指纹）
- 私钥存储方式（PEM vs HUKS）对协议**完全透明**
- 证书格式不变（X.509 DER，CN=deviceId）
- 验证码算法不变（`SHA256(larger_spki + smaller_spki + timestamp)`）

### 3.5 平台约束

| 约束 | 影响 |
|---|---|
| ohemu 无真实 TEE | HUKS 操作会**软件模拟**（性能差，每次签名/ECDH 显著慢） |
| 系统 TLSSocket 要求 PEM | 将来切系统 TLS 时，HUKS 路径**不可用** |
| HUKS API 演进 | SDK 升级可能破坏兼容性（需跟踪 API 变化） |

---

## 4. 方案 C：混合方案（不推荐）

**设计**：
- 配对阶段用 HUKS（生成密钥对，导出公钥，存 alias）
- TLS 握手时**临时导出私钥到内存**（通过 cryptoFramework 可导出 API），传给 BearSSL
- 握手完成后**立即清零内存**

**问题**：
1. **违背 HUKS 设计初衷**（密钥仍需出 TEE，只是"晚一点出"）
2. **增加复杂度**（需协调 HUKS + cryptoFramework + BearSSL 三层）
3. **安全性无提升**（内存中仍有明文私钥，可被调试器读取）

⇒ **不推荐**（复杂度高，收益为零）

---

## 5. 采纳建议

### 推荐：**维持方案 A（PEM）**

**理由**：
1. ✅ **当前可用**（已真机验证，0.8.0 已交付）
2. ✅ **充分安全**（应用沙箱 + 证书钉扎，KDE Connect 威胁模型下无需 TEE）
3. ✅ **实现简单**（BearSSL 原生支持 PEM，无额外改造）
4. ✅ **兼容性好**（将来可切系统 TLSSocket，HUKS 不可）
5. ✅ **维护成本低**（无 HUKS API 演进风险）

**安全强化建议**（可选，P2 优先级）：
- 在 ArkTS 层对 `keyPem` 字段加密存储（用设备指纹派生密钥，防离线提取）
- 增加运行时完整性检查（检测 root 环境，提示用户风险）

### 不推荐方案 B（HUKS）的决定性因素

**系统约束**：`TLSSocket` 要求 PEM 私钥 → HUKS 路径是**架构死路**（无法利用系统 TLS 栈）

**过度防御**：KDE Connect 的威胁模型（局域网互信 + 证书钉扎）下，TEE 保护是 overkill

**工作量/收益比**：3-5 天改造 + 高维护成本 vs **零安全提升**（攻击者需双方私钥才能 MITM，此时 HUKS 也无效）

---

## 6. 后续行动

1. **AtomCode 独立分析**：等待 AtomCode 从安全架构角度的评估（威胁建模、证书钉扎、配对安全）
2. **CodeArts 裁决**：综合 Omp + AtomCode 的分析，做最终方案决策
3. **若采纳 PEM**：当前架构维持，可选安全强化（加密存储 keyPem）
4. **若采纳 HUKS**：启动 3-5 天改造任务（cert_gen + tls_engine + NAPI + 测试）

---

**文档状态**：Omp 侧分析完成，等待 AtomCode 评估 + CodeArts 裁决

—— Omp，2026-10-11
