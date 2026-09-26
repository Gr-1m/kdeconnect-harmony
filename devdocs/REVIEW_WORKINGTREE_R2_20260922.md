# REVIEW_WORKINGTREE_R2_20260922.md — 新改动增量评审（第二轮，AtomCode）

> 2026-09-22。范围：工作区未提交改动 vs HEAD（65 文件，+6357/-2314，含 R1 修复后的新增改动）。
> 工具：code_review deep 档两轮均 0/4 维度完成（覆盖不可靠），以下 3 条发现由 AtomCode 逐条读源核实（build-profile.json5 / PROCESS.md / net_log.h / napi_events.cpp 均已读原文确认），**核实结论可信**。
> 与 R1（REVIEW_WORKINGTREE_20260922.md）的关系：R1 的 P1/P2/P3-5 均已修复闭环且本轮未再现回归。

## 发现（全部 P3，无 P0/P1/P2）

### P3-A signingConfigs 门禁 grep 命令与新版 build-profile.json5 不匹配

- 位置：`devdocs/PROCESS.md:286` vs `build-profile.json5:3`。
- 事实：本轮 diff 把 build-profile.json5 从带引号 JSON 风格重写为无引号 JSON5 风格（`signingConfigs: [],`），而同一 diff 保留的门禁命令 `grep -q '"signingConfigs": \[\]'` 只匹配旧的带引号形式——对新文件**永不匹配**，每次构建前必打 WARN。后果：假警报常态化，agent 习惯性忽略 WARN 后，DevEco 真注入 Windows 签名配置时反而漏检——恰是该门禁要抓的 SignHap 卡死事故。
- **整改**：PROCESS.md §7.1 校验命令改为匹配 JSON5 形式，如 `grep -qE 'signingConfigs:\s*\[\s*\]' build-profile.json5 || echo "WARN: signingConfigs not empty"`。

### P3-B DeferredLogFlush 把延迟的 ERROR 日志降级为 INFO 打出

- 位置：`entry/src/main/cpp/net/net_log.h:57-65`（S2/S2b 延迟日志机制）。
- 事实：`deferLogf` 入缓冲时正确保留了级别标记（"E " / "I "），但 `~DeferredLogFlush()` 用**硬编码 LOG_INFO** 把整个缓冲一次打出。而 `dispatchError`（证书不匹配、限流、ENOBUFS 队列满等真实错误）在 `_dlf` 已武装的临界区路径里走 deferLogf("E ", …)——这些错误最终以 INFO 级别出现，hilog 按级别过滤/`grep -E` 会静默漏掉，恰好削弱本次改动「锁内日志不丢」的目的。次要问题：整个多行缓冲作**单条 hilog 记录**打出，hilog 单条约 4KB 截断，日志突发时尾部丢失。
- **整改**：析构时按 `\n` 拆分逐行打，行首 "E " 用 LOG_ERROR、其余 LOG_INFO；可选：给缓冲设上限并分块冲刷（每块低于 hilog 单条上限）。

### P3-C napi_events.cpp 丢事件诊断日志缺 %{public}，deviceId 会被掩成 <private>

- 位置：`entry/src/main/cpp/napi/napi_events.cpp:173-175`。
- 事实：新增的丢事件 WARN 用裸 `%d`/`%s`：`"event dropped: tsfn call failed (type=%d device=%s)"`。HarmonyOS hilog 默认掩私密（AGENTS.md 明文记录过 errno 掩成 `<private>` 的同款坑），本 diff 其余新日志（[KDC-JS-CB]/[KDC-JS-ENTRY]）都带 %{public}，唯独这条漏了。后果：诊断真正触发时 deviceId 打成 `<private>`，无法定位是哪个设备的事件被丢——这条日志就没用了。
- **整改**：两个占位符均补 `%{public}`（deviceId 为本地生成的证书 CN，可公开；与本文件既有日志口径一致）。

## 处置建议（给 CodeArts）

三条均为低风险小改，建议一并纳入下一轮整改（不做单独补丁提交）：P3-A 是文档一行；P3-B/P3-C 是 native 侧小改，随 S2/S2b 与 MSG24 §2 相关工作收尾统一处理。R1 三项修复经本轮复评未发现回归。

—— Atomcode（glm5.3-flash），2026-09-22
