# 阶段 B 任务卡（CCR-3 生效后执行，2026-11-15 预置）

> 依据：`contract/CCR-3.md`（草案）、`devdocs/MAP_KCApi_PHASEA_20261114.md` §4、`PLAN_CONSOLIDATED_20261112.md` §5。
> 用途：CCR-3 一批准即可直接派单，不用再讨论边界。字段沿用任务卡模板（目标/边界/契约/不变式/步骤/验收/风险）。

## B-1 事件映射（ArkTS，Omp-ArkTS）

- **目标**：`KcBridge` 内建 `EventKind(14) → NetEvent` 单映射表，契约层 `kind+JSON` 还原为现有类型化事件，控制器/插件零改动。
- **边界**：只改 `net/KcBridge.ets`（+ 单测）；不改控制器、插件、`Index.d.ts`。
- **契约**：`setOnEvent(cb(kind, json))`（CCR-3 §2.2，不新增方法）。
- **不变式**：未知 `kind` ⇒ 丢弃 + `notify.log`，不抛异常；同一事件的字段语义与现有 `NetEvent` 逐字段一致（映射表即唯一事实源）。
- **步骤**：① 列 14 个 kind ↔ 字段表；② 实现 `decodeEvent(kind, json): NetEvent | undefined`；③ 用例：14 个正例 + 1 未知 kind + 1 坏 JSON；④ 真机冒烟（连接/设备/收发）。
- **验收**：宿主单测覆盖 14+2 例；`hvigorw` ✅；真机日志事件字段与改前一致（同场景 diff）。
- **风险**：字段漏映射 ⇒ 用「改前/改后同场景事件 JSON 对照」兜底。

## B-2 配对/设备名原语化（ArkTS + Native，两车道）

- **目标**：ArkTS 不再自拼 `kdeconnect.pair` body；`requestPair/acceptPair/rejectPair/unpair/setDeviceName` 走 native 原语。
- **边界**：native 新增 5 个导出（内部复用现有 pair 发送逻辑）；`KcBridge` 转发；`Index`/`DeviceController` 改调用点。**不改**协议字段。
- **契约**：CCR-3 已含这 5 个方法（`requestPair`…`setDeviceName` 原在 KcApi 内，本项只是「落地」）。
- **不变式**：配对 body 的 `timestamp` 仍由发送方生成（±1800s 语义不变）；已配对路径行为不变。
- **步骤**：① native 导出 + 单测（body 断言）；② bridge 转发；③ 调用点替换；④ e2e：配对请求/接受/拒绝各一条（用现有裸 TLS 对端）。
- **验收**：e2e 3 例；`grep -rn "kdeconnect.pair" entry/src/main/ets` 只剩协议常量引用（无 body 拼装）；真机配对冒烟。
- **风险**：配对失败回退 ⇒ 保留旧 `sendPacket` 路径一个版本，超时/失败日志可回查。

## B-3 `KCError` 化 + 分发（ArkTS，Omp-ArkTS）

- **目标**：bridge 把 native 错误统一成 `KCError{code}`（`KC_E<code>: …`），调用方按 `disposition` 三分处置（FatalLink/DropPacket/Infra）。
- **边界**：`KcBridge` + 新增 `common/KcException.ets`（或复用现有）；不改 `errors.v1.json`。
- **契约**：码表不变；`kind=throw` 抛异常、`kind=event` 走事件（CCR-3 注释已写明）。
- **不变式**：未知 code ⇒ Infra + 日志，不崩；`errorCode` 不丢（payload 0–7 与 kcbridge 码空间不混用）。
- **步骤**：① 按 `errors.v1.json` 生成常量/映射；② bridge 包装；③ 用例：Throw/Drop/Infra 各 1 + 未知码；④ 真机：制造一次 401/402 路径验证。
- **验收**：单测 4 例；真机日志 `KC_E<code>` 可检索；UI toast 与 disposition 一致。
- **风险**：把 Drop 当 Throw 抛会中断链路 ⇒ 用例必须逐条对 disposition 断言。

## B-4 `contractVersion` 校验（ArkTS，Omp-ArkTS）

- **目标**：启动早期校验，不匹配拒绝 `start()`（E109 语义），日志/状态栏可见。
- **边界**：`Index.aboutToAppear` 前段 + `KcBridge`；native 侧新增 `contractVersion()` 导出（常量）。
- **契约**：CCR-3 §2.3。
- **不变式**：不匹配不得静默继续；`EXPECTED_CONTRACT_VERSION` 改动即评审点。
- **步骤**：① native 常量化；② bridge 暴露；③ 启动校验 + 状态栏；④ 桩测试（不同版本 ⇒ 未 start + 已记录）。
- **验收**：桩用例 2 例（匹配/不匹配）；真机冷启日志一行版本；`check-native-contract.py` C 组转阻塞。
- **风险**：常量漂移导致拒启动 ⇒ CI 双端校验（C 组阻塞）兜底。

## B-5 Stage-B 单写者队列（ArkTS，Omp-ArkTS；仅当 B-1 引入 await）

- **目标**：若事件还原/分发出现 await 分支，在 bridge 内加**单写者队列**，保证同设备事件按到达序处理。
- **边界**：仅 `KcBridge`；不散落控制器。
- **验收**：乱序事件用例（先 finished 后 progress）终态/计数正确；真机多文件批次不回退。
- **备注**：若 B-1 实现全程同步（无需 await），本卡**不执行**并在 MAP §4 注记理由。

## 依赖与顺序

`CCR-3 生效` → B-4（native 常量）与 B-2（native 原语）可并行 → B-1 → B-3 → B-5（条件触发）。
全部完成后：`tools/check-native-contract.py` C 组由「报告」转「阻塞」（19→27 方法集合相等）。
