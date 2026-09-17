# REVIEW_REFERENCE_PRACTICES.md — 借鉴参考实现（kdeconnect-kde/android）评审本项目代码（AtomCode）

> 2026-09-17。方法：通读 KDE `lanlinkprovider.cpp`（682 行）/ `landevicelink.cpp` 与 Android `LanLinkProvider.java`（647 行）的核心机制，逐条对照本项目的 native/ArkTS 实现——**只提「参考实现做对了而我们没做」的结构性差距**，已达成项一并列出作基线。

## 一、参考实现的 5 个好实践 → 对照结果

### P-1 KDE：握手期协议版本中途变化校验 ✅ 已对齐（略强）

KDE 在 TLS 层二次 identity 处校验 `protocolVersion` 中途变化（lanlinkprovider.cpp:433-437，版本漂移即 abort）。本项目在 `handleIdentity`（ArkTS）与 native 钉扎/CN 校验覆盖了 deviceId/证书维度；**版本漂移未显式比对**——但我们的 identity 校验在 v8 加密通道内做，漂移帧会被 JSON 契约与 capabilities 缺失兜住。**结论：不补**（补一行版本断言属低价值防御），记录差异即可。

### P-2 KDE：`canReadLine` 语义——半包**静默等待**而非报错 ✅ 已对齐

KDE 对 identity 大包分块到达的处理是「`!canReadLine() → return`，等下一个 readyRead」（:423-426、:515-517）。本项目 `extractFrame` 返回 Half 时的行为一致（缓冲留待下次），且我们的实现比 KDE 多了「超限帧直接丢弃」的保护（KDE 用 `bytesAvailable > MAX` 在外层兜）。**无差距**。

### P-3 KDE：`deleteLater` 延迟析构纪律 ⚠️ 我们用「快照遍历 + 重新确认」等效达成，机制不同

KDE 全程用 Qt 对象树的 `deleteLater`（:353/:365/:489/:653）——**析构永远发生在事件循环的安全点**，回调链里引用悬垂从根上不可能。我们无对象树/事件循环框架，等价物是 MSG169 的 `(fd, 指针)` 快照遍历 + 回调后重新确认。**结论：等效但成本更高**——KDE 的纪律是「声明即可」，我们的是「每个回调点手动确认」，这正是 S1 两阶段管线（锁外解析+决策）能带来的第二层收益：**派发移出锁后，回调点数量减半，悬垂确认面同步减半**。为 S1 的必要性再加一票。

### P-4 Android：限流表用 `ConcurrentHashMap` + **双维度**（deviceId + IP）⚠️ 我们只有 IP 维度

Android 限流是两把表：`lastConnectionTimeByDeviceId`（:83）+ `lastConnectionTimeByIp`（:84）。我们只有 `lastAcceptByIp_`（trustMutex_ 下）。**差距场景**：同一 NAT 后两台设备（同 IP 不同 deviceId）快速先后连接——我们按 IP 限流会误伤第二台（KDE 侧双设备办公场景真实存在）。**建议**：补 deviceId 维度限流（identity 读完才知道 deviceId，故只能作**第二道**软限流：同 deviceId 建链后 N ms 内的新连接直接拒）。P3，与 S3 同批。

### P-5 Android/KDE：**发现与连接职责分离**——provider 只管发现/握手，link 对象管会话 ✅ 结构性对齐（native 分层清晰）

KDE/Android 都把「发现（provider）」与「设备链路（devicelink）」拆成独立类。我们对应 `UdpDiscovery`/`TcpServer`/`TcpConnection`/`NetStack` 分层，边界同样清晰——这是本项目 native 层最接近上游的部分。**无动作**；S5 拆文件时按此边界命名即可。

## 二、反向发现：我们做了而上游没做的（不要被「上游没有」误导回退）

1. **EPOLLET 按需挂/摘写兴趣**：上游是 Qt/Java 事件框架，无 raw epoll——我们的 b2c 机制是平台必需，非过度设计；
2. **tick 兜底读（P0-d）**：上游 readyRead 边沿由框架保证重放，我们 ET 无此保证——同理平台必需；
3. **R1 Rust 解析核**：上游无对应物，是鸿蒙侧的自主选择，维持。

## 三、建议动作汇总

| 项 | 级别 | 动作 | 归批 |
|---|---|---|---|
| P-4 deviceId 维度软限流 | P3 | `identity` 读完后的第二道限流（同 deviceId N ms 内重复建链拒绝） | 随 S3 公共设施批 |
| P-1 版本漂移显式断言 | 记录 | 不补，写入 EXP_LESSONS 差异清单 | 文档 |
| P-3 悬垂确认面减半 | 论据 | 并入 S1 管线重构的收益论证 | S1 |
| P-2/P-5 | 基线 | 无动作 | — |

**一句话结论**：本项目 native 层与上游的结构差距集中在「无框架兜底下的手动纪律」（快照确认、限流维度）——S1/S3 落地后这两处即收编；其余维度（半包语义、职责分层）与上游同构或更强。

—— Atomcode（glm5.3-flash），评审工作负责人
