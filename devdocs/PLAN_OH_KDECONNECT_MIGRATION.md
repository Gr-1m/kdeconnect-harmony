# 计划：迁移到 kdeconnect-oh 规格（5 crate + kcbridge v1）——0.9.0 后执行

> 决策：用户 2026-11-08 选择 **C**——当前 `dev/native-rust`（既有 `Index.d.ts` 契约）先按规格加固并完成 0.9.0 合并；
> 本文把 `docs/kdeconnect-oh/` 的架构作为**下一个大版本窗口的正式重构计划**，**本阶段不启动**。
> 依据：`docs/kdeconnect-oh/{00,01,02,04,06,08,09,10}`（Rust 车道路由：00 → 08 → 09 → 01 全文 + 06 §2/§3）。

## 1. 目标架构（规格摘要）

| 维度 | 目标 |
|---|---|
| 契约 | `libkcbridge.so` + `contract/kcbridge.d.ts` v1：命令即入队、事件 kind(0–14) + JSON 载荷、错误码 101–503、`contractVersion`、`setOnEvent` 单注册 |
| crate | `kc-core`（纯逻辑，host 全测）/`kc-lan`（rustls 双角色+发现+payload）/`kc-sftp`（russh）/`kc-engine`（EngineActor 编排）/`kc-bridge`（薄 NAPI） |
| 并发 | 单 `EngineActor` 唯一写者 + tokio task + channel；每链路读循环 + 单写者队列 |
| 配对 | **引擎内** `pairing.rs` 状态机（转移表逐行对照上游） |
| 错误 | `KcError` + `Disposition`（FatalLink/DropPacket/Ignorable/Infra，穷举无 `_`） |
| 单一事实源 | `limits.rs`（常量）、`capabilities.v1.json`（能力）、`contract/scenarios/*.json`（双车道同构测试） |
| 闸门 | `cargo fmt --check`、`clippy --all-targets -D warnings`、`cargo test`、`cargo deny check`、`cargo audit`、fuzz 60s 冒烟、`scripts/check.sh` |
| ArkTS | MockKcEngine + reducer + RDB/Asset/Prefs 持久化 + 长时任务；不碰系统 Kit 之外的能力 |

## 2. 现有资产的去留

| 资产 | 处理 |
|---|---|
| `rust/kdc_core`（packet/cert/sas + 7896 组差分、SAS 金标） | **复用**，作为 `kc-core` 的协议纯函数基础（重命名/补类型注册表） |
| `rust/full/core` 的 rustls verifier/角色矩阵/payload 超时语义 | **移植**到 `kc-lan`；补 `PeerTrust` 显式枚举与链长 1 校验（本阶段已预热） |
| dhcp：`stack.rs` 线程模型、`state.rs` 注册表、NAPI 桥 | **重写**为 EngineActor + kc-bridge；不直接搬运 |
| `Index.d.ts` 19 函数契约 + ArkTS 调用点 | **由 kcbridge.d.ts 取代**（kind/错误码/JSON 化），ArkTS 车道按 A0–A4 重写 |
| CMake↔cargo 集成、`tools/sign-debug.sh`、ohemu 验证流程 | **复用**（`scripts/build-ohos.sh` 落 `libkcbridge.so`） |
| 设备证据（KDE 配对/文件收发、TLS 角色、证书 CN/钉扎） | 作为 `kc-lan` 的行为基线回归 |

## 3. 里程碑（对齐 `09 §6` / `10`）

| 阶段 | 交付 | DoD |
|---|---|---|
| M0 | workspace 5 crate + lints + fmt/clippy/deny/audit/fuzz 配置 + `scripts/check.sh` | 空骨架 `check.sh` 全绿 |
| M1 | `contract/` 工件（kcbridge.d.ts/errors.v1.json/capabilities.v1.json/scenarios 起步集）+ `kc-core` 契约类型 + 场景加载器 | 场景文件驱动空引擎断言 emit 序列 |
| M2a/M2b | `kc-lan` 发现/建链/TLS/链路；`kc-engine` actor + kc-cli | 对 Go protocol-peer：发现→建链→配对→ping；本机 KDE 互操作 |
| M3 | `kc-bridge` + `.so` 进 HAP | HAP 内 `contractVersion` 比对 + 真 `engineStarted` |
| M4 | ArkTS A2/A3（DeviceStore/reducer/插件队列）+ 五关卡集成 | Mock 与真引擎同场景双绿 |
| M5 | `kc-sftp`（russh，认证模型 01 §6）+ `setSftpRoots` | 桌面 sshfs 挂载实测 |

## 4. 风险与前置

1. **双写期**：0.9.0 前只维护现有契约；合并后再切 kcbridge，避免两套契约并行开发。
2. **ArkTS 重写成本**：契约形态从「函数 + 字符串事件」改为「kind + JSON」，涉及 DeviceController/Reducer/插件适配层；需 CodeArts/Omp-ArkTS 排期。
3. **依赖与工具链**：`cargo-deny/audit/fuzz`、`ohrs`、Go protocol-peer；首次构建需网络（需用户同意）。
4. **SFTP**：russh/russh-sftp 在 OHOS musl 的行为需单独探针（规格 §M5）。
5. **Android 互操作**：并入 S4 真机窗口预演；正式回归放合并后 soak。

## 5. 触发条件

- 用户批准启动（预计 0.9.0 收口后）；
- 启动前需冻结：`contract/kcbridge.d.ts` v1 逐字、`capabilities.v1.json`、场景起步集；
- 启动后按 `09 §6` 任务卡模板派单，Rust 车道从 M0 起。

—— Omp-Native，2026-11-08
