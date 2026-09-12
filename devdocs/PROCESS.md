# PROCESS.md — KDE-H Connect 工作流规范

> CodeArts（流程总指挥）起草，2026-09-12。
> 适用于新仓库 `<workspace>/kdeconnect-harmony`（gitcode 中心仓库 clone，分支 `dev/zcodeinit`）。
> 所有 agent 遵守本文；变更由 CodeArts 发起，异议走 `AgentsConversion/` 消息。

---

## 1. Commit / Push 策略

### 1.1 当前约束（用户 2026-09-12 决定）

- **gitcode 远端暂不同步**：不 `remote add`、不 push（远端保持 Initial commit 空壳状态）
- **未经用户明确要求不 push**
- 本地 commit 允许，但需经 CodeArts 确认时机和粒度

### 1.2 Commit 时机规则

| 条件 | CodeArts 动作 |
|---|---|
| WP 交付完成 + 构建通过 + 评审通过 | 发 commit 指令给负责 agent |
| 未经评审的代码 | **不发** commit 指令 |
| 用户明确要求 commit | 立即执行用户指令，不走评审流程 |
| 跨层改动（d.ts + C++ + ArkTS） | 三层都就绪后统一 commit，不拆分 |
| 单层改动（仅 C++ 或仅 ArkTS） | 该层就绪即可 commit |

### 1.3 Commit 粒度规则

- **一个 commit = 一个逻辑单元**：一个 WP 子任务、一个 bugfix、一个评审整改
- **不混装**：不把多个无关改动塞进一个 commit
- **commit message 格式**：`[WP-N] <简述>` 或 `[fix] <简述>` 或 `[review] <简述>`
- **示例**：`[WP-0] baseline: C++ native stack migrated from PreDev` / `[WP-1] payload: add payloadReceived event to d.ts v2`

### 1.4 首个 Commit 切分建议

当前仓库尚无任何本地 commit（仅远端 Initial commit）。建议首个 commit 切分：

| 序号 | 内容 | 负责 | 条件 |
|---|---|---|---|
| C1 | 工程骨架 + ArkTS 基线 + C++ native 基线（全量，构建通过） | DevEco Code + ZCode | DevEco 骨架落地 + `hvigorw assembleHap` 通过 + 模拟器冒烟通过 + **.gitignore 修复** + `git add -A` 复核无机器本地文件 |
| C2 | `.gitcode/workflows/` CI 流水线初版 | CodeArts 出规格 + 代码 owner 落地 | C1 之后 |
| C3+ | 按 WP 进度逐个 commit | 各 WP owner | 评审通过后 |

**C1 是关键里程碑**——标志着新仓库从空壳变为可构建可运行的工程。C1 之前不 commit 任何零散改动。

**C1 硬前置条件**（全部满足才发 commit 指令）：
1. `hvigorw assembleHap` 构建通过 ✅（DevEco Code Win10 首验已确认）
2. 模拟器冒烟通过 ✅（DevEco Code 首验②已确认）
3. lint 通过 ✅（DevEco Code 首验③已确认）
4. `.gitignore` 修复完成（`.cache/`、`.codeartsdoer/`、`.appanalyzer/`、`wecode-cpp.db`、`devdocs/reference/` 追加）⏳
5. `git add -A --dry-run` 复核无机器本地文件 ⏳
6. `build-profile.json5` 签名配置不阻塞 Linux 侧构建 ⏳
7. AtomCode 流程文档交叉核对完成 ⏳

### 1.5 Push 规则

- **当前不 push**（用户 2026-09-12 决定）
- 将来 push 需满足：用户明确要求 + 远端已配置 + 本地 commit 已评审
- Push 前检查：`git log --oneline` 确认 commit 历史、`git status` 确认无未提交改动

### 1.6 签名策略（2026-09-12 CodeArts 裁决）

**方案 A**：tracked `build-profile.json5` 的 `signingConfigs` 恒为 `[]`。

- Linux 侧签名走 `tools/sign-debug.sh`（不依赖 build-profile signingConfigs）
- Win10 侧 DevEco 自动签名本地注入，**不写回 tracked 文件**
- DevEco Code 负责：关闭自动签名写回或每次构建后还原 signingConfigs 为 `[]`

---

## 2. 通信文档管理

### 2.1 文件分类

| 类别 | 文件 | 处理规则 |
|---|---|---|
| **永久保留** | `AGENTS.md`、`USER_SAY.md`、各 agent 名片（`CODEARTS.md`/`ZCODE.md`/`ATOMCODE.md`） | 只更新不删除 |
| **活跃消息** | 含未完成任务、待确认事项、最新指令的 MSG | 保留 |
| **已完成消息** | 内容已被对方接收并执行完毕，且无后续依赖 | 标记 `ARCHIVED_` 前缀，下一轮确认后删除 |
| **被取代消息** | 内容已被 newer MSG 完全覆盖 | 标记 `ARCHIVED_` 前缀，下一轮确认后删除 |
| **技术笔记** | `CODEARTS_NOTES.md` 等 | 保留（历史参考价值） |

