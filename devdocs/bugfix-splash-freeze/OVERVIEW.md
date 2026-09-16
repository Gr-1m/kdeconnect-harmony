# 开屏卡顿等待 — 合作排查目录

> 2026-09-16 创建。用户指令：「开屏卡顿等待，后台到底在等待什么（这个期间 APP 不能操作、点击无反应）。这个 BUG 不能被接受。」
>
> 本目录供所有 agent 合作解决此 BUG 使用。所有相关分析、证据、方案均写入本目录。

## BUG 描述

**现象**：APP 冷启动后，界面已渲染但**点击无反应/操作无效**，持续数秒后才恢复可交互。
**影响**：用户体验不可接受——ANR 弹窗已出现（系统判定"没有响应"）。
**范围**：开屏期 + 连接建立期（首批 battery/connectivity_report/mpris 包发送时）。

## 已知证据汇总

### P0-b2 系列（已修复）

| 修复 | commit | 效果 |
|---|---|---|
| EPOLLOUT 常驻 → 按需挂/摘 | `674d6a9` | wake[conn] 8275/s→3270/s，maxJsLockWait 2603ms→0ms |
| 设备级限流 1000ms→300ms + 链路替换语义 | `674d6a9` | connected/disconnected 0.7s 抖动消失 |
| tick 重活节流 | `674d6a9` | 网络线程 CPU ≈1核→4%核 |
| payload settle 锁外 I/O | `330bb7a` | 大文件保存不再阻塞 JS 线程 |

### 修复后仍残留

| 指标 | 修复后 | 状态 |
|---|---|---|
| THREAD_BLOCK_3S/6S | 0/0 | ✅ |
| maxJsLockWait | 0ms | ✅ |
| connected/disconnected | 10/0 | ✅ |
| 配对端到端 | 成功 + 6 张卡片 | ✅ |
| 慢 JsSendPacket | 仍 5 条（1.3~4.7s） | ⚠️ 未归零 |
| wake[conn] | ≈3270/s（CPU 4%） | ⚠️ 未归零 |
| wake[payload] | 31,526/s | ⚠️ 未修（payload fd EPOLLOUT 推迟） |

### ArkTS 侧根因清单（omp MSG174 §4，未修）

| # | 位置 | 问题 |
|---|---|---|
| 1 | Index.ets:2041-2044 | @State logText 驱动整页重渲染（每条日志一次整页重建） |
| 2 | Index.ets:1139→PacketRouter:139→MprisPlugin:395/403→Index:674/683 | 同帧 4~6 次 JSON 往返 |
| 3 | Index.ets:863 | 媒体面板 1s ticker 写 @State（每秒整页重建） |
| 4 | Index.ets:371-373 | 启动期 setColorMode + setLanguage（全量重主题） |
| 5 | DevicesTab.ets:845/861 | onAreaChange 写 @State paneWidthVp（尺寸变化即重渲染） |

### 开屏路径分析（omp MSG174 §3）

```
UIAbility.onCreate（无工作）
 → onWindowStageCreate：同步窗口调用 + 2× AppStorage.setOrCreate → loadContent
 → Index.aboutToAppear：前 3 行同步重活 → await Preferences/TrustStore（首帧在此期间渲染）
 → await 恢复后：一段无 yield 的同步块(240-305)：
   TrustStore 回灌 → native.setTrustedCertificate → native.generateCert → native.init
   → setCapabilities → native.start → 注册回调
 → onPageShow → applySettingsIfReady：setColorMode + setLanguage（配置变更=整页重主题）
```

**关键**：首帧渲染后紧接着一段同步块吃掉主线程 → "出来了但点不动/等一会儿"。

## 分析进度

| 文件 | 内容 | 作者 | 状态 |
|---|---|---|---|
| `OVERVIEW.md` | 本文件（总览） | CodeArts | ✅ 已完成 |
| `NATIVE_ANALYSIS.md` | native 侧分析（锁/线程/事件循环） | Omp | ✅ 已完成（185 行） |
| `ARKTS_ANALYSIS.md` | ArkTS 侧分析（@State/渲染/同步块） | DevEco | ✅ 已完成（129 行） |
| `REVIEW.md` | 评审与裁决 | AtomCode | ⏳ 已通知，正在写 |
| `TIMELINE.md` | 真机时序证据 | DevEco | ⏳ 待写 |
| `SOLUTION.md` | 最终方案 | 全员 | ⏳ 待讨论 |

## DevEco 分析关键结论（ARKTS_ANALYSIS.md）

1. **开屏主因 = native `sendPacket` 同步阻塞**：1.27~5.79s/次，4 次累计 ≈9.6s，JS 线程全程被卡在 native 调用内
2. **`aboutToAppear` 同步块本身无长任务**：+1.23s 主要是 Preferences/TrustStore 的 await 往返
3. **#1 logText 整页重建已基本消解**：20s 内仅 3 次 flush（900ms 合并 + 动态窗生效）
4. **hilog 假设已排除**（负结果）：瘦身事件日志后慢 `JsSendPacket` 数值几乎不变
5. **ArkTS 侧是"放大器"不是根因**：事件 JSON 往返、主题重应用等属净收益优化，但不是秒级卡顿的原因
6. **用户"关 WiFi 就不卡"坐实**：冻结是网络事件驱动的——开 WiFi ⇒ 事件涌入 ⇒ JS 线程被 tsfn 回调占满

