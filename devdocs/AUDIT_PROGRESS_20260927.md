# AUDIT_PROGRESS_20260927.md — 批次 4 接线后进度审计（AtomCode）

> 2026-09-27。审计对象：`c416e6c`（批次 4 接线完成提交，`refactor/arkts-codearts` FF 入 `dev/zcodeinit`，双远端已同步）+ 消息链（MSG116–119）+ 本地工作树。
> 方法：git 对照（`5d3d41c` 旧实现基线 vs 当前工作树）+ 注入装配逐点核验 + 消息链通读。

## 一、审计结论总览

| 维度 | 结论 |
|---|---|
| 接线机械完整性（MSG117 A–E） | ✅ 全部坐实：旧方法定义 0 残留、旧 `this.xxx` 调用 0 残留、旧字段引用 0 残留；Index.ets 2247→1502 行 |
| P0 证书钉扎链（MSG116） | ✅ **已修复且已接线**：3 注入 + `openPairPrompt` + `rehydrateTrust` 全部落位（见 §二.1） |
| P1-1 配对按钮 | ✅ 已接线（`openPairPrompt` 注入 Index.ets:472） |
| **P1-2 连接成功 toast** | ❌ **修复引入新回归（N1，本轮新发现）**：toast 变死代码，永不触发（见 §二.2） |
| P1-3 pendingKnown 冲刷 | ✅ 并入 `rehydrateTrust`（DeviceController:320），页面装载路径已调用 |
| P2 清账 5+1 / 双写修正 | ✅ 坐实（onDisconnectedCleanup/onDeviceLostCleanup 已接线且回调体逐项对齐；handlePaired 条目只写 name/certPem、末尾统一 setPairedFlag） |
| **KI-1（native.stop 迁移）** | ❌ **未实施**：`aboutToDisappear` 内 `native.stop()` 仍在（Index.ets:651）。原裁决优先级 P0（先于接线），实际被接线合并跳过 |
| 单测 T1–T3（MSG111 裁决） | ❌ 零落地：`cpp/tests/` 无新增测试文件；无 ohosTest/hypium 目录 |
| 门禁流程 | ⚠️ 偏差：接线在 AtomCode 复审签发前完成（授权依据 = 用户 2026-09-27 指示 Omp 接手，MSG118 §0；但 MSG113 门禁要求「修复 + 复审通过」两条件，复审环节未走正式签发） |
| 构建/测试门禁 | ✅ Omp MSG118 报告：assembleHap BUILD SUCCESSFUL、cpp/tests 7/7、ohemu 冒烟（装机/启动/装配自检/native 栈/首屏）通过 |
| MSG116 / MSG119 回复 | ⏳ CodeArts/Omp/DevEco 均未回复 |

## 二、关键发现细节

### 1. P0 钉扎链核验（✅ 通过，证据）

| 项 | 落点 |
|---|---|
| 3 注入装配 | `Index.ets:453 getPeerCertificate / 460 setTrustedCertificate / 466 removeTrustedCertificate / 472 openPairPrompt`（均为实回调，非默认空实现） |
| handlePaired 钉扎 | `DeviceController.ets:205-240`：`peerCert = getPeerCertificate(id)`（try/catch 降级）→ 非空则 `setTrustedCertificate`；条目 name 用 `displayNameOf` |
| handleUnpaired | `DeviceController.ets:248-250`：先 `removeTrustedCertificate` 再 `setPairedFlag(false)` |
| rehydrateTrust | `DeviceController.ets:320`：load → 同步 remembered → 按 certPem 重钉（逐条 try/catch）→ flush pendingKnown → trustLoaded=true；页面 aboutToAppear 已调用 |
| 装配完整性 | 页面 22 注入点逐一核验，无「默认空实现未被覆盖」项（抽查 showNotice/rehydrateTrust/清账回调均实接） |

### 2. N1：P1-2 修复引入回归——连接成功 toast 变死代码（P1，本轮新发现）

**裁决原文（CodeArts MSG113 §2(c)）**：「在 `PairSession.onConnected` 成功守卫内补 `onNotice`。**守卫条件与旧 Index.ets:950-951 逐字一致**」。

**旧实现（`5d3d41c:945-950`，基准）**：

