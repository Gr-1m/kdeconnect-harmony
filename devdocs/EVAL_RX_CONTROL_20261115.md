# RX 控制与通知 inbox 评估（ArkTS 车道，2026-11-15）

> 依据：MSG262 §3.3（读 `docs1115/plans/15-rx-control-and-notification.md`，出「采纳/不采纳」清单）。
> **口径**：docs1115 为参考性输入；与 `PLAN_CONSOLIDATED_20261112.md` 冲突以统一规划为准。以下「我方现状」均为 `[代码事实]`（读码确认），推断处标注 `[推断]`。

## 0. 结论速览

| 计划项 | 我方现状 | 结论 | 前提/理由 |
|---|---|---|---|
| **RX-NOTIF-1** 通知 inbox | **已有**：`NotificationPlugin.onPacketReceived('kdeconnect.notification')` → `normalizeNotification` → `PluginEvent{kind:'notification'}` → 入库/UI（`NotificationStore`/通知弹层）| **已采纳（已完成，不打补丁）** | 收方向已在跑；计划里的「inbox 建模」我们已有等价物 |
| **RX-NOTIF-2** 收到对端通知 → 系统通知栏 | 未见把对端通知投到系统通知栏的实现 `[推断：NotificationHelper 目前用于前台/常驻类通知]` | **评估 → 0.8.x 可选** | 需要 `ohos.permission.NOTIFICATION_CONTROLLER` 无关，只需本应用发通知权限（已有）；价值中等、风险低；建议等「通知允许/拒绝两路径」发布门一起做 |
| **RX-NOTIF-3** reply / action（从手机回复桌面通知）| **未实现**（无 `notification.action`/`reply` 处理） | **不采纳（本轮）**：需系统通知 action 能力 + 对端 reply 通道，属 P1-6 之后 backlog | 计划 §3.3 亦标注为后置 |
| **RX-MPRIS-1/2** 对端控制本端媒体 | **未实现**：我方只处理 `kdeconnect.mpris`（对端播放器列表/状态），**不处理** `kdeconnect.mpris.request` | **不采纳（本轮）→ 先做能力探针** | 计划 §4.3 明确「普通三方应用控制**其他应用**媒体会话能力有限」；需 spike `@ohos.multimedia.avsession`（能否查询/控制他人会话、是否需 `MANAGE_MEDIA_RESOURCES`）。**若只能控制本应用会话 ⇒ 价值低，明确不支持更诚实** |
| **RX-VOL-1** 对端控制本端音量 | **未实现**：只处理 `kdeconnect.systemvolume`（对端 sink 列表/增量），不处理 `systemvolume.set` | **不采纳（本轮）→ 同样先探针** | 改本机音量在 OpenHarmony 上「本应用音量可调 / 系统音量受限」需实测；与 RX-MPRIS 同批 spike 更经济 |
| **RemoteInput RX**（对端控制本端输入） | 我方 `RemoteInputPlugin` 是**发送**方（手机→桌面） | **不采纳**：计划 §6 自标后置 | 与安全/权限面大，非 0.8.x 范围 |

## 1. 计划里值得吸收的**协议细节**（无论是否实现 RX，都要记）

| 细节 | 来源 | 用途 |
|---|---|---|
| `SetPosition` 单位 **ms**、`Seek` 单位 **微秒**，二者大写 S | 计划 §4.1 | 将来实现 RX 或做对端兼容测试时的易错点；**现在**可用于校验我们对端的请求包（日志/测试断言） |
| `action` 首字母大写、`setVolume` 0–100 夹紧 | 计划 §4.1/§4.4 | 同上（oath: 与 `kdeconnect-meta/schemas` 对齐后再落测试） |
| 未知 player / albumArt 未实现的降级口径 | 计划 §4.4 | `MprisController` 已有「未知播放器」处理，保持 |

**动作建议**：把「单位/大小写/夹紧」写进 `devdocs/PLATFORM_INVARIANTS*.md`（或 MPRIS 设计文档）作为协议注记 —— 成本 1 段文字，避免将来踩。

## 2. 建议的探针任务（若总指挥要推进 RX）

- **RX-SPIKE-1（半天，0.8.x 可选）**：`avsession` 能力探针 —— 在模拟器/真机验证：① 能否 `getAllSessionDescriptors` 看到**其他应用**会话；② 能否对他人会话执行 play/pause/volume；③ 失败时的错误码（`201` 权限/`801` 能力不支持）。产出：一张「能做到/做不到 + 证据」表，据此决定 RX-MPRIS 是「落地」还是「明确不支持」；
- **RX-SPIKE-2（同批）**：本端音量控制可达性（`audio` 框架：本应用音量 vs 系统音量；是否需要系统权限）；
- 二者**均不承诺**在 0.8.x 交付功能，只出结论。

## 3. 不采纳的**结构性**建议（写明理由）

- 计划 §3 建议的「通知系统分层（ArkTS/Kit port + adapter）」：我方已有 `NotificationStore` + `PluginEventBus` + `NotificationHelper` 三层等价物 ⇒ **不重构**；
- 计划 §7 任务卡的命名/结构：**不照抄**（我们按 `PLAN_CONSOLIDATED` 的 P0/P1/P2 派单）；
- `plancode/feature-prework/src/inbound_control.ts` **不引入**（骨架代码，命名与分层与我们既有控制器不一致）。

—— Omp-ArkTS
