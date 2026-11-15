# CCR-3: KcApi 补登记（信任/证书/手动连接/能力集）+ 事件形态 + contractVersion

- 日期：2026-11-15
- 提出人：AtomCode（依据用户 2026-11-15 对「阶段 B 三个开放问题」裁决建议的批准）
- 状态：**草案（待 CodeArts 评审 + Omp-ArkTS / Omp-Native 双方签名确认后生效）**
- 影响：`contract/kcbridge.d.ts`、`devdocs/MAP_KCApi_PHASEA_20261114.md`、`KcBridge.ets`（阶段 B）、`tools/check-native-contract.py`（C 组转阻塞）
- 关联：`MSG261`（队列裁决 P1-5 Stage-B）、`MSG263`（映射表骨架/阶段 A 实施）、`MSG262`（阶段 B 排序）

## 1. 动机

阶段 A 已把 native 依赖收敛到唯一 `KcBridge.ets`（现有 19 导出一一转发，契约未动）。
映射表（`MAP_KCApi_PHASEA_20261114.md` §2）指出：冻结 `KcApi` 与现行导出有 **5 条契约缺口**（信任/证书 4 个、`setCapabilities`、手动连接 2 个、`getPairVerificationCode`），
若不在契约层补登记，ArkTS 无法完成配对信任与手动连接；同时 `kind + JSON` 事件形态需要在 bridge 内还原类型化事件。

本 CCR **只增不减**：旧 `Index.d.ts`/napi 导出原样保留，`KcBridge` 以适配层承接新形态；`errors.v1.json` 码表与 `capabilities.v1.json` 能力广告均不变。

## 2. 变更内容

### 2.1 `kcbridge.d.ts` 的 `KcApi` 新增 8 个方法（只增）

```typescript
/** 能力集：直接声明本端 incoming/outgoing（不再由 ArkTS 自拼 identity 能力表） */
setCapabilities(incoming: string[], outgoing: string[]): void;

/** 配对待确认码（v8：双方公钥 DER 排序拼接 + SHA256 前 8 位 hex；ts 为对端 timestamp，秒） */
getPairVerificationCode(deviceId: string, ts: number): string;

/** 信任与证书（配对信任链；pem 为对端叶证书 PEM） */
getPeerCertificate(deviceId: string): string;
getOwnCertificate(): string;
setTrustedCertificate(deviceId: string, pem: string): void;
removeTrustedCertificate(deviceId: string): void;

/** 手动连接（Add by IP）；host 为 IPv4/IPv6 字面量，port 为 TCP 端口 */
connectToPeer(host: string, port: number): void;
disconnect(deviceId: string): void;
```

### 2.2 事件形态（既定，不新增方法）

- 契约层：`setOnEvent(cb: (kind: number, eventJson: string) => void)`（当前 d.ts 已定义，不改）；
- 实现层：`KcBridge` 内维护 **14 个 `EventKind` → 内部 `NetEvent` 的单映射表**，还原类型化事件；
  控制器/插件签名零改动；**未知 `kind` ⇒ 丢弃 + 记日志**（不崩），并加宿主单测。

### 2.3 `contractVersion` 校验策略（写入契约注释）

1. ArkTS 侧常量 `EXPECTED_CONTRACT_VERSION`（随本文件版本同步的手工常量，改动即评审点）；
2. 启动早期（`Index.aboutToAppear` 装配控制器前）调用；
3. 不匹配 ⇒ **拒绝 `start()`** + 日志/状态栏可见（E109 语义），不得静默继续；
4. 桩测试：注入不同版本 ⇒ 断言「未 start + 已记录」。

### 2.4 语义备注（不新增方法，但需在 d.ts 注释写明）

| 方法 | 备注 |
|---|---|
| `setSftpRoots` | **声明但 not implemented**（Q3 已裁决不广告 `sftp` 能力）；bridge 内显式返回未实现，避免广告不可用能力 |
| `setAutoAcceptSec` | 与 S2「自动保存接收文件」是**不同语义**：本方法只影响 `transferOffer` 自动接受超时，**不默认开启**；与 autoSave 的关系在注释写明 |
| `generateIdentity` | **保留 ArkTS 持有私钥**：bridge 内调 `generateCert` + 回填 deviceId，返回形状不变；私钥入 HUKS 属 0.8.x 安全补丁，另走 CCR-4 |
| `stop` | 幂等；进程级 `shutdown` 作为别名标注，不新增方法 |

## 3. 兼容性与风险

- **只增不减**：8 个方法均为新增；现有 19 个 napi 导出与 `Index.d.ts` 不动，老路径经 `KcBridge` 继续可用；
- **不做能力广告变化**：`capabilities.v1.json` 与 identity 广告范围不变（`setCapabilities` 只是把既有能力集入口契约化）；
- **风险**：`contractVersion` 常量若与 native 生成值漂移会拒绝启动 ⇒ 由 `check-native-contract.py` C 组转阻塞 + CI 双端校验兜底；
- **不在本 CCR**：`setSftpRoots` 实装、HUKS 私钥移民、`setAutoAcceptSec` 与 autoSave 合并。

## 4. 验收（生效条件）

1. CodeArts 评审通过（重点：新增方法签名是否贴现有导出、`contractVersion` 失败语义、注释准确性）；
2. Omp-ArkTS（bridge 侧）与 Omp-Native（导出侧）双方书面确认签名一致；
3. `contract/kcbridge.d.ts` 更新后：`tools/check-native-contract.py` **C 组转阻塞**（19→27 方法集合相等）；
4. 阶段 B 门禁：`contractVersion` 桩用例、14 kind 映射单测、真机冒烟（连接/配对/收发一图）。

## 5. 状态记录

| 日期 | 事件 |
|---|---|
| 2026-11-15 | 草案提出（AtomCode，用户批准裁决建议） |
| — | 待 CodeArts 评审 + 两车道签名；生效后更新 d.ts 并排阶段 B |
