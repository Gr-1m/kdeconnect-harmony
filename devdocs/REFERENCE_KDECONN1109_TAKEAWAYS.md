# 参考版本借鉴清单 — kdeconn1109（其他 Agent 版本）

> 来源：`/home/cagp/WorkSpace2/kdeconnect-harmony/kdeconn1109/kdeconn-1108/`（内部目录名仍为 1108，内容为 1109）。
> **不入库**、**不整段复制**（未见 LICENSE）；引用注明「参考 kdeconn1109（其他 Agent 版本）」。
> 格式：项 | 对方做法 | 我们现状 | 结论 | 理由 | 落点。各 owner 只写自己的小节。

---

## Omp-Native（桥层阶段 1 + 错误码 + 构建/门禁）

| 项 | 对方做法 | 我们现状 | 结论 | 理由 | 落点 |
|---|---|---|---|---|---|
| **错误码契约** | `contract/errors.v1.json`：v1，101–503，含 `kind: throw\|event` 与 `disposition`（FatalLink/DropPacket/Infra）；与 `docs/kdeconnect-oh/08 §4` 逐条一致 | 现有 `error` 事件用 errno；S2 契约 v0.2 定 payload `0–7` | **采纳**（阶段 1 用其编号与分级；payload 仍用 0–7） | 已与我方映射草案同构，无需另起一套 | `devdocs/MAP_ERRORCODE_KCBRIDGE_20261108.md`（已交付 P0）；阶段 1 实现 |
| **桥接形态** | `contract/kcbridge.d.ts` v1：`contractVersion`/`generateIdentity`/`start|stop`/`setOnEvent(kind,json)`/`networkChanged`/`refreshDiscovery`/配对四命令/`sendPacket`/`sendFile`/`acceptTransfer|rejectTransfer|cancelTransfer`/`setSftpRoots`/`setAutoAcceptSec`；`EventKind` 数值 0–14 | `Index.d.ts` v2：19 函数、字符串事件、嵌套对象字段 | **采纳（阶段 1 机械对齐，需 CCR）** | 命令即入队 + 窄腰 JSON + 数值 kind 可双端同构测试；`start` 仍走事件（C2 收窄） | `PLAN_OH_KDECONNECT_MIGRATION.md`；桥层阶段 1（与 Omp-ArkTS 消费侧同批） |
| **crate 划分** | 实际 **3 crate**：`kc-core`（纯逻辑）/`kc-engine`（编排）/`kc-bridge`（NAPI 薄壳）；文档蓝图写过 5 crate（kc-lan/kc-sftp 未在此快照出现） | `rust/full/{core,napi}` 2 crate；网络/协议/状态机都在 core | **改造（阶段 2）**：先保持 2 crate，按「纯逻辑 / 编排 / 桥」三层收敛；SFTP 落地时再拆 `kc-sftp` | 对方 3 crate 实测可跑，说明不必为 5 而拆 5；拆分应服务依赖方向而不是数量 | `PLAN_OH_KDECONNECT_MIGRATION.md` §2/§3 |
| **构建集成** | `scripts/build-ohos.sh`：`ohrs build -p kc-bridge -a arm64 -a x86_64 --dist dist` → 拷 `dist/<abi>/libkcbridge.so` 到 `app/entry/libs/<abi>/` + types 包 → `hvigorw assembleHap`；要求先 `source /opt/ohos-sdk/env.sh`、`OHOS_NDK_HOME=$OHOS_SDK_HOME/26` | CMake 调 cargo，静态库→CMake 链接出 `libkdeconnect_napi.so`，hvigor 从 CMake 输出目录收集 | **借鉴（脚本化 + 预编译 .so 落位）** | 预编译 .so 把「Rust 工具链」与「hvigor 构建」解耦，Windows/CI 只需拷产物；也是 `05-prebuilt-so-integration` 的官方路径 | 阶段 1/2 的 `scripts/build-ohos.sh`；`devdocs/CPP_GUIDE.md` Windows 前置（DevEco D 项） |
| **门禁** | `scripts/check.sh`：`cargo fmt --check`；`clippy --all-targets --no-deps -- -D warnings`；按 crate `cargo test`；`cargo check -p kc-bridge` | `entry/src/main/cpp/tests/run.sh`：`cargo test -p kdc_native` + NAPI check + 注入契约 | **采纳**（补 fmt/clippy -D、crate 粒度） | 与 `docs/kdeconnect-oh/06 §2.9`、`09 §6` 的 M0 闸门一致；成本低 | `tests/run.sh` 或新增 `scripts/check.sh`（阶段 1 一并落） |
| **L2 对端** | `docs/kdetestpeer-golang/`：Go 独立协议对端（发现/建链/配对/收发 ping/文件），供 M2b 与 ArkTS 集成共用 | host 双栈 Rust↔Rust E2E + 真实 KDE 桌面互操作；无第三方独立对端 | **采纳为测试用途**（不引入 Go 依赖到产品；CI 可选 job 或手动脚本） | 独立实现对端能暴露「两边同源实现同时犯同一错」；与真实 KDE 互补 | 阶段 1 后加 `tools/` 或 CI 可选步骤；先确认许可 |
| **TLS / pairing / payload** | 实现位于 `engine/`（本次只做结构核对，未逐行读） | 我们已：rustls 双角色、CN/pin 校验、链长 1、payload 1739/超时/取消、负路径用例 | **改造（阶段 2 前逐项对照）** | 需比对配对状态机归属（引擎内 vs ArkTS `PairSession`）与 spool 策略后再定迁移面 | `PLAN_OH_KDECONNECT_MIGRATION.md` §2/§3；阶段 2 |
| **vendor / 许可** | `engine/vendor/`（228M 含产物），未见 LICENSE/README | 依赖走 crates.io + `rust/full/Cargo.lock` | **不采纳复制**；许可确认前只取设计 | 未确认许可的 vendor 不能进仓；我们已有可复现依赖链 | —（纪律） |

### Omp-Native 小结（给 CodeArts 评审）

1. **错误码**：对方 `errors.v1.json` 与 `docs/08 §4` 完全一致 ⇒ 我方 `MAP_ERRORCODE_KCBRIDGE_20261108.md` 的 E 码列**无需改**，仅需 CodeArts 对 §4 三项待裁（spool 超时 7a/7b、not-started 归 401/202、TLS 非证书失败复用 2）给结论即可开工。
2. **构建/门禁**：`ohrs` 预编译 + `check.sh` 是最值得先搬的两项，阶段 1 可落（不改协议）。
3. **crate 划分**：以 3 层（纯逻辑/编排/桥）为收敛目标，不追求 5 crate 数量。

---
（其他 owner 小节请在此文件内追加；本小节由 Omp-Native 维护）
