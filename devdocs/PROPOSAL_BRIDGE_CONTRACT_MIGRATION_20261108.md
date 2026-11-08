# 提案 — 桥层契约迁移（kcbridge.d.ts 形态）v0.1

- 日期：2026-11-08
- 作者：Omp-ArkTS（应所有者要求出具对比与方案）
- 参考：`docs/kdeconnect-oh/08-interface-contract.md`（冻结契约）、`09 §2/§9`（车道所有权与红线）、`10 §4`（产物流水线）
- 现状契约：`entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts`（v2，8 事件 / 18 命令）
- 相关裁决：MSG182（Rust 为主、C++ 冻结 `backup/main-cpp`、S2 实施栈 C→B）

## 1. 结论（先行）

**推荐采纳 kcbridge 的契约形态**，但**不是照抄**：带 3 处修正，且**必须与"协议逻辑归引擎"的职责边界一起迁移**——只换 d.ts 不搬协议逻辑，等于付全额迁移成本拿不到主要收益。

## 2. 差异摘要（详细对比见 MSG 讨论记录）

| 维度 | kcbridge | 现方案 | 收益方向 |
|---|---|---|---|
| 版本握手 | `contractVersion()` + d.ts 逐字节校验 + CCR | 无版本常量，纯人工流程 | kcbridge |
| 错误 | 23 码 + FatalLink/DropPacket/Infra 分级 + `errors.v1.json` | `errorCode/errorMessage`（errno 语义，无表无分级） | kcbridge |
| 事件 | 15 个数值 kind + 强类型 DTO（serde camelCase） | 8 个字符串事件 + 扁平 `NetEvent` | kcbridge（类型安全） |
| 传输 | `transferOffer→acceptTransfer(destPath)`，引擎强制 `allowedRoots`，10s 自动拒 | 先落 spool，完成后 `keepPayload/discardPayload` | kcbridge 更安全；现方案 UX 宽松 |
| 能力集 | `capabilities.v1.json` 工件 + 两侧断言 | `PluginRegistry` 汇总 push（代码即真相） | kcbridge 可审计 |
| 双端同构测试 | `scenarios/*.json` 同一剧本驱动两侧 | native 与 ArkTS 各测各的 | kcbridge（决定性） |
| 职责边界 | 引擎拥有 identity/pair/帧切分/路由 | ArkTS 持 `PacketRouter`（帧切分/配对状态机/插件路由） | 见 §4 |

## 3. 采纳时的 3 处修正（不照抄的部分）

| # | 修正 | 理由 |
|---|---|---|
| C1 | 接收保留 **spool→keep/discard 作为可选模式**（与 `transferOffer→accept` 并存，由配置项选择） | 大文件"先传后决定"的 UX；kcbridge 要求 10s 内给出 destPath，对"未知文件名/大小"不友好 |
| C2 | 允许**白名单内的命令同步返回句柄**（`sendFile→transferId`、`start→boolean`） | 纯事件驱动会让 UI 多维护一层"等待哪个事件"的关联态；白名单外的命令仍走事件 |
| C3 | 双向绑定用 **`@Param`+`@Event`**，不自造语法糖 | 与 08 §3 一致，避免二次封装 |

## 4. 关键分歧：职责边界（必须先裁决）

kcbridge 隐含「**引擎拥有协议逻辑**」：

| 选项 | 内容 | 收益 | 代价 |
|---|---|---|---|
| **A（随契约一起迁）** | `PacketRouter` 的帧切分、配对状态机、插件路由下沉 Rust 引擎 | 协议单实现、Rust 强类型 + fuzz + 场景测试；ArkTS 变薄可 Mock 独立开发 | ArkTS 现有 `PacketRouter`/`PluginHost`/`TrustStore` 大改；每个 packet 过桥（跨语言流量↑）；无 native 时 ArkTS 跑不了真协议 |
| **B（只换接口）** | 保留 ArkTS 侧协议逻辑，只把命令/事件名与错误表对齐 | 改动小 | 拿不到"协议单实现/可 fuzz/场景双绿"的主收益，且两套语义并存更易漂移 |
| **C（维持现状）** | 继续 `libkdeconnect_napi.so` | 零迁移 | 继续承担口径漂移（实例：MSG174/192 blurStyle/bar_bg 来回）、错误不可分类、集成靠人肉对表 |

