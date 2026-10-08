# TEST_COVERAGE_PLAN_20260926.md — ArkTS↔C++/Rust 前后端边界与协议功能单测需求总结报告（AtomCode）

> 2026-09-26。对象：远端 `dev/zcodeinit`（`5d3d41c`）。
> 背景：用户要求评审「ArkTS ↔ C++/Rust 前后端交流部分」与「各自重要协议功能」，给出**哪里需要编写单元测试**的总结报告。

## 一、边界与协议功能盘点

### 1.1 NAPI 边界（前后端契约面，共约 1108 行）

| 组件 | 行数 | 职责 | 现有测试 |
|---|---|---|---|
| `Index.d.ts` | 133 | 唯一契约源（NetConfig/NetEvent×8 种/payload 字段） | ❌ 无（类型层，靠编译期） |
| `napi_exports.cpp` | 508 | 15 个导出（start/sendPacket/payload×4/setCapabilities/证书×4/验证码等） | ❌ 无直接单测（经集成间接覆盖） |
| `napi_events.cpp` | 199 | 事件桥（tsfn 投递/队列深度/drop 留痕） | ❌ 无 |
| `PacketRouter.ets`（ArkTS 侧） | 268 | 帧切分消费/pair 收口/插件包分发 | ❌ 无（PROCESS §4.2 早已规划，未落地） |

### 1.2 协议关键功能（Rust kdc_core，1368 行，R1 起为事实实现）

| 模块 | 行数 | 职责 | 现有测试 |
|---|---|---|---|
| `packet.rs` | 476 | **帧切分**（scan_frame/extract_frame）、identity 编解码、deviceId 校验、packet 解析 | ✅ **14 个 #[test]** |
| `cert.rs` | 518 | base64/PEM-DER/SPKI 提取/**验证码算法**（compute_verification_code，含对称性与 timestamp 追加用例） | ✅ 10 个 #[test] |
| `ffi.rs` | 358 | C ABI 薄 shim（内存管理/字符串转换） | ❌ **0** |
| C++ net_stack 集成 | — | 连接/握手/择链/证书钉扎/payload 落盘 | ✅ net_stack_tests 11 用例 + desktop_pair E2E + payload_e2e |

**结论概览**：Rust 核心算法层覆盖较好（24 个 Rust 单测）；**最大空白在 NAPI 边界两侧**——native 侧导出函数的取参/抛错语义、事件桥的投递/丢弃语义，ArkTS 侧 PacketRouter/PluginHost 的路由与配对状态收口，全部零直接单测。当前质量靠「集成测试 + 真机 E2E + code review」兜底，任何一侧契约改动（d.ts v2 流程）都缺乏快速回归网。

## 二、需要编写单元测试的清单（按优先级）

### P0——契约面回归网（d.ts v2 变更流程的门禁缺口）

| # | 测试对象 | 覆盖点 | 层 | 说明 |
|---|---|---|---|---|
| T1 | **napi_exports 取参/抛错语义** | 15 个导出逐一：缺参/类型错 → 必抛 TypeError（E1 约定）；正确参数 → 返回值形状；`requireArgc`/`jsGetStringStrict` 边界（argc=0、非 string、NaN） | C++（host，stub env 或抽 validate 层） | **建议先做**：P3-5 修复后这套 Strict helper 是新约定，无测试锁定易回退。落点：`cpp/tests/`，仿 test_main 的轻量断言；可将取参校验抽为纯函数层绕开 napi_env 依赖 |
| T2 | **PacketRouter 帧消费与 pair 收口** | 合法/非法 JSON 行、半包跨 read、ping 回包、pair 请求→PairSession 状态机联动、未配对设备只收 pair（其余丢弃+unpair）、v8 二次 identity 校验失败路径 | ArkTS（@ohos/hypium） | PROCESS §4.2 P0 清单的 ArkTS 半边，至今未落地；PacketRouter 是事件进 ArkTS 后的第一道闸 |
| T3 | **napi_events 事件桥** | tsfn 投递成功/失败（drop 计数 + 留痕）、队列深度回退、事件字段透传完整性（8 种 type 的字段映射与 d.ts 逐字一致） | C++（host） | drop 路径刚修过 P3-C（%{public}），语义应有测试锁定；字段透传即「d.ts 契约 → JS 可见形状」的一致性，是 v2 流程的自动门禁 |

### P1——协议语义锁定（防跨端漂移）

| # | 测试对象 | 覆盖点 | 层 |
|---|---|---|---|
| T4 | **验证码跨端向量** | 用 Android/KDE 参考实现的固定输入（公钥 DER 对 + timestamp）→ 期望 hex 输出做**黄金向量**；排序拼接/前 8 位大写/±1800s 容差边界 | Rust（已有 10 测，补跨端向量）+ ArkTS（computePairCode 与 native 输出一致性） | 
| T5 | **identity 编解码跨端向量** | build_identity/parse_identity 与 meta schema 逐字段对齐（deviceId 正则 32–38、缺 tcpPort 默认值、8KiB 上限）；自过滤（自己的 deviceId 忽略） | Rust（部分已有）+ 集成断言 |
| T6 | **caps 协商语义** | setCapabilities 汇总进 identity、未配对设备 caps 拒发（A9 语义）、插件注册表 caps 单一来源（PluginRegistry 汇总 = native 侧声明） | ArkTS（hypium，PluginRegistry 可纯逻辑测） |
| T7 | **ffi.rs shim** | 字符串/缓冲所有权与释放（无泄漏/无悬垂）、null/越界入参不 panic（返回错误码） | Rust（#[test] + valgrind 可选） | 0 覆盖；虽是薄 shim，但它是 C++↔Rust 内存边界的唯一守卫 |

### P2——补强（已有覆盖的缝隙）

| # | 测试对象 | 覆盖点 |
|---|---|---|
| T8 | net_stack_tests 补口 | 两轮择链（927c507 的新语义：优先 Encrypted、全无才回退 Handshake）尚无用例锁定；多链路冗余收敛（KI-2/P2 后半）实施时**必须先写用例** |
| T9 | PayloadController（ArkTS） | 终态驱动队列、failInflightReceives 兜底、forgetSendQueue——4 条头注释不变量的可测部分（history/持久化注入为 mock） |
| T10 | TrustStore 迁移 | 旧 rememberedDevices 格式一次性迁移、schemaVersion、损坏文件回退 |

## 三、实施建议

1. **顺序**：T1 → T2 → T3（P0 契约网，约 3 个提交）→ T4–T7（P1）→ T8–T10 随对应功能改动搭车；
2. **分层落点**：C++/Rust 侧进 `cpp/tests/`（run.sh + CI 已接好，T1 需把取参校验抽纯函数以脱离 napi_env）；ArkTS 侧用 `@ohos/hypium` table-driven（PROCESS §4.3 既有约定，命名 `Test<函数名>_<场景>`）；
3. **职责归属**（按现行分工）：Rust/C++ 测试 Omp，ArkTS 测试 DevEco，CI 门禁（host 单测 job 已存在）只需把新套件挂进 run.sh；
4. **不做的事**：不为 UI 渲染写单测（无价值）、不为 d.ts 类型本身写测试（编译期已保证）、不为 ffi 以外的薄 shim 重复测（集成测试已覆盖路径）。

—— Atomcode（glm5.3-flash），2026-09-26
