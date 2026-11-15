# docs1115 参考评审（k0 长期规划 + plancode 预研）— 总指挥复核

日期：2026-11-15（文档生成 2026-11-14）　对象：`docs1115/`（1.9 MB，228 文件）
性质：**对我们仓库的第三方长期评审快照**（其自称评审对象 `k0`，但路径/契约/代码与我们的 `entry/src/main/cpp/rust/full`、`Index.d.ts`、`contract/` 一一对应）。
处理口径同前：**参考性输入，非硬要求**——各车道按具体情况分析 + 自审后采纳/驳回，并在 `TO_ATOMCODE` 写明理由。

## 1. 内容构成

| 部分 | 内容 |
|---|---|
| `plans/`（16 篇） | `01` 执行摘要、`02` 架构、`03` 安全、`04` 可靠性、`05` 性能、`06` 测试、`07/08/09` 30-60-90 天 / 6-12 月 / 12-24 月路线、`10` 功能矩阵、`11` 治理、`12` 风险登记、`13` 立即执行计划、`14` 证据日志、`15` RX 控制与通知 |
| `plancode/`（可执行预研） | `checks/contract_check.py`（d.ts/Rust NAPI/caps/CI 路径一致性）、`checks/architecture_guard.py`（分层/native import 边界/死页面）、`tools/generate_capabilities.py`（从 ArkTS 插件源码生成能力表并与契约比对）、`native-prework`（未配对门禁/panic 包裹/文件名冲突）、`sftp-prework`（多根只读路径 + handler 状态机，15 单测）、`napi-prework`（生命周期状态机 + per-device outbox，19 单测）、`feature-prework`（通知/分享/MPRIS/系统音量/RX，90 Bun 测试）、`ci/gitlab-ci.snippet.yml` |

## 2. 其三个 P0 主张 —— 我已逐条核到代码（**均成立，需修**）

| 主张 | 我们的现状（证据） | 判定 |
|---|---|---|
| **P0-1 未配对设备只应放行 `identity`/`pair`** | 只有 **payload** 有门禁：`connection.rs:825-845`（`payload rejected: device not paired/trusted` + `close_conn`）；ping/share/等**非 payload 包没有统一拦截** | **成立**（缺口：未配对可发其它包） |
| **P0-2 线程 panic 无包裹** | 全仓 **无 `catch_unwind`**；`connection.rs:900/928`、`payload.rs:343` 直接 `spawn`；`ENGINE_PANIC(501)` 码存在但未用于兜底 | **成立**（panic 会静默杀线程/连接） |
| **P0-3 CI 路径失真** | `.gitlab-ci.yml:17` 跑 `--manifest-path entry/src/main/cpp/rust/protocol-core/Cargo.toml`，**该目录不存在**（实际 `rust/full`、`rust/kdc_core`）；且仍 include `clang-format.yml`（C++ 已删） | **成立**（该 job 必然失败） |

> 与我们既有工作的关系：P0-1 是 MSG209/D1 的**扩展**（当时只补了 payload 断链），P0-3 与我方 `tools/check-native-contract.py` 互补（那管 d.ts↔napi，CI 路径需另修）。

## 3. 与我们规划的关系（并入建议）

- **采纳（P0，进 0.8.x 收口批）**：P0-1 未配对全类型门禁、P0-2 panic 包裹、P0-3 CI 修正；
- **采纳（P1，参考实现可直接对照）**：
  - `native-prework` 的「文件名冲突」→ 我们 payload 落盘重名策略（P1-2）；
  - `napi-prework` 的 per-device outbox / 生命周期状态机 → 对应我们「单例 + 事件有序」P1-5（阶段 B 参考）；
  - `sftp-prework` → S6（P2），先不落；
  - `feature-prework`（通知/分享/MPRIS/音量）→ 对应我们通知 reply/action、MPRIS 完整字段等 backlog（P1-6 以后）；
  - `checks/architecture_guard.py`（分层/native import 边界/死页面）→ 可并入我们 `tools/` 作为静态门禁，配合 KcBridge 阶段 A 验收「只有 bridge import native」。
- **不采纳/暂缓**：`sftp-prework` 直接落地（S6 未排）、`plans/08/09`（6-24 个月路线）中的平台不可行项（OH 通知监听/SMS 等已判定平台封死）、其「契约统一」里把 `contract/` 当现状的表述（我方 `contract/` 是桥层目标契约，非现行 NAPI 面——与我方认知一致，但文档措辞需注意）。
- **纠正其事实偏差**：`plans/03` 称「未配对门禁缺失」为高危——方向正确；但 `plans/02` 说 `contract/` 是「当前实际 NAPI 面」与事实不符（我们 `Index.d.ts` 才是现行面，`kcbridge.d.ts` 是冻结目标）。

## 4. 待车道核对的点（避免照抄）

1. P0-1 的门禁放行集合需与我们 `packet.rs` 的包分类、`connection.rs` 的路由点对齐（不能误伤 `kdeconnect.pair`/`identity`/证书校验前流程）；
2. panic 包裹只包**线程入口**（连接/接收/发送/发现），不要包整个事件循环（否则吞掉状态错误）；panic 后必须 `emit_error(501)` + 清理连接；
3. CI 修正优先「删错 job + 指向实际 crate」，不要顺手改成 `cargo test --workspace`（会拖长 CI，先最小修复）；
4. 参考实现（prework）只作骨架参考：`sftp-prework`/`feature-prework` 的类型与命名不强行对齐我们的 ArkTS 插件层。
