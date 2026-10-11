# DESIGN_STAGE4_NOTIFICATION_deveco — 阶段4 方向C（通知读取 / notification）接口设计

> 2026-10-11。作者 DevEco。**状态：待 AtomCode 评审**（沿用 A1 的"先评审再落码"流程）。
> 依据：CodeArts MSG135 §3（0.8.0 需 A2：「通知读取功能基本可用（**显示+关闭**）」）、Omp MSG140 §3（A2 工作包与不确定项）、
> `docs/kdeconnect-oh/01` §8（包类型全集）、`docs/11-功能点字典.md` L90（通知同步三类型）。
> 现状：`plugins/NotificationPlugin.ets` 24 行**桩**（仅声明 caps）；无存储、无 UI。

---

## 0. ⚠️ 待核对项（本设计的前置输入，请评审方确认）

本机**无规范仓**（`kdeconnect-meta/` 与 `kdeconnect-kde` 在 Linux 侧不可达），本地文档 `01`/`05`/`11` 均**只到包类型层、无 body 字段表** ✗。故：

| # | 待核对 | 我的设计取值（依据） | 影响 |
|---|---|---|---|
| Q1 | `kdeconnect.notification` body 字段名与必填性 | `id`(string) / `appName` / `ticker` / `isClearable`(bool) / `time`（**取自 Omp MSG140 §3.1 的既定清单**，非我猜测） | 解析层 |
| Q2 | `time` 类型（number ms / ISO8601 string） | **双兼容**：`number` 或可解析字符串，均规整为 epoch ms（对齐 `09 §互作坑` 的"数值字段双兼容"惯例） | 展示排序 |
| Q3 | `kdeconnect.notification.request` body 语义 | **本期不使用**（见 §4：关闭=纯本地）⇒ Q3 **不阻塞本期** | 对端关闭延后 |
| Q4 | 是否需要 `payloadHash`/图标 payload | **本期不做**（图标需 payload 通道与哈希校验，属独立增量） | UI 仅文字 |

> **设计原则**：Q1 用**既定清单**（来自任务书，不是我的推断），未知字段**一律忽略不报错**（前向兼容，对齐 `docs/kdeconnect-oh/08 §9` 的兼容性规则）⇒ 即使 schema 有未列字段也不影响。

## 1. 协议契约（本期范围）

| 方向 | packet type | 用途 |
|---|---|---|
| incoming | `kdeconnect.notification` | 桌面把通知推给我方 ⇒ **解析 + 展示** |
| outgoing | `kdeconnect.notification.request` | 已声明 caps（保持不动）；**本期不发**（见 §4） |

## 2. 数据模型（`model/NotificationModels.ets`，新建）

```ts
export interface NotificationItem {
  id: string;          // 对端通知标识（同 id 再次到达 = 更新同一条）
  appName: string;
  ticker: string;      // 主文本（标题/摘要，对端已合成）
  isClearable: boolean;
  timeMs: number;      // 规整为 epoch ms（Q2 双兼容）
  deviceId: string;    // 来自哪台设备（多设备区分）
  receivedAtMs: number; // 本侧收到时刻（排序兜底）
}
```

**归一化函数**（纯逻辑 ⇒ 进宿主 `logic` 测试通道，见 §6）：
`normalizeNotification(deviceId, body: Object, nowMs: number): NotificationItem | undefined`
- `id` 为空 ⇒ 返回 `undefined`（丢弃，防脏条目）；
- `time` 规整：`typeof === 'number'` 直接用；字符串可 `Date.parse` 用之；否则回落 `nowMs`；
- `isClearable` 非布尔 ⇒ 视为 `true`（保守：允许本地关闭）；
- **未知字段忽略**。

## 3. 存储（`common/NotificationStore.ets`，新建，`@Observed`）

- **会话内内存**（**不持久化**）：对齐 `01` §7 的 iOS 降级范本与 Omp §3.2 的倾向（桌面版亦不持久化）；
- 每设备上限 **50 条**（FIFO 淘汰）—— 防长会话内存无界增长；
- 接口：`put(item)`（同 id 覆盖 = 更新）/ `remove(deviceId, id)` / `clearDevice(deviceId)` / `listOf(deviceId): NotificationItem[]`。

## 4. 关闭语义（**本期 = 纯本地**，关键取舍）

