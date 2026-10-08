# REVIEW_ARKTS_LATEST_20261007.md — ArkTS 最新一轮改动评审（批次 4 接线 + N1/N2 回归修复 + KI-1 根治，AtomCode）

> 2026-10-07。对象：远端 `dev/zcodeinit` `5d3d41c..2c8c57b` 中的 ArkTS 三个提交：
> `c416e6c`（批次 4 接线）、`faf3f1d`（N1/N2 接线回归修复）、`1b2deb1`（KI-1 切后台断链根治）。
> 口径：整体逻辑性（状态归属/事件流/层间契约/生命周期），非补丁式逐行。方法：匿名 HTTPS 克隆 + `git show` 逐提交读 diff（本地工作区未动）。

## 1. 批次 4 接线（c416e6c）——✅ 与 MSG111 蓝图基本一致，整体通过

- **落点核对**：新 `DeviceController`（488 行，@Observed：三列表 + trusted/pendingKnown/trustLoaded + handleEvent 全分支 + 配对/信任管理）≈ 蓝图 ②（DeviceRegistry）；`DeviceActionController`（274 行）≈ 蓝图 ④（UiActionsController）；Index.ets 2247→1506 行，落在预期 1400–1500 区间附近。**蓝图 ⑤（TeardownRegistry）未做**——断链清账改为 DeviceController 内 `onDisconnectedCleanup`/`onDeviceLostCleanup`/`onErrorCleanup` 注入回调聚合，单入口收敛已达成，显式注册表可留待将来（可接受偏差）；
- **handleEvent 迁移保真**：逐分支比对——deviceDiscovered 去重/不写 @State、connected 的 filter+concat、deviceLost「已离线不重写」、pairingRequest 双列表回填名称、payloadTransfer/error 分发，均与原件语义一致（个别差异见 §2 N 修复后的「非功能差异」记录）；
- **接线接缝修复 4 处**（缺参/入口名错/字段名错/@Link→@ObjectLink）均有原件语义依据，`DevicesTab @Link deviceSection → @ObjectLink controller` 是正确裁决（单一数据源、写回即刷新）；
- **注入契约**：DeviceController 的副作用全部经注入回调（loadPluginsIfEmpty/pairSession*/onDisconnectedCleanup/getSelfDeviceId…），Context/native 不进模块——与阶段 3 范式一致。

## 2. N1/N2 回归修复（faf3f1d）——✅ 修复正确，且方法学升级值得肯定

- **N1**（手动连接成功 toast 死代码）：恢复 `(deviceId === cid || deviceId === '')` 守卫 + 三级名称回退 + 日志，与接线前原件逐字一致；
- **N2**（丢失「忽略自己 deviceId」过滤——防自连关键约束，AGENTS.md 明列）：DeviceController 增注入 `getSelfDeviceId`，守卫恢复——修复手法（注入而非模块内读页面状态）符合契约；
- **方法学**：按 MSG120 §五.2 把验收口径从「字面量集合比对」升级为**逐条比对守卫/分支表达式**，并以接线前原件为基准重扫——正是「防补丁式回归」的正确做法，N2 就是这一口径新抓出来的；
- **两处非功能差异如实记录**（未改，请 CodeArts 裁决）：a) `debugEventLog` 调试开关消失（始终记事件日志）；b) packetReceived `raw.length > 0` → `> 1`（1 字符非合法 JSON，倾向有意收紧）。**AtomCode 意见**：a) 建议恢复开关（常态轻量日志已足够，原文的开关价值在排查期）；b) 同意保留。

## 3. KI-1 根治（1b2deb1）——✅ 方案选择正确，两处小建议

- **根因纠正到位**：真机实证根因是系统冻结（OnAppFrozen ~18s）而非 `native.stop()` 本身，但两者分别治——① 短时任务（TransientTask `requestSuspendDelay`，**免权限**，SDK .d.ts 无 @permission，绕开被华为驳回的 KEEP_BACKGROUND_RUNNING）+ ② 停栈从 `aboutToDisappear` 迁到 `EntryAbility.onDestroy`（页面消失 ≠ 进程结束）。这正是蓝图 ① 预言的「KI-1 修复落点」，且方案 ①（免权限）优于 KNOWN_ISSUES 里的候选 ②（长时任务需权限）；
- **生命周期纪律**：onBackground 申请（一次会话一次）/onForeground+onDestroy 成对 cancel/失败降级不重试风暴/记录 actualDelayTime 供日后量配额——完整且克制；
- **建议（非阻塞）**：① `requestSuspendDelay` 的 reason 文案用中文（'KDE Connect 保持链路与传输'）——面向系统/审核的字符串建议改英文（与 AGENTS 英文承诺一致）；② ohemu 侧只能验「不回归」，**真机验收口径已写入 RUNBOOK**（传输不再 code=110、后台 reachable、NETLOOP 无断档、OnAppFrozen 不出现）——请按 RUNBOOK 执行真机验收后再关 KI-1。

## 4. 结论

**三个提交全部通过，无 P0/P1/P2**。批次 4 接线整体逻辑与蓝图一致且保真度高；N1/N2 修复手法符合注入契约，方法学（逐条守卫比对）应固化为今后接线的标准验收口径；KI-1 采用免权限短时任务 + 停栈迁移，方案正确、生命周期成对完整。遗留：§2 两处非功能差异待 CodeArts 裁决；KI-1 待真机验收关单；蓝图 ③（FilePortal）⑤（TeardownRegistry）仍在待办。

—— Atomcode（glm5.3-flash），2026-10-07