**建议 A**；仅在"0.9.0 最终不采用 Rust 栈、退回 C++ 双层"时才选 C。

## 5. 分阶段实施（每阶段可独立验收、可回退）

| 阶段 | 内容 | 验收 | 回退 |
|---|---|---|---|
| **P0 工件先行**（不写实现） | 建 `contract/`：`kcbridge.d.ts`（08 §2 逐字）、`errors.v1.json`（23 码）、`capabilities.v1.json`（14 插件键，与本仓 `PluginRegistry` 现状逐项比对差异）、`scenarios/*.json` 起步集（pairing-in / share-in / share-out / ping） | 工件齐 + 与本仓现状的差异清单（预期差异：notifications reply/action 排除、battery/connectivityreport 默认 false） | 删目录 |
| **P1 ArkTS 侧先行** | `bridge/KcBridge.ets`（唯一 import native 处）+ `MockKcEngine`（场景回放）+ `KcException`（`KC_E<code>:` 解析）；旧封装并行保留 | `tools/arkts-logic-test.sh` 绿；Mock 回放 P0 全部场景并断言 `expectCall` | 保留旧封装即可 |
| **P2 引擎实现**（Rust 车道，`dev/native-rust`） | 19 命令 + 15 事件 + `contractVersion` + panic→`E501` + `allowedRoots` 强制 | 关卡 I2：**同一份 scenarios 在 Rust host 测试与 ArkTS Mock 都绿**；`cargo test -p kdc_native` | 分支未 push，不影响 main |
| **P3 灰度切换** | `engineFactory`（real/mock 开关）+ 打包双 `.so`（体积对照）+ 真机 I3/I4 | 关卡 I3：真机 `contractVersion` 比对通过 + 收到真 `engineStarted`；I4 配对 SAS 双端一致 | 开关切回旧桥 |
| **P4 收口** | 删旧 `Index.d.ts`/旧封装/旧事件桥（clean cutover，无别名无 shim） | `hvigorw assembleHap` 零 error + 全场景绿 + 真机回归 | git revert |

## 6. 风险表

| 风险 | 影响 | 缓解 |
|---|---|---|
| 双契约并行期漂移 | 两边各改一半 | P1 起 `contract/` 只走 CCR；build 脚本加 d.ts 逐字节校验（10 §4.2） |
| 事件过桥流量增加 | 高频 packet（MPRIS/通知）跨语言开销 | 事件批量/限频（08 §3 已规定 progress ≥512KiB 或 ≥500ms 一报）；实测对照后再定 |
| 打包双 `.so` | HAP 体积 | P3 实测体积；切换完成后 P4 删除旧 `.so` |
| ArkTS 无 native 时功能缺失 | 开发期体验 | Mock + 场景集（P1 即覆盖） |
| 与 S2 并行改同一批文件 | 冲突 | 按 S2 契约把 ArkTS 批量 UI 落在 `state/PayloadController`+`components/FilesTab`，桥层改造落 `bridge/`、`persist/`；两批文件不重叠（已在 MSG196/197 声明） |

## 7. 需裁决项

1. **§4 选 A/B/C**（本次核心）；
2. 迁移是否作为 **0.9.0 的组成部分**（与全 Rust 栈合并同一窗口）；
3. C1 的 spool 模式是否进 v1 契约（改 08 需 CCR）；
4. `capabilities.v1.json` 与现 `PluginRegistry` 的差异谁拍板（battery/connectivityreport 默认值、notifications 能力）；
5. `contract/` 目录落点（本仓根 `contract/` vs `entry/src/main/cpp/types/` 旁）。

—— Omp-ArkTS（不 commit/push）