### 2.2 清理流程

1. CodeArts 扫描 `AgentsConversion/`，标记可归档文件（加 `ARCHIVED_` 前缀）
2. 在 `HOUSEKEEPING.md` 列出归档清单及理由
3. 留一轮确认期（下一个 agent 会话周期）
4. 确认无异议后删除归档文件

### 2.3 Syncthing 冲突处理

- `*sync-conflict*` 文件**由用户裁决后删除**，agent 不得自行合并或删除
- 两端同时新建同名 MSG 文件会产生 `*.sync-conflict-*`——编号占用表（见 `HOUSEKEEPING.md`）可预防
- `.stignore` 只本机生效、不同步——两端必须各配一份且内容一致

### 2.4 编号规则

- 格式：`MSG<全局递增编号>_TO_<TARGET>.md`
- 编号全局递增，不按收件人独立计数
- 广播消息用 `MSG<编号>_TO_ALL_AGENTS.md`
- 编号占用表见 `HOUSEKEEPING.md`

### 2.3 首轮清理评估（见 §3）

---

## 3. 首轮消息清理评估

### 3.1 可归档的 MSG（内容已完成/被取代）

| 文件 | 理由 |
|---|---|
| `MSG_TO_ATOMCODE.md` | atomcode 角色已移交 ZCode；内容为初始分工确认，已被 CPP_GUIDE 取代 |
| `MSG_TO_CODEARTS.md` | 同上，atomcode 初始同步，已被后续 MSG 取代 |
| `MSG2_TO_ATOMCODE.md` | 早期分工协调，已完成 |
| `MSG2_TO_CODEARTS.md` | 早期 NAPI 接口定义，已落地实现 |
| `MSG3_TO_ATOMCODE.md` | bug 修复指令，MSG13 确认已修复 |
| `MSG3_TO_CODEARTS.md` | 同上 |
| `MSG4_TO_ATOMCODE.md` | 早期协调，已完成 |
| `MSG4_TO_CODEARTS.md` | 同上 |
| `MSG5_TO_CODEARTS.md` | 早期实现细节讨论，已落地 |
| `MSG5b_TO_CODEARTS.md` | 同上 |
| `MSG6_TO_CODEARTS.md` | 同上 |
| `MSG7_TO_ATOMCODE.md` | 同上 |
| `MSG8_TO_ATOMCODE.md` | 同上 |
| `MSG8_TO_CODEARTS.md` | 同上 |
| `MSG9_TO_ATOMCODE.md` | 同上 |
| `MSG9_TO_CODEARTS.md` | 同上 |
| `MSG10_TO_CODEARTS.md` | 同上 |
| `MSG11_TO_ATOMCODE.md` | bug 修复指令，MSG13 确认已修复 |
| `MSG12_TO_ATOMCODE.md` | 同上 |
| `MSG13_TO_CODEARTS.md` | 端到端验证通过确认，历史记录价值但内容已完成 |
| `MSG14_TO_ATOMCODE.md` | 早期协调，已完成 |

### 3.2 保留的 MSG（含活跃信息或最新指令）

| 文件 | 理由 |
|---|---|
| `MSG15_TO_CODEARTS.md` | 工作区位置变更通知，含未提交改动纪律，仍有参考价值 |
| `MSG16_TO_CODEARTS.md` | ZCode 角色交接 + 新仓库分工，当前活跃 |
| `MSG17_TO_DEVECO.md` | DevEco Code 骨架规格书，当前活跃（DevEco Code 尚未完成骨架） |
| `MSG18_TO_CODEARTS.md` | 目录迁移 + 任务确认，当前活跃 |
| `MSG19_TO_CODEARTS.md` | 总指挥职责移交，当前活跃 |
| `MSG20_TO_DEVECO.md` | 总指挥再分工通知，当前活跃 |

### 3.3 名片处理

| 文件 | 处理 |
|---|---|
| `ATOMCODE.md` | **保留**（历史参考：atomcode 的实现细节、协议参数核对结论仍有价值）；但标注"角色已移交 ZCode" |
| `CODEARTS.md` | **已更新**（反映当前角色和状态） |
| `ZCODE.md` | **保留**（当前 native agent 名片） |
| `CODEARTS_NOTES.md` | **保留**（native 网络栈实现细节，技术参考价值高） |

### 3.4 执行计划

1. 本轮先在 `HOUSEKEEPING.md` 列出归档清单（本文 §3.1）
2. 等 ZCode 和 DevEco Code 下次会话确认
3. 确认后统一加 `ARCHIVED_` 前缀，再下一轮删除

---

## 4. 单测指导

### 4.1 测试分层

