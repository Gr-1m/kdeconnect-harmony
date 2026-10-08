# 决策简报：方向 F —— HDS（沉浸光感）与 OpenHarmony 双平台

> 2026-10-08，Omp。**用途**：请用户就"目标"给一句话，据此选定实现路线。
> 标注约定：**[实测]** = 本机可复现证据；**[推断]** = 分析结论。

## 1. 问题（一句话）

UI 层**静态导入** `@kit.UIDesignKit`（HDS：`HdsTabs`/`hdsMaterial`）⇒ 在 **OpenHarmony** 侧该模块不存在，
**模块加载即失败** ⇒ 白屏（app 进程在、native 不初始化）。**静态导入无法运行期 catch**，ArkTS 的 builder 也是
编译期概念 ⇒ 只能**构建期**处理。**[实测]** 现象：hilog 报
`SyntaxError: '@hms:hds.hdsBaseComponent' does not provide an export name 'HdsTabsController'`。

## 2. 先定"目标"（路线的最优解取决于此）

| 目标 | 含义 | 结论 |
|---|---|---|
| **(甲) 仅在 ohemu 上验证 UI/链路** | 开发期自验 | **现状已够**：`tools/verify-on-ohemu.sh`（构建期降级 + 装机 + 取证，`--revert` 还原）**[实测]** |
| **(乙) 出正式 OpenHarmony 产物** | 面向开放原子渠道分发 | 需要**构建期双产物**能力（下述 A/B） |

## 3. 三条路线（证据 + 成本）

| 路线 | 做法 | 优点 | 缺点 / 风险 | 成本[推断] |
|---|---|---|---|---|
| **A 变体树** | 把 `entry/src/main/ets/` 整体复制成变体树，HDS 版/降级版各一份 | **零构建系统风险**；能出双产物 | 维护成本高：`Index.ets` 等每次改动都要同步两份；易漂移 | 搭建 1–2 天 + 持续同步成本 |
| **B hvigor pre-build 任务** | 构建期由 hvigor 钩子做**文件替换**（HDS → 标准组件） | 自动化；可随 CI 出双产物；单一源码 | 引入**构建系统风险**（钩子/任务链）；替换映射需维护 | 3–5 天（含回归） |
| **C 现状手工降级** | `tools/verify-on-ohemu.sh` | 零风险、已验证 | **不是产物**：只能本机验证，不能分发 | 0（已实现） |

## 4. 已排除的路线（避免重复试错）

- **`targets[].source.sourceRoots` 实现"双变体"**：**[实测]** hvigor 的 `sourceRoots` 是**追加**语义、
  **不能覆盖**同名文件（在变体根放一个故意语法错的同名 `LogStore.ets`，用 `-p module=entry@ohosvariant`
  构建**仍然成功** ⇒ 变体根未被采纳）⇒ 该方案**不可行**（AGENTS 2026-09-23 已记）。

## 5. 相关事实（供决策）

- **native 层无需改动**：已审计确认（系统头/POSIX + NAPI/hilog 均属 OpenHarmony 标准，第三方全 vendored；
  HarmonyOS 专有 native API 0 命中）——见 `devdocs/NATIVE_OPENHARMONY_COMPAT.md` **[实测]**；
- 本机**构建** OpenHarmony 目标不可行（商用 CLT 拒绝该 SDK 布局：`The SDK management mode has changed.`）
  ⇒ 属**工具链/打包**问题，与代码无关 **[实测]**；
- ohemu 上**无法点按**（镜像内无 `uinput`）⇒ 交互类验收仍需真机/人工（但 **hypium 仪器化测试可真跑**，
  见 `EMULATOR_NOTES.md §9`）**[实测]**。

## 6. 建议（[推断]，请用户裁定）

- 若目标 = **(甲)** ⇒ 维持 **C**，不投入 A/B（现状已验证可用）；
- 若目标 = **(乙)** ⇒ 建议 **B**（自动化 + 可出双产物），并把 **A** 作为 B 失败时的保守退路；
- 无论选哪条，**native 层与协议层零改动**（见 §5），工作量全部落在 ArkTS/构建层 ⇒ 属 **DevEco 车道**。

—— Omp
