# 协议一致性校验发现（2026-11-05/07）

## 1. 证书有效期偏差（确认 Bug）

**AGENTS.md 规定**：证书有效期 -1y → +10y
**Android 端实现**（SslHelper.kt:110-111）：`notBefore = LocalDate.now().minusYears(1)`，`notAfter = LocalDate.now().plusYears(10)` → -1y → +10y ✅
**鸿蒙端实现**（cert_gen.cpp:243-250）：`notBefore = time(nullptr)`（当前时间），`notAfter = now + 10 years` → **0y → +10y** ❌

**影响**：-1 年回溯是为了防止时钟偏差——如果两台设备时钟有轻微差异，刚生成的证书可能被对端认为"尚未有效"而拒绝 TLS 握手。Android 端通过回溯 1 年避免此问题，鸿蒙端缺少此保护。

**修复方向**：在 `cert_gen.cpp` 第 243 行附近，将 `notBefore` 从 `now` 改为 `now - 1 年`（按日历年回溯，与 Android 端 `LocalDate.minusYears(1)` 语义一致）。

**归属**：Native C++（Omp 职责范围）

## 2. shutdown() 未调用风险

**NAPI 桥接契约审查发现**：`shutdown()` 函数在 Native 层导出、.d.ts 声明、ArkTS 侧均有定义，但 ArkTS 侧从未调用。

**影响**：如果 PacketRouter 或其他组件在 `aboutToDisappear` 中不调用 `shutdown()`，事件桥可能重复初始化，导致 native 回调异常。

**修复方向**：在路由重构时（0.9.0 导航直接内容方案），确保在 `aboutToDisappear` 或合适的生命周期钩子中调用 `native.shutdown()`。

**归属**：ArkTS（CodeArts 评审范围，实施由 ArkTS 开发者执行）

## 3. deviceId 正则校验不完整（可接受）

**AGENTS.md 规定**：deviceId 正则 `^[a-zA-Z0-9_-]{32,38}$`
**ArkTS 端实现**：只有长度 ≥ 32 检查，无完整正则
**Native 端实现**：完整正则校验

**结论**：格式校验委托 native 层，ArkTS 侧只做基本长度检查，可接受——native 是权威校验层。