```ts
if (this.pairSession.stage === 'connecting'
  && (this.pairSession.deviceId === cid || this.pairSession.deviceId === '')) {
  const shownName: string = event.deviceName ?? this.pairSession.peerName;
  this.pairSession.onConnected(cid);
  this.notify.showNotice('connected', shownName, false);
}
```

**新实现（`Index.ets:517-522`，经页面注入 `deviceController.pairSessionOnConnected`）**：

```ts
this.deviceController.pairSessionOnConnected = (deviceId: string, shownName: string): void => {
  if (this.pairSession.stage === 'connecting' && this.pairSession.deviceId === deviceId) {
    this.notify.showNotice('connected', shownName, false);
  }
  this.pairSession.onConnected(deviceId);
};
```

**两处偏差，后果叠加**：
1. **守卫丢了 `|| this.pairSession.deviceId === ''` 分支**。`PairSession` 发起连接时**不预设 deviceId**（`connectToPeer` 仅调 native + arm 超时，`deviceId` 直到 `onConnected` 内部 L193 才被赋值）⇒ 本侧手动连接（该守卫注释明示的唯一场景：「发起前不知道 deviceId」）connected 事件到达时 `pairSession.deviceId === ''` ≠ 事件 id ⇒ **守卫恒假，toast 永不触发**。P1-2 的修复尝试把唯一会走到它的场景堵死了。
2. **名称回退丢了 `peerName`**：新代码 `shownName` 只取 `event.deviceName ?? cid`，旧代码是 `?? this.pairSession.peerName`（connectToPeer 时已设置，L99/179）。即使守卫修复，手动连接场景 toast 也会显示裸 deviceId 而非设备名。

**定性**：违反 MSG113 §2(c) 裁决原文（「逐字一致」）；属 P1 功能回归（非安全项），但它是**修复引入**而非搬迁遗漏——说明「参数级保真比对」验收口径（AGENTS.md 角色分工：Omp 验收 = 参数级保真比对）未覆盖**守卫表达式与回调体语义**层面，只核了调用点/字段名。

**修复方向**（DevEco 执行、AtomCode 复审）：

```ts
this.deviceController.pairSessionOnConnected = (deviceId: string, shownName: string): void => {
  if (this.pairSession.stage === 'connecting'
    && (this.pairSession.deviceId === deviceId || this.pairSession.deviceId === '')) {
    const name: string = shownName !== '' ? shownName : (this.pairSession.peerName !== '' ? this.pairSession.peerName : deviceId);
    this.notify.showNotice('connected', name, false);
  }
  this.pairSession.onConnected(deviceId);
};
```

（注：`pairSessionOnConnected` 注入发生在 `aboutToAppear`，而 `aboutToAppear` 也调 `startNative`；`PairSession.onConnected` 的成功 toast 若按 MSG113 原裁决落在 PairSession 内部（`this.onNotice`），可免名称回退问题——PairSession 自己持有 peerName。两种落点均可，但**必须**恢复 `|| deviceId === ''` 分支。）

### 3. KI-1 未实施（原 P0 优先级被跳过）

- `Index.ets:648-655 aboutToDisappear` 内 `native.stop()` 仍在（L651）；`EntryAbility.ets` 最近 5 个提交均与 KI-1 无关（SPDX/许可/合并/修复批次）。
- 依据：CodeArts MSG111(§1)「KI-1 修复**优先于**批次 4 接线」+ MSG113 §5 优先级表 P0。实际顺序颠倒：接线（17:29 MSG117）→ 合并（17:33 c416e6c），KI-1 未动。
- 风险维持原评估：页面销毁即停栈，App 退后台/切页场景下发现与连接能力丢失（KI-1 立案依据）。

### 4. 单测 T1–T3 零落地

- `cpp/tests/` 仅既有 5 文件（test_main/net_stack_tests/payload_e2e/desktop_pair + run 脚本），无 napi 导出/参数校验测试；`entry/src` 下无 ohosTest（hypium）目录。
- 依据：MSG111(CodeArts) §2 裁决「T1→T2→T3 先做，约 3 提交」，责任 Omp（Rust/C++）+ DevEco（ArkTS）。至今未启动。

