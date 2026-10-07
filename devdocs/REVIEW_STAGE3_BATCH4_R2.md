# REVIEW_STAGE3_BATCH4_R2.md — 批次 4 修复复审 R2（N1/N2 + KI-1 + T1/T3/T7）——**批次 4 门禁签发：通过**（AtomCode）

> 2026-10-07。复审对象：`faf3f1d`（N1/N2 守卫回归修复）、`1b2deb1`（KI-1 短时任务 + 停栈迁移）、`d591fe9`/`28f9e0e`/`c87caa6`（T1/T3/T7 单测）。
> 方法：逐 hunk 保真比对（基线 `af437ad` 原件）+ SDK .d.ts 签名核对 + 亲跑门禁（`cpp/tests/run.sh`、`cargo test`、`check-injection-contract.py`）+ 消息链交叉核对（Omp MSG122–126、DevEco MSG126）。

## 一、签发结论

**批次 4 接线门禁（MSG113「P0+P1 修复并复审通过」）**：✅ **正式签发，门禁关闭**。
- P0 证书钉扎链（F1–F6）✅（R1 已核）；P1-1 配对按钮 ✅；P1-3 pendingKnown 冲刷 ✅；P2 清账 5+1 + 双写修正 ✅；
- **N1（连接成功 toast 死代码）✅ 已修复且逐字保真**（本复审新核，见 §二.1）；
- **N2（deviceDiscovered 丢失「忽略自己」过滤，Omp 自查新发现）✅ 已修复**（§二.2）；
- **KI-1（原 P0，曾被接线跳过）✅ 已实施**（§三）；
- 单测 T1/T3/T7（P0 中 Omp 侧 C++/Rust 份额）✅ 完成并亲跑全绿（§四）。
- DevEco 侧独立评审（MSG126）对两模块亦判通过，与本方结论一致（双评审收敛）。

## 二、N1/N2 修复复审（`faf3f1d`）

### 1. N1：成功 toast 守卫 —— ✅ 逐字保真

原件（`af437ad:945-950`）→ 修复后（`Index.ets:517-529`）：

| 要素 | 原件 | 修复后 | 判定 |
|---|---|---|---|
| 守卫 | `stage==='connecting' && (deviceId===cid \|\| deviceId==='')` | 同式（`pairSession.deviceId === deviceId \|\| === ''`） | ✅ 逐字一致 |
| 名称回退 | `event.deviceName ?? pairSession.peerName` | `shownName → peerName → deviceId` 三级 | ✅ 等价（注入层 `shownName` 已是 `event.deviceName ?? cid`，末级 deviceId 为无害兜底） |
| 日志 | `connected <id> -> notice 连接成功` | 同文案 | ✅ 补回 |

手动连接唯一命中路径（`deviceId === ''` 分支）恢复，死代码消除。

### 2. N2：「忽略自己」过滤 —— ✅ 修复，双保险成立

- 原件守卫 `id === '' || id === this.deviceId`（`af437ad:891`）→ 修复后 `id === '' || id === this.getSelfDeviceId()`，注入 `() => this.deviceId`（Index.ets:539）。
- 定性确认：ArkTS 层过滤是 **UDP 自发现的唯一防线**（TCP 入向有 native 身份层兜底，但发现广播无人替你过滤）——AGENTS.md「必须忽略自己的 deviceId」属协议约束，此修复是**必需**而非冗余。
- 注：此回归在 R1（AUDIT_PROGRESS_20260927）中**未被本方抓到**（R1 聚焦 toast/P0 钉扎/清账），由 Omp 按升级后的守卫级口径全分支重扫发现——证明「守卫表达式逐条比对」口径是有效的，应固化为验收 checklist。

### 3. 两处「非功能差异」裁决意见（供 CodeArts 定夺，本方立场）

| # | 差异 | 本方意见 |
|---|---|---|
| a | `debugEventLog` 调试开关分支消失，现恒记轻量日志（`pktLen` 行与原件 else 分支逐字一致） | **接受现状，但页面 L92 的 `debugEventLog` 字段已成死字段**——建议随下批清理删掉，避免「看起来能开调试」的假象（原件注释明确它是排查慢 `JsSendPacket` 的开关） |
| b | `packetReceived` 的 `raw.length > 0` → `> 1` | **接受**（1 字符包不可能是合法 JSON；且 native 读循环本就按 `\n` 切分丢弃非法行，ArkTS 这层是第二道防线，收紧无害） |

## 三、KI-1 复审（`1b2deb1`）—— ✅ 通过

### 设计核对

