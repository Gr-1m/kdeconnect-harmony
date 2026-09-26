# REVIEW_STAGE3_BATCH1.md — 阶段 3 批次 1 评审：4 模块抽离（0e7c002）+ Index 接线（857300c）+ 遮罩行为差异裁决意见 + sign-debug.ps1

> 2026-09-26。评审人 Atomcode。对象：`0e7c002`（DevEco 4 模块，Omp 代提交）、`857300c`（Omp 接线，Index 3714→3438 行）、MSG68 §3 遮罩行为差异、`tools/sign-debug.ps1`（未入库）。
> **总体结论：通过。2 项 P2（遮罩误触取消配对 + showNotice 兜底分支语义漂移）+ 1 项 P3 备注。无 P0/P1。**

## 一、0e7c002（4 模块抽离）——完整性核过

| 模块 | 基线对照 | 结论 |
|---|---|---|
| 5a PairConfirmDialog（137 行） | 纯 UI，@Prop 8 字段 + onConfirm/onCancel 回抛 | ✅ 状态全在 PairSession，组件零副作用 |
| 5b RunCommandDialog（119 行） | @Prop deviceName/commands + onPick/onClose | ✅ 保留「弹层不用毛玻璃」「卡片消费点击」坑注释 |
| 5c NotificationHelper（119 行） | 旧 Index 6 方法/3 字段（log/flushLog/showNotice/resText/NOTICE_MS/noticeKey 机制） | ✅ 注入 4 点（resText/showToast/setNoticeKey/logTabVisible）方向正确：noticeKey 留页面 @State，Helper 经回调写入不反向持页面状态——分层干净 |
| 5d NetworkWatcher（86 行） | 旧 registerNetworkListener/unregisterNetworkListener | ✅ 3s 限频门控逐字保留（gate 注入页面 actionGate），注释带用户实测卡顿坑背书 |

### 发现 1（P2 候选，见第三节裁决）
5a 的遮罩 `Column.onClick(() => this.onCancel())`——旧配对弹窗遮罩**无** onClick（点卡外无反应）。行为变化属实（MSG68 §3 已声明，非隐瞒）。

## 二、857300c（接线）——全过

- **旧代码清零**：`showNotice/resText/log/flushLog/registerNetworkListener/unregisterNetworkListener/NOTICE_MS` grep 全 0；旧配对/命令弹窗内联体（`pair_dialog_title_outgoing` 等）清零 ✓；
- **注入装配**（Index:438-477）：notify 4 点注入逐条正确——resText 与旧实现逐字一致（HostContext 判空）、showToast 保持「纯字符串 + bottom 96vp」（注释带 404 坑）、setNoticeKey 写页面 @State、logTabVisible 返回 currentTab===3（旧 flushLog 的同款条件）✓；netWatcher 3 点注入（log 转 notify.log/gate 转 actionGate/triggerBroadcast）✓；
- **生命周期**：`netWatcher.register()`（477，aboutToAppear 内）与 `unregister()`（538，aboutToDisappear 内）成对 ✓；
- **LogsTab 绑定源**：`logStore: this.notify.logStore`——LogStore 本身是 @Observed 实例，@ObjectLink 绑定成立；容器 notify 非 @State 无影响（构造期一次初始化，引用不变）。omp ohemu 实测日志页正常，风险声明（未来 SDK 收紧需 @State 桥接）属实且已记录 ✓；
- **回调正确性**：5a onConfirm→`pairSession.confirm()`、onCancel→`pairSession.cancel()`；5b onPick→`runCommand(key)`、onClose→关弹窗——与旧内联体一致 ✓。

## 三、MSG68 §3 行为差异——我方裁决意见（供 DevEco/CodeArts 定夺）

**建议改回旧行为（移除遮罩 onClick）**，理由：

1. 该弹窗是**配对安全门**（验证码核对），误触成本不对称——多一次「点卡外」= 一次配对请求被取消（发 `{pair:false}` 拒绝帧给对端），而遮罩点击省下的只是一次「取消」按钮点击，按钮就在那里（danger 样式，位置明确）；
2. 与系统惯例一致：验证/确认类系统弹窗（如系统权限弹窗）遮罩点击不取消，防误触是通行语义；
3. 改动量 1 行，且方向是「回退到已验证的旧行为」，无新风险。

**若 CodeArts 裁定接受新行为**（更顺手），也成立——但应在 devdocs/ARKTS_GUIDE.md 坑册记一笔「确认类弹窗遮罩点击语义裁决」，避免后续批次（6a MprisDialog 等）不一致。

## 四、发现 2（P2 候选）：showNotice 兜底分支漂移

旧实现 `else { 文案=connect_failed + detail }` 是**兜底**（未知 key 也拼 detail）；新实现把 else 改成了显式 `connectFailed` 分支，默认初始值 `message = resText(connect_failed)`（不带 detail）变为**不可达**（所有 if/else-if 命中后都覆盖了默认值）。当前 6 个 key 全被显式覆盖 ⇒ **实际行为等价，且显式化是改进**（未知 key 从此走默认值而非伪装成 connect_failed）。判 P3 级备注而非缺陷：「行为逐字保持」的声明在此处不严格成立，但方向是变好。后续批次照此显式化即可。

## 五、sign-debug.ps1（Win10 签名脚本，未入库）——通过

逐条对照 sign-debug.sh 核过：
- bundleName `org.kde.kdeconnect` ✓（新名正确）；证书链序 leaf/中间/root ✓；validity 2 年 ✓；UDID 64 位校验 ✓；sign-alg（profile SHA256 / app SHA384）✓；
- **ACL 声明同步了 sh 侧修复**（WRITE_IMAGEVIDEO + WRITE_AUDIO，注释带 9568289 坑与用户 2026-09-22 裁决）✓——说明移植是逐坑对照而非抄骨架；
- 工程细节正确：PS 5.1 文件头带 BOM（UTF-8 解析前提）、产物写 `UTF8Encoding($false)` 无 BOM（JSON/cer 可解析）、`$ErrorActionPreference='Continue'` + 显式检查（外部命令 stderr 不误杀）、hdc 定位 toolchains 目录 ✓；
- 价值确认：localSign 零配额路线打通 Win10 侧装机——**直接解除 MSG68/67 的真机回归阻塞**（不等华为云 provision 配额）。
**建议入库**（MSG68 §6 的待确认项）：它是双机签名的第二半，只增不冲突。

## 六、结论与下一步

- 批次 1 **通过**；2×P2（遮罩 onClick 建议移除 / showNotice 显式化记录在案）由 CodeArts 裁定，遮罩一行改动可随批次 2 一并提交；
- sign-debug.ps1 建议入库（Omp 代提交即可）；
- 批次 2（6a MprisController+MprisDialog / 6b PayloadController+ReceivedFilesDialog）等 DevEco 接口设计，接口设计到达即按本口径评审（重点：Controller 持状态 vs 组件纯 UI 的边界、@ObjectLink 绑定源、旧代码清零）；
- 真机回归：Win10 侧可立即用 sign-debug.ps1 跑（零配额），不再等 provision。

—— Atomcode（glm5.3-flash），评审工作负责人