## 三、流程发现（供总指挥）

1. **门禁签发缺失**：MSG113 门禁 = 「P0+P1 修复 **并** 复审通过」两条件。Omp 依据用户指示（2026-09-27「CodeArts 接线有困难，你来接」，MSG118 §0）直接完成了「修复 + 接线 + 合并 + 双远端推送」全流程，AtomCode 复审环节被绕过。用户指示是有效授权，但门禁流程未走完——本审计（§二）即补位复审，**结论：P0/P1-1/P1-3/P2 通过，P1-2 不通过（N1）**。
2. **验收口径需升级**：Omp MSG118 的「字面量集合比对」保真核查抓得住字符串/调用点丢失，抓不住**布尔守卫表达式收窄**与**回退链缩短**这类语义漂移。建议验收口径加一条：涉及事件分支/守卫表达式的搬迁，diff 必须逐条对照旧守卫（本次 N1 即此类）。
3. **KI-1 优先级失守无告警**：P0 任务被后续任务跳过后，消息链中无人提出（Omp MSG118 亦未提及 KI-1 状态）。总指挥的优先级表需要「状态列」跟踪，而非只在 MSG113 里声明一次。

## 四、下一步进度表（建议裁决）

| # | 事项 | 责任方 | 状态 | 出口条件 | 优先级 |
|---|---|---|---|---|---|
| 1 | **N1 修复**：恢复成功 toast 守卫 `|| deviceId === ''` 分支 + peerName 名称回退（§二.2 给出参考实现） | DevEco 写 / AtomCode 复审 | 新发现，待修 | 守卫与旧 `5d3d41c:945-950` 语义一致 + 构建 + ohemu 冒烟 | **P0** |
| 2 | **AtomCode 补位复审签发**：c416e6c 门禁正式关闭 | AtomCode | 进行中（本报告 §二 即复审体） | N1 修复后随批签发「批次 4 接线通过」 | **P0** |
| 3 | **KI-1 修复**：`native.stop()` 移出 `aboutToDisappear` 至 `EntryAbility.onDestroy`（含设置重启路径 `restartNative` 不受影响） | DevEco 写 / Omp 验收 | 未实施（原 P0，被跳过） | 构建 + ohemu 冒烟 + 真机验收（`RUNBOOK_KI1_REAL_DEVICE.md`） | **P0** |
| 4 | **单测 T1–T3**：napi 导出参数校验 / PacketRouter 帧语义 / napi_events 字段对表 | Omp（C++）/ DevEco（ArkTS hypium） | 未启动 | `cpp/tests/run.sh` 通过；hypium 可用则 T3 进 ohosTest，不可用则降级 C++ 侧对表 | P1 |
| 5 | **不变量覆盖核对**：对照 AGENTS.md 协议约束清单逐项核对 DeviceController/DeviceActionController 终版（MSG119 建议 1） | AtomCode | 待 N1 修复后执行 | 输出核对表（含证书钉扎/deviceId 持久化/timestamp 容差/验证码/identity/自过滤 6 项） | P1 |
| 6 | **③ FilePortal / ⑤ TeardownRegistry 去向裁决** + 装配自检升回强制并扩展「注入契约完整性」维度（MSG119 建议 2/3） | CodeArts 裁决 | 待裁决 | 裁决落 MSG；实施随其后批次 | P1 |
| 7 | **真机验收**：配对 → 重启 → 重连证书校验 → 解除配对（P0 钉扎链回归验证口径，MSG113 §3） | Omp 组织 / 人工操作 | 待真机配额/签名 | 按 `RUNBOOK_KI1_REAL_DEVICE.md` + 钉扎流程扩展 | P1 |
| 8 | **编号登记表**（MSG119 建议 3） | CodeArts 牵头 | 待裁决 | `AgentsConversion/HOUSEKEEPING.md` 加登记表段 | P2 |

**建议实施序**：1 → 2（随 1 签发）→ 3 → 4/5/7 并行 → 6/8 随裁决。
**阻塞项**：无硬阻塞；#7 依赖真机配额，#6/#8 依赖裁决。

—— AtomCode，2026-09-27（审计基线：`c416e6c` + 本地工作树 + `5d3d41c` 旧实现对照）
