# CCR-3a: EventKind 增补 3 项（Connected / Disconnected / Error）

- 日期：2026-11-17
- 提出人：AtomCode（依据 Omp-Native MSG265 §1.3 契约缺口上报 + Omp-ArkTS MSG271 §2 的映射缺口证据；用户已批准阶段 B 执行）
- 状态：**草案 → 随本提交即时生效（用户 2026-11-15 批准的阶段 B 范围内）**
- 影响：`contract/kcbridge.d.ts`（EventKind 15 → 18 项）、native `events.rs kind_of`（+3 行）、ArkTS 事件映射（15 → 18 行）
- 关联：CCR-3 §2.2（15 行对照表）、MSG265（缺口上报）、MSG271（B-1 依赖）

## 1. 动机

冻结 `EventKind` 15 项（0–14）里**没有** `connected` / `disconnected` / `error` 的对应 kind，
而这三个事件是 ArkTS 控制器的**必备输入**（连接态维护、错误分级处置）。

CCR-3 §2.2 曾把三者记为「由 `packetReceived`/`connected` 承载」，但 native 实现 kind 通道后证明：
这三类事件**没有承载它们的 kind**，只能走旧的类型化通道 ⇒ 形成「两套事件语义」（CCR-3 §2.2 与单一通道目标冲突）。

## 2. 变更内容（只增）

在 `contract/kcbridge.d.ts` 的 `EventKind` 末尾追加：

```typescript
  /** CCR-3a：连接建立（含设备名/角色）。 */
  readonly Connected: 15;
  /** CCR-3a：连接断开。 */
  readonly Disconnected: 16;
  /** CCR-3a：错误（按 errors.v1.json 处置）。 */
  readonly Error: 17;
```

- `Connected(15)` 载荷与现有 `NetEvent`（`connected`：`deviceId`/`deviceName`/`role`）一致；
- `Disconnected(16)` 载荷：`deviceId`；
- `Error(17)` 载荷：`code` + `message`（`errors.v1.json` 处置不变，`FatalLink` 才用户可见）。

## 3. 兼容性

- **只增**：已有 0–14 语义不变；类型化通道暂保留（阶段 B 过渡期双通道并存），
  待 bridge 18 行映射全量接线后由两车道确认退场时机（单独 CCR 或随验收注记）；
- 契约哈希随之变化 ⇒ `tools/gen-contract-version.py --update` 已同步重生成 Rust + ArkTS 两处常量（本提交内）。

## 4. 验收

- native `kind_of` 补 3 行 + 单测（三行各自断言）；
- ArkTS 对照表 15 → 18 行 + 单测；
- 真机：连接/断开/错误三场景在 kind 通道可见。

## 5. 状态记录

| 日期 | 事件 |
|---|---|
| 2026-11-17 | 草案即生效（用户批准的阶段 B 范围；d.ts 与两侧常量同批重生成） |