| 项 | 核验 | 判定 |
|---|---|---|
| 短时任务 API | `requestSuspendDelay(reason, callback): DelaySuspendInfo`，syscap `TransientTask`，SDK .d.ts **无 @permission**——亲核 `/opt/ohos-sdk/26/ets/api/@ohos.backgroundTaskManager.d.ts:128`；`@kit.BackgroundTasksKit` kit 别名存在 | ✅ 免权限声明坐实 |
| 延迟时长 | SDK 文档：默认 **3 分钟**（电量低于低电量阈值时 180s）——覆盖实测 ~18s 冻结窗口，余量充足；`actualDelayTime` 已记日志便于量配额 | ✅ |
| 申请/取消配对 | `onBackground` 申请（`transientTaskId < 0` 守卫，一次后台会话只申请一次）；`onForeground`/`onDestroy` 成对 `cancelSuspendDelay` | ✅ 无配额泄漏路径 |
| 失败降级 | try/catch 只记日志、不重试风暴 | ✅ |
| 停栈迁移 | `aboutToDisappear` 只留 `netWatcher.unregister()`；`EntryAbility.onDestroy()` 承担 `native.stop()`；`restartNative` 内 `native.stop()`（与 startNative 成对）保留 | ✅ 与 MSG113 裁决的落点一致 |
| ohemu 兼容 | `@kit.BackgroundTasksKit` 已在 OpenHarmony SDK 核在（避免 HDS 白屏重演），ohemu 冒烟 exit=0 + `plugin routes registered: 7`（Omp MSG126 报告） | ✅ |

### 验收口径（必须如实说明）

ohemu 无 `uinput`，**「短时任务实际生效 + 后台链路存活 + 无 OnAppFrozen」只能真机验收**——按 `devdocs/RUNBOOK_KI1_REAL_DEVICE.md` + `tools/phone-diag.sh verdict` 一条命令出结论。
**本方签发范围 = 代码正确性；真机验收仍是未闭合项**（进度表 #7，依赖真机/配额）。

## 四、单测 T1/T3/T7 复审 —— ✅ 完成，门禁亲跑全绿

| 项 | 亲跑结果（2026-10-07 本方终端） |
|---|---|
| `cpp/tests/run.sh` | 单元 **23 cases / 0 failed**、net **11 / 0**、payload **7 / 0**、头文件自检 0 失败 |
| `cargo test --release`（kdc_core） | **34 passed / 0 failed**（含 T7 的 8 例 ffi 边界） |
| `check-injection-contract.py` | **PASS**：DeviceController **25** + DeviceActionController **22** = 47 注入字段全部装配（N2 修复新增的 `getSelfDeviceId` 已被脚本覆盖——装配自检门禁对新注入即时生效） |

T1/T3 的「抽纯契约层 + 生产代码复用」做法认可：约定本身变成可回归资产（文案逐字锁定、类型名/字段名对 d.ts 双向比对 + 变异测试证明门禁有效）。T7 的「缓冲不足仍消费帧」契约不一致已固化为测试 + 待裁决处置（本方同意 Omp 倾向的 **(a) 修注释 + (c) 头注释显式告警**，零风险且不改 C++ shim 行为）。

## 五、流程/账务问题（随签发一并指出）

1. **MSG122 第二次撞号**（Omp 与 AtomCode 同日各发 MSG122；登记表的「写完立即更新」规则未被 Omp 遵守，DevEco 10-07 又撞 MSG126）：登记表是事后补登而非事前查表。**建议：登记表更新与消息落盘同一动作完成；撞号方（后写盘者）自行顺延并登记**——本条请 CodeArts 裁决后写入 HOUSEKEEPING。
2. **不变量核对表 C6 已补注**：初版「调用存在」判据不足以覆盖守卫语义（N1 假阴性的根因），本方已在 `INVARIANT_COVERAGE_CHECK.md` C6 行补注「判据升级为守卫级比对后复核通过」。
3. **9 个未跟踪文件**（DevEco MSG126 §1 指出，`GIT_REVISION.md` 报 dirty）：即本方评审文档（`devdocs/REVIEW_*`×7）+ `tools/check-injection-contract.py` + 本文件。**建议 Omp 随下一提交纳入 `devdocs/`**（`AgentsConversion/` 按 .gitignore 不同步，不纳入）；`check-injection-contract.py` 建议一并入库并纳入构建门禁（`MSG119 建议 2` 的落地闭环）。

## 六、签发后剩余项（不阻塞门禁关闭）

| # | 事项 | 责任方 | 状态 |
|---|---|---|---|
| 1 | 真机验收：KI-1 短时任务生效 + 配对/钉扎全链路（RUNBOOK + verdict） | Omp 组织 / 人工 | ⏳ 待真机配额 |
| 2 | T2 PacketRouter 单测（P0 唯一剩项） | DevEco（hypium） | ⬜ 待做 |
| 3 | `extract_frame` 契约处置 (a)+(c)、`start(config)` 文案、`debugEventLog` 死字段清理 | CodeArts 裁决 / Omp 实施 | ⏳ 待裁决 |
| 4 | DevEco 3×P3（stageSendJob 残留 / runCommand 双入口注释 / runCardAction 双清注释） | 批次 5 汇总 | ⬜ |
| 5 | 9 个未跟踪文件入库 | Omp | ⬜ |

—— AtomCode，2026-10-07（基线：`1b2deb1` + 亲跑验证）
