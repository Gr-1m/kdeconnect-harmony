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
- **可选方案（未决）**：
  1. **不随 UI 停栈**：把 `native.stop()` 从 `aboutToDisappear` 移到 Ability 的 `onDestroy`，链路随进程存活；
  2. **后台任务/前台服务**：配合**已声明**的 `ohos.permission.KEEP_BACKGROUND_RUNNING`（`module.json5` 现存）
     使用 `backgroundTaskManager` 长时任务，保证后台不被冻结；
  3. 折中：进入后台**不主动断链**，由系统回收时再停（并派发 `Disconnected`）。
- **归属**：**DevEco**（ArkTS 生命周期与权限/后台任务实现）+ **CodeArts**（排期与方案裁决）。
- **状态**：⬜ **未修（待裁决）** —— 本条由用户 2026-09-26 指定"很重要，记录下来"。

---

## KI-2 native「多链路卫生」P2：后半（链路收敛 / `jobs_` 回收）

- **前半已修（`927c507`）**：`sendPacket` 原先在 `connections_` 中取**第一个** `Encrypted/TlsHandshake` 连接
  ⇒ 可能选中仍在握手的链路；已改为**两轮择链**（优先 `Encrypted`，无则回退 `TlsHandshake`，保留 P0-b 语义）。
- **实测证据（2026-09-26 E2E）**：同一设备并存多条链路 —— 遥测 `conn[in=7 out=11]`（18 条）。
- **后半（未做）**：
  1. 同设备冗余链路**收敛到 1 条**（注意既有语义：`net_stack_link.cpp` 中"新链路替换旧链路时不派发
     `Disconnected`"，改动面较大 ⇒ 建议 AtomCode 评审后再动）；
  2. `jobs_` 发送条目回收（实测回收点计数 = 0）。
- **归属**：**Omp**（native）—— 建议在 AtomCode 对其余 native 议题评审后成批处理。
- **状态**：🟡 前半已修；后半 ⬜ 待评审。

---

## 附：非本项目问题（避免误判）
- 桌面端 `kdeconnect-cli --ping/--ring` 对本机**所有**设备（含 Win10Dev）均报
  `No such object path '/modules/kdeconnect/devices/<id>/ping'` ⇒ 属该 KDE Connect 版本的 D-Bus 路径/CLI 不匹配，
  **与本项目无关**；E2E 取证改用 `--share <文件>` + App 侧 hilog/页面。
