# KNOWN_ISSUES — 已知问题与待决策项（可引用的长期清单）

> 2026-09-26 建立（Omp）。用途：把**证据齐全但归属他人/需排期**的问题固定下来，避免只在消息里流转而丢失；
> 每条都带**实测证据**与**归属建议**。修复后请把状态改为 `✅ 已修（commit）`，不要删除（保留追溯）。

---

## KI-1 【重要】App 进入后台即停 native 栈 ⇒ 链路与后台能力全部失效

- **现象**：App 一旦离开前台，native 网络栈被关闭，链路立即断开 ⇒ 桌面端把该设备标记为**不可达**；
  通知/剪贴板/媒体/查找设备等**依赖链路的后台能力全部失效**，且需用户重新点连接才能恢复。
- **代码位置**：`entry/src/main/ets/pages/Index.ets:541-545`
  ```ts
  aboutToDisappear(): void {
    this.netWatcher.unregister();
    ...
    native.stop();
  }
  ```
  （另有 `Index.ets:460` 的 `native.stop()`，属另一路径，同需复核。）
- **实测证据（2026-09-26，ohemu + 真实 KDE 桌面）**：
  - App 侧 hilog：`21:28:46.620 I A00001/KDEConnect: net stack stopped` + `native stop`；
  - 桌面端在同一时刻把 `OpenHarmony 32: 1de3bacd…` 从 `(paired and reachable)` 变回 `(paired)`；
  - 这解释了此前反复观察到的**链路 flapping**（`reachable` 时有时无）——
    **更正**：先前归因于"多链路卫生 P2"的猜测**不成立**（该 P2 另有其实测证据，见 KI-2）。
- **影响面**：连接类应用的核心价值（常驻连接 + 后台收发）全部受此限制；`sign-debug.sh` 之下真机亦同。
- **权限现实（用户 2026-09-26 提供）**：`ohos.permission.KEEP_BACKGROUND_RUNNING` 属**需华为云官方申请**的受限权限，
  **用户首次申请已被驳回** ⇒ 长时后台方案（下述方案 2）**当前不可用**，阻塞在华为审批。
- **拆成两步（不互相阻塞）**：
  1. **最小修复（不需要任何权限）**：**不要把 `native.stop()` 放在页面 `aboutToDisappear`**，改为在
     `EntryAbility.onDestroy()` 停栈 ⇒ **UI 消失时链路继续存活**（覆盖"用户短暂切后台/切应用"这一最常见场景）；
     ✅ **ohemu 即可验证**（桌面侧观察 `reachable` 是否持续）——**原型实验已于 2026-09-26 完成待用户取证**；
  2. **长时后台（需要上述权限）**：进程被冻结/回收的对抗（长时任务），**等华为审批通过**后再做。
- **可选方案（未决）**：
  1. **不随 UI 停栈**：把 `native.stop()` 从 `aboutToDisappear` 移到 Ability 的 `onDestroy`，链路随进程存活；
  2. **后台任务/前台服务**：配合**已声明**的 `ohos.permission.KEEP_BACKGROUND_RUNNING`（`module.json5` 现存）
     使用 `backgroundTaskManager` 长时任务，保证后台不被冻结；
  3. 折中：进入后台**不主动断链**，由系统回收时再停（并派发 `Disconnected`）。
- **归属**：**DevEco**（ArkTS 生命周期与权限/后台任务实现）+ **CodeArts**（排期与方案裁决）。
- **旁证（供查，未断言因果）**：模拟器 faultlog 里有 2 条 `sysfreeze-org.kde.kdeconnect-…` 故障日志
  （2026-09-26 20:32/20:33，`Reason: LIFECYCLE_TIMEOUT`，`Foreground: No`），时间点与应用/模拟器生命周期切换相近，
  记此以备排查（当时安装的还是 0.2.0 旧包）。
- **用户实测确认（2026-09-26）**：用户明确表示"**后台断链是确实存在的，在之前测试中我体验过**" ⇒ 本条由「有日志证据」升级为「**用户实机体验确认的真实缺陷**」，为当前**最高优先级**待修项。
- **状态**：⬜ **未修（待 DevEco 实施 + CodeArts 裁决）** —— 用户 2026-09-26 指定"很重要，记录下来"并确认实测存在。

---

## KI-2 ✅ 已关闭（复核结论：原记录的三项**均已实现**；此前「待做」判断系我误差）

> **2026-09-26 复核更正**：本条原写「前半已修、后半待评审」，逐源核查后确认 **三项都已存在**，
> 且我曾把 `conn[in/out/hup]` 的**累计计数器**误读为「在线链路数」。证据指针如下，避免后人重复改动：

| # | 事项 | 结论 | 证据 |
|---|---|---|---|
| ① | 同设备冗余链路收敛到 1 条 | **已实现** | `net_stack_link.cpp` 的「替换同设备旧链路」：身份落定时收集同设备其它链路 → `closeConnection(sfd, "replaced by newer link")`；并含 2026-09-18 真机定位的**顺序约束**（先登记新链路再关旧链路，否则 `sameDeviceAlive` 判空 ⇒ 误派发 `Disconnected` 并 `payload_->onDeviceDown` 误杀在传载荷） |
| ② | `jobs_` 发送条目回收 | **已实现 + 有回归测试** | `payload/payload.cpp` 的 `onTick` 清扫（`PAYLOAD_JOB_REAP_MS`：发送任务终态后短宽限回收；接收任务 24h 兜底并删 spool）；测试 `tests/payload_e2e.cpp`「发送侧已终态的任务未被回收（jobs_ 泄漏回归）」 |
| ③ | 握手期链路的写兴趣语义 | **已文档化** | 提交 `9eb6f3c`：`net_stack.cpp` 注释（为何不能收紧挂载时机）+ 本条记录；AtomCode `REVIEW_OMP_CHANGES_20260926.md` §2 |

**保留的改动**：`927c507`（`sendPacket` 两轮择链）**仍然保留** —— 它不是「修多链路泄漏」，而是让
**替换窗口内**（新链路握手完成、旧链路尚未关闭）的择链确定化，属稳健性改进；其代码注释已随之更正。

### 更正记录（我自己的三处误读，均为「未读源就下结论」）
1. 「仓内查不到安全/性能评审产物」✗ —— 实际在 `devdocs/REVIEW_WORKINGTREE_20260922.md` §4（只搜了 `AgentsConversion/`，且只看关键词命中计数）；
2. 「`jobs_` 回收点计数 = 0」✗ —— 搜了 `net/` 目录，而 `jobs_` 在 `payload/payload.cpp`（且早已有回归测试）；
3. 「E2E 遥测 `conn[in=7 out=11]` = 18 条在线链路」✗ —— 那是**累计计数器**（`connIn_/connOut_/connHup_`），不是在线数。

> 教训：**跨目录取证必须逐字读源**；**计数器/命名的字面含义不能替代语义确认**。

---

## 附：非本项目问题（避免误判）
- 桌面端 `kdeconnect-cli --ping/--ring` 对本机**所有**设备（含 Win10Dev）均报
  `No such object path '/modules/kdeconnect/devices/<id>/ping'` ⇒ 属该 KDE Connect 版本的 D-Bus 路径/CLI 不匹配，
  **与本项目无关**；E2E 取证改用 `--share <文件>` + App 侧 hilog/页面。