| 层 | 范围 | 执行环境 | 负责 |
|---|---|---|---|
| **proto/ host 单测** | 帧切分、identity 编解码、验证码算法、常量回归 | Linux host（g++/clang，不依赖 NDK） | ZCode 编写，CodeArts 指导+评审 |
| **net/ 集成单测** | UDP/TCP/TLS 连接流程（mock 或 loopback） | Linux host 或 NDK | ZCode 编写 |
| **ArkTS 单测** | PacketRouter、插件注册表、UI 逻辑 | DevEco/ohost | DevEco Code 编写，CodeArts 指导+评审 |
| **CI 单测** | `.gitcode/workflows/` 自动执行 proto/ host 单测 | GitCode CI | CodeArts 出规格 |

### 4.2 proto/ host 单测覆盖清单（M1 优先）

| 测试用例 | 覆盖目标 | 优先级 |
|---|---|---|
| **帧切分：完整单包** | 一行 JSON + `\n` → 正确解析 | P0 |
| **帧切分：半包累积** | 分两次 recv 收到同一包 → 等到 `\n` 才解析 | P0 |
| **帧切分：多包合并** | 一次 recv 收到多个包 → 逐个解析 | P0 |
| **帧切分：非法 JSON** | 丢弃该行，继续解析后续包 | P0 |
| **帧切分：空行** | 跳过，不报错 | P1 |
| **identity 编码** | deviceId/deviceName/deviceType/tcpPort → JSON 字段正确 | P0 |
| **identity 解码** | JSON → 各字段正确提取 | P0 |
| **identity 缺字段** | 缺 tcpPort 等可选字段 → 不崩溃，默认值合理 | P1 |
| **identity 自过滤** | 自己的 deviceId → 忽略 | P0 |
| **验证码算法** | 双方公钥 DER 排序拼接 + SHA256 前 8 位 hex 大写 | P0 |
| **验证码 v8** | 追加配对 timestamp | P0 |
| **常量回归** | protocolVersion=8、端口 1716、包大小限制等 | P1 |

### 4.3 测试风格要求

- **C++ 侧**：仿 Go 标准库 table-driven 风格——每个测试用例一行输入+期望输出，循环驱动
- **ArkTS 侧**：用 HarmonyOS 测试框架（`@ohos/hypium`），table-driven 风格
- **命名**：`Test<函数名>_<场景>`，如 `TestParseFrame_HalfPacket`、`TestVerifyCode_V8`
- **断言**：C++ 侧用简单 assert 宏（自写或单头框架），不引 Google Test 等重依赖

### 4.4 测试框架选型建议（proto/ host 单测）

| 选项 | 优点 | 缺点 | 推荐 |
|---|---|---|---|
| **自写最小断言** | 零依赖，完全可控 | 需自己写 runner | 备选 |
| **doctest（单头）** | 一个 .h 文件，轻量，table-driven 支持好 | 需 vendor 一个 .h | **推荐** |
| **Google Test** | 功能全面 | 重依赖，编译慢 | 不推荐 |

**推荐 doctest**：vendor `doctest.h` 到 `cpp/test/`，host 编译时 `#include "doctest.h"`，NDK 编译时不包含测试代码（CMake 条件分支）。

---

## 5. CI 流水线规格（初版）

### 5.1 目标

- GitCode `.gitcode/workflows/` 用 GitHub-Actions 风格
- checkout 后代码位于 `repo_workspace/` 子目录
- **第一优先级**：Linux host 单测 job（proto/ 编译+运行）
- **第二优先级**：构建检查 job（`hvigorw assembleHap`，需 SDK 环境）

### 5.2 Job 设计

| Job | 触发 | 内容 | 环境 |
|---|---|---|---|
| `host-unit-test` | push/PR | `cd repo_workspace && cmake proto/ && make test` | Linux + g++ |
| `build-check` | push/PR | `cd repo_workspace && hvigorw assembleHap` | Linux + OHOS SDK |
| `lint-check` | push/PR | ArkTS lint（待 DevEco 验证后启用） | Linux + codelinter |

### 5.3 实现节奏

1. 先出 `.gitcode/workflows/host-test.yml` 规格文档（CodeArts）
2. ZCode 落地 yml + proto/ CMakeLists 测试目标
3. 验证 CI 绿后逐步加 build-check job

---

## 6. 分支策略（初版）

- 当前：单分支 `dev/zcodeinit`，所有改动直接在此分支
- MVP 期间（M1-M2）：维持单分支，不引入 feature branch
- M3+：考虑 `main` + `dev` + feature branch 模式
- 远端同步后：`main` = 稳定可发布，`dev` = 开发主线

---

## 7. 验收流程

每个 WP 交付时：

1. **代码 owner 自测**：构建通过 + 功能验证
2. **AtomCode 评审**：先过 `REVIEW_ATOMCODE.md` 对应章节的 P0 项（WP-1 尤其关键：§3 的三条 blocker 直接决定 M1 锚点成败）
3. **CodeArts 评审**：d.ts 契约一致性 + 协议常量 + 代码风格 + 流程合规
4. **CodeArts 发 commit 指令**（评审通过后）
5. **里程碑 WP**：用户确认后才能进入下一个 WP

---

## 维护

本文由 CodeArts 维护。工作流规则变化时同改动更新本文并通知各 agent。