CodeArts 要求"显示 + **关闭**"：
- **本侧关闭**：从 store 移除该条 ⇒ **纯本地，不发包** ✓（零协议风险，本期唯一实现）；
- **对端关闭**（要求桌面也清掉）：需 `kdeconnect.notification.request` 的确切 body（**Q3 未决**）⇒ **本期不做**，登记为后续增量。

> 理由（与 A1 的 B0 同构）：宁可先交付**确定正确**的一半，也不把猜测的字段名固化进代码与测试。

## 5. 插件层（`plugins/NotificationPlugin.ets` 扩展）

```ts
onPacketReceived(packetType, body): boolean
  // 仅处理 'kdeconnect.notification'；其余 return false（交给其它插件）
  // 解析 → normalizeNotification → 若非 undefined 则 notifyEvent('notification', <JSON>)（类型化事件，批1 通道）
```
- **不新增 caps**（`notification`(in)/`notification.request`(out) 保持原样，有 `PluginRegistry.test.ets` 锁定）；
- store 由**页面持有**（插件不持 UI 状态）⇒ 插件只上抛事件，页面写 store（与 `systemvolume.sinks` 同构）。

## 6. UI 形态（**待裁决，见 §8-Q1**）

**我的建议：设备详情页（`DevicesTab`）内的「通知」折叠区块**（列表 + 每条本地关闭）。理由：
- 通知**天然按设备归属**（模型含 `deviceId`），放设备详情内语义最正；
- **不动现有 4 页签**（A1 已因"第 5 页签会挤底栏 + `syncSelectedDevice` 漂移"被否，同一理由适用）；
- 不占 6 按钮栅格（栅格已按 MSG112 §1 定版）。

**备选**：① 新页签（第 5 个）② 底部第 7 个功能卡片 ③ 独立弹窗（由设备行入口打开）。若评审选定其它形态，逻辑层（§2/§3/§5）零改动 ⇒ 可平滑迁移。

## 7. 边界与不变量

1. **不新增权限**（通知读取走 packet 通道，非系统通知监听）✓；
2. **native 零改动** ✓；
3. 上抛一律经 `PluginBase.notifyEvent`（类型化事件），不经 JSON 字符串往返；
4. **上限 50 条/设备**，防内存无界；
5. **不持久化**（重启即清空，release 说明需注明）；
6. 未知字段/未知类型**忽略不抛**（前向兼容）。

## 8. 拆分顺序与验收

| 步 | 内容 | 产出 | 验收 |
|---|---|---|---|
| C0 | 评审本设计（含 §8-Q1 UI 形态 + §0 的 Q1/Q2） | 结论 | — |
| C1 | `model/NotificationModels.ets` + `normalizeNotification`（纯逻辑） | + `logic-test` 套件 | `arkts-logic-test.ps1` 全绿（**无需设备**） |
| C2 | `common/NotificationStore.ets`（@Observed，50 上限，纯逻辑） | + 单测 | 同上（上限/覆盖/移除均可纯逻辑验） |
| C3 | `plugins/NotificationPlugin.ets` 扩展（解析 + 上抛） | + `NotificationPlugin.test.ets`（捕获式 sendFn/uiFn 断言字段名） | `devecocli build` + 设备侧 hypium |
| C4 | UI（形态待 C0 裁决） | `components/…` 或 `DevicesTab` 区块 | 构建 + ohemu 冒烟（**交互仍需真机**） |
| C5 | Index 接线（事件路由 `notification` → store） | `pages/Index.ets` | `assembleHap` + `check-injection-contract.py` |

**测试策略**：C1/C2 是纯逻辑 ⇒ 我新落地的 **无设备通道** 直接覆盖（秒级）；C3 的字段名断言走设备侧 hypium（与 `RemoteInputPlugin.test.ets` 同构）。

## 9. 请评审明确（4 项）
1. **UI 形态**（§6 建议"设备详情内折叠区块"）；
2. **§0-Q1**：`notification` body 的字段名/必填性（若有 schema，请给原文；我用的是任务书既定清单）；
3. **§0-Q2**：`time` 类型（我采用双兼容）；
4. **§4 关闭语义**：本期"纯本地关闭"是否可接受（对端关闭延后）。

—— DevEco（待评审）
