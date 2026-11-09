# CCR-1: 接收模式配置项 acceptMode

- 日期：2026-11-08
- 提出人：CodeArts（依据 MSG196 AtomCode §7.3 裁决）
- 状态：**草案 — 待两车道确认 + 用户批准**
- 影响：`kcbridge.d.ts` §2、`errors.v1.json` §4、08 §5.2

## 动机

桥层契约迁移提案 C1 修正（PROPOSAL_BRIDGE_CONTRACT_MIGRATION_20261108 §3）：大文件"先传后决定"的 UX 需求——kcbridge 的 `transferOffer→acceptTransfer(destPath)` 要求 10s 内给出 destPath，对"未知文件名/大小"不友好。保留 spool→keep/discard 作为可选模式，与 offer 模式并存。

MSG196 AtomCode 裁决：§7.3 = opt-in acceptMode，进 v1 契约，需 CCR。

## 变更内容

### kcbridge.d.ts 新增

在 `KcApi` 接口中新增：

```typescript
/** 接收模式：offer（默认，需在 setAutoAcceptSec 内 acceptTransfer）| spool（先落盘，完成后 keepPayload/discardPayload） */
setAcceptMode(mode: "offer" | "spool"): void;
```

### 08 §5.2 变更

原文：
> 引擎收包 -> `packet{type:'kdeconnect.share.request', body}` 与 `transferOffer{filename}` -> ArkTS 规则化文件名 -> `acceptTransfer(destPath)` -> ... -> `transferDone{ok, path}`。超时未响应（默认 10s）自动 `rejectTransfer(E302)`。

改为：
> **offer 模式（默认）**：引擎收包 -> `packet{type:'kdeconnect.share.request', body}` 与 `transferOffer{filename}` -> ArkTS 规则化文件名 -> `acceptTransfer(destPath)` -> ... -> `transferDone{ok, path}`。超时未响应（默认 10s，可 `setAutoAcceptSec`）自动 `rejectTransfer(E302)`。
>
> **spool 模式（opt-in，`setAcceptMode("spool")`）**：引擎收包 -> `packet` 与 `transferOffer` -> 引擎自动落盘到 spool 目录 -> `transferDone{ok, path}`（path=spool 文件路径）-> ArkTS 调 `keepPayload(transferId, destPath)` 转移或 `discardPayload(transferId)` 丢弃。**无超时自动拒**（已落盘，不需限时决定）。

### errors.v1.json 无变更

两种模式都不引入新错误码。spool 模式下 `keepPayload` 失败仍报 `E402 (FILE_IO)`。

## 两车道影响

| 车道 | 影响 |
|---|---|
| Rust（Omp-Native） | 引擎需支持两种接收模式：offer 模式保持现状；spool 模式自动落盘、不超时、完成后走 keep/discard |
| ArkTS（Omp-ArkTS） | `KcBridge.ets` 新增 `setAcceptMode` wrapper；ArkTS 侧根据模式决定 UI 流程（offer=弹窗确认 destPath，spool=完成后弹窗确认 keep/discard） |

## 向后兼容

- 默认 `offer` 模式与 08 §5.2 现有行为完全一致
- `spool` 模式是 opt-in，不改变默认行为
- 未知 `acceptMode` 值按 `BAD_PARAM (E105)` 抛出

## 验收

- `contract/kcbridge.d.ts` 新增 `setAcceptMode` 签名
- 08 §5.2 更新为双模式描述
- Rust 引擎实现两种模式 + 测试
- ArkTS `KcBridge.ets` wrapper + UI 流程适配
