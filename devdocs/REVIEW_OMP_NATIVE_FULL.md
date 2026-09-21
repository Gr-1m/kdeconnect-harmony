# REVIEW_OMP_NATIVE_FULL.md — omp native 线全量审计（整体逻辑，非补丁式）

> 2026-09-19。审计人 Atomcode。对象：`kdc-native-omp`（`dev/zcodeinit` @ `ea2cf83`）`entry/src/main/cpp` 自研代码 ~5300 行 + 测试 ~2600 行（vendor BearSSL/cJSON 与 rust/kdc_core 不在本轮深审范围，shim 边界已核）。方法：逐文件通读（net_stack ×3 TU、tcp_connection、tcp_server、udp_discovery、packet_io shim、tls_engine、cert_gen、payload、napi 两件、eventLoop 锁路径），并本机复跑全部测试。
> **总体结论：架构成立，锁纪律与失败路径是三条线的共同强项；未发现 P0/P1。2 项 P2（结构性观察）+ 6 项 P3。**

## 一、整体逻辑评价（审计主报告）

### 1.1 做对了的结构性决策（值得固化，勿回退）

1. **锁序契约被文档化且有测试**：`connMutex_ → payload.mu_` 单向、跨锁调用一律先出临界区（startSend 取 peerCertPem、sendControlFrame 均在 mu_ 外，P0-3 注释在案），`payloadLockOrder` 用例把契约钉进回归——这是同类项目最常烂掉的地方，这里守住了；
2. **单写者不变量贯穿到底**：sendPacket 只入队（JS 线程零 I/O），flushTx 唯一写者，明文帧与 TLS 记录靠「flushPlain 排空后才 startTlsHandshake」保证不交错（协议顺序不变量有注释、有卡顿根因背书）；
3. **EPOLLET 的三个经典坑全部被踩平且有注释链**：读必到 EAGAIN（fillTlsRx 循环）、握手完成当次必 drain（防边沿丢失）、EPOLLOUT 按需挂/摘（S3 唯一设施，连接侧与 payload 侧共用）——注释里保留了真机实测数据（1 万次/秒空转、5.4s CPU），这是团队记忆的正确存法；
4. **两阶段 dispatchFrames**（S1）：锁内只搬帧，解析/决策/派发全在锁外；fd 回写用「重定位 + 失效即作废」处理连接竞争销毁——tick 快照用 (fd, 指针) 双重确认防 fd 复用，是正确的防悬垂模式；
5. **失败路径全部有界**：握手 deadline、identity 超时、payload accept 超时、stall 无进展超时、TX 队列上限、rxBuf 上限、runUntil drive guard 4096——「任何病态路径都不烧核、不挂死」在三层（引擎/连接/栈）都有兜底；
6. **可观测性即架构**：KDC-NETLOOP/KDC-PAYLOAD/LOCKHOLD/HoldTimer 把「等锁 vs CPU」区分开，且 S4 用 KDC_TELEMETRY 编译期开关保证 release 干净——埋点不再是事后补丁而是设计的一部分。

### 1.2 P2（结构性观察，建议排期讨论而非立即改）

- **P2-A：NAPI tsfn 队列无界**（napi_events.cpp：`max_queue_size=0`）。JS 线程长卡时事件无限积压，内存无上界；且 packet 事件携带完整 packet 字符串，积压代价不小。事件本身不允许丢（断链/终态语义），无界是正确默认，但缺一个「积压深度观测」——建议加原子计数进 NETLOOP 统计行，超阈值告警，把「无界」变成「可见的无界」。不建议改有限队列（会丢终态事件，违反层间契约）；
- **P2-B：receive 任务终态后只能靠 settle() 回收**。onTick 只回收 send 任务（正确——receive 结果要留给上层落盘）；但用户若永不点「保存/丢弃」，finished+keep 的 receive 任务连带 spool 文件永久驻留。当前量级无害（历史列表驱动 settle），属于「上层契约兜底」——建议 in-app 加一条兜底（如 finished 后 N 小时的 receive 任务连同 spool 一并清），或明确记录该契约依赖 ArkTS PayloadHistory，防未来重构打破。

### 1.3 P3（记录在案，随批处理）

1. `udp_discovery.broadcast()` 末尾 `LOGE(...strerror(errno))` 的 errno 是**最后一次 sendto** 的，不代表「全部失败」原因——多路径失败时日志会误导定性；
2. `tcp_server.listen` 把 `MAX_UNPAIRED_CONNECTIONS`(42) 当 listen backlog 复用——语义巧合（该常量本意是未配对连接数上限），建议拆出 `LISTEN_BACKLOG` 常量，防未来调 42 时顺带改掉 backlog；
3. `connectToPeer` 中 connections_ 登记与 writeInterest.armed 置位分两次取锁，间隙内事件循环可能先跑一轮 onConnectionWritable——行为正确（MOD 幂等）但属可收敛的窗口，合并为一次持锁更干净；
4. `fillTlsRx` 的 rxBuf 上限检查在 append **前**，单次 16KiB 读后可能轻微越限才在下轮判死——把检查移到 append 后更精确（现状只是晚一拍，无危害）；
5. `payload.startReceive` 的立即失败路径（fd setup/connect 失败）会派发 failed 事件但从未派发 started——ArkTS 侧按「无 started 的 failed」容忍即可，建议在 d.ts 注释里写明该序列合法；
6. `readPlainFrame` 的 MSG_PEEK+精确消费实现正确，但 consume 循环对 EAGAIN `continue` 在理论上可自旋（数据已在内核缓冲，实际不触发）——可加一次性 EAGAIN 计数防御。

### 1.4 测试覆盖评价

- 覆盖面与断言质量**好**：173 处断言分布合理；契约类用例（链路替换不误杀载荷、设备断链派发带 id 终态、握手期发包排队、announced-without-port 终态化）直指历史上真实踩过的坑；
- harness 设计好：每用例独立进程 + 3 次重试 + 用例间静默 + 头文件自足检查——时序脆性被显式管理而非掩盖；
- 缺口：`desktop_pair.cpp` 是手工联调工具（0 断言，属预期）；**CN!=deviceId 断链**（drainEncrypted 域2 P2-1 的 fail-closed）没有 host 用例——它是安全语义，建议补一条「伪造 CN 对端被拒」的负路径用例；证书钉扎 mismatch 路径同样只有 dispatchError 观测、无直接用例。

### 1.5 与评审历史的一致性

此前 MSG19 复核的 4 项修复（jobs_ 泄漏、EPOLLOUT 收口、链路替换顺序、延迟日志）在当前代码中形态完好、无回退迹象；S1–S5 重构后注释链完整保留了「为什么」——审计期间所有反直觉代码都能靠注释自证，这是重构质量最直接的证据。

## 二、测试复验（本机）

- 纯函数单测 + net 9/9 + payload 集成 7/7（含连续 4 发并发验证）+ 头自足 failed=0 —— **全绿**。

—— Atomcode（glm5.3-flash），评审工作负责人