## 根因定位（2026-09-16 23:16 突破）

**慢 `sendPacket` = `connMutex_` 锁等待**（DevEco MSG11 用 Omp 的 CPU 埋点复跑后定性）：

| 慢 JsSendPacket | maxJsLockWait | maxHold |
|---|---|---|
| 5776ms | 5775ms | 3205ms |
| 1312ms | 1285ms | 1285ms |
| 2560ms | 2560ms | 3220ms |
| 1237ms | 1238ms | 12ms |

- **1:1 吻合**（±1ms）→ JS 线程在等 `connMutex_`
- **持锁方是网络线程**：`maxHold` 1.2~3.2s
- **不是事件洪峰**：每 5s 只有个位数事件
- **下一步**：Omp 加持锁段分段计时，定位是哪一段持锁数秒

## 两份分析的共识与分歧

| 项 | Omp (native) | DevEco (ArkTS) | 结论 |
|---|---|---|---|
| 主因定位 | native 各出口 <100ms，秒级来自 ArkTS | ArkTS 同步块无长任务，秒级来自 native sendPacket | **互补**：sendPacket 在 JS 线程同步执行，属 native 调用但卡的是 JS 线程 |
| hilog 假设 | 候选 2（hilog 阻塞） | 已排除（负结果实测） | **共识**：排除 hilog |
| 下一步 | wall vs cpu 三段埋点定性 | 同意按 omp §2.4 埋点一次性定性 | **共识**：需 CPU 时间埋点 |
| 事件驱动 | — | "关 WiFi 就不卡"坐实事件驱动 | **新增关键证据** |

1. **开屏"点不动"主因不在 native**：native 各出口均 <100ms，秒级感觉来自 ArkTS 侧
2. **慢 JsSendPacket 5 条（1.3~4.7s）成因未定性**：已排除锁等待/队列积压/TX flush/epoll_ctl/TLS——指向**调度延迟或 hilog 同步写阻塞**
3. **需加 CPU 时间埋点**（wall vs cpu）一次定性：wall≫cpu ⇒ 调度/日志阻塞；wall≈cpu ⇒ 函数内真活
4. **wake[payload] 31,526/s 已定性**：payload fd 常驻 EPOLLOUT，需按新设计重做（§4.3）
5. **P2-2 每事件 16KB 堆分配**：3270 事件/秒 × 16KB ≈ 50MB/s 分配/释放，是 CPU 与抖动放大器

### omp 请求授权的 4 项

| 优先级 | 项 | 规模 |
|---|---|---|
| P0 | CPU 时间埋点（sendPacket wall/cpu/lock 三段）+ 掩码分布 | 1 文件 ~30 行 |
| P0 | payload 写兴趣按新设计重做（含 RAII 刷新点） | payload 3 处 + host 接口 1 处 |
| P1 | P2-2 每事件 16KB 堆分配 → per-connection 复用缓冲 | 1 文件 ~20 行 |
| P1 | CMake 归属注释修正 + 死代码清理 | 少量 |

## 排查方向

### native 侧（Omp 负责）
1. 慢 JsSendPacket 5 条的根因（已非锁等待，是什么？）
2. wake[conn] 3270/s 残留（是否仍有不必要的唤醒？）
3. wake[payload] 31,526/s（payload fd EPOLLOUT 常驻，推迟修复中）
4. 启动期同步块中 native 调用的耗时分解（generateCert/init/start/setTrustedCertificate 各多少 ms？）

### ArkTS 侧（DevEco 负责）
1. aboutToAppear 同步块(240-305) 的耗时分解
2. #1 logText 整页重建（开屏期日志密集 → 持续重渲染）
3. #4 setColorMode/setLanguage 启动期执行 → 全量重主题
4. #2 JSON 往返（每个 native 事件 stringify→parse→stringify→parse）
5. #3 ticker（面板打开后每秒整页重建）
6. #5 onAreaChange（尺寸变化即重渲染）

### 评审（AtomCode 负责）
1. 复核 native/ArkTS 分析的完整性与准确性
2. 评估修复方案的风险与收益
3. 验证修复效果

## 工作规则

1. **所有分析写入本目录**，不散落在 AgentsConversion 消息里
2. **消息只用于通知**（"我写了 XXX_ANALYSIS.md，请查收"），详细内容在文件里
3. **每个 agent 先写自己的分析文件**，再读其他人的
4. **最终方案 SOLUTION.md 由全员讨论后 CodeArts 定稿**
5. **修复执行仍走原流程**（omp 改 native、DevEco 改 ArkTS、commit 需授权）
