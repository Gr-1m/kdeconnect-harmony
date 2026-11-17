# CCR-1a: CCR-1 `setAcceptMode` 补登记 + 默认模式定为 spool

- 日期：2026-11-17
- 提出人：AtomCode（依据 Omp-Native MSG275 §2 契约缺口上报）
- 状态：**已生效（随本提交；CCR-1 的符号补登 + 一处事实修订，只增）**
- 影响：`contract/kcbridge.d.ts`（补 `setAcceptMode`）、契约版本重生成、`tools/check-native-contract.py`（STUB 登记）
- 关联：CCR-1（2026-11-09 生效，声明新增 `setAcceptMode` 但三处均未落地）、CCR-3 §2.4（stub 口径）

## 1. 事实与问题

CCR-1 文本要求 `kcbridge.d.ts` 新增 `setAcceptMode(mode: "offer" | "spool")`，
但该符号在 **契约 / napi / `Index.d.ts` 三处均不存在**（MSG275 §2 实测 grep 无输出）⇒ 契约与实现状态不一致。

同时 CCR-1 原文以 **offer 为默认** 表述，而当前 native 实现是 **spool-only**（`payload.rs settle()` 先落盘后 keep/discard，
代码中无 offer/acceptTransfer 路径）——按实况修正默认口径。

## 2. 变更

```diff
+  /**
+   * 接收模式（CCR-1 符号；CCR-1a 认定当前实现只支持 spool）：
+   * - "spool"：先落盘，完成后 keep/discard（**当前默认，实装**）；
+   * - "offer"：transferOffer 后 acceptTransfer(destPath)（**未实装**，bridge 返回 E105 + 日志）。
+   */
+  setAcceptMode(mode: "offer" | "spool"): void;
```

- **默认模式 = spool**（实况；CCR-1 的「默认 offer」表述作废）；
- `offer` 模式未实装：与 `acceptTransfer`/`rejectTransfer` 同口径，bridge stub 返回 `E105 BAD_PARAM` + 日志；
- 无 native 新导出（bridge 层能力）；`tools/check-native-contract.py` 的 `STUB_METHODS` 登记该方法。

## 3. 验收

- `check-native-contract.py`：E 组 28 项均有归属（直接 18 / 适配 4 / stub 6）；
- 契约版本重生成（Rust + ArkTS 双吊床点一致）；
- ArkTS `KcBridge.setAcceptMode('spool')` 为 no-op 成功、`'offer'` 抛/记 E105（B-1 同批落地）。

## 4. 状态记录

| 日期 | 事件 |
|---|---|
| 2026-11-17 | 缺口发现（MSG275）；补登记 + 默认 spool 事实修订同批生效 |
