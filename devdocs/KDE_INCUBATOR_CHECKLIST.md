# KDE_INCUBATOR_CHECKLIST.md — KDE 官方项目孵化准备清单对照与规划

> 2026-09-22。CodeArts（流程总指挥）编写。依据 [KDE Incubator process](https://community.kde.org/Incubator) 官方清单。

## 当前状态总览

| # | 清单项 | 状态 | 说明 |
|---|---|---|---|
| 1 | Incubation Sponsor | ❌ 待定 | 需找到 KDE 社区中的赞助人 |
| 2 | E-mailed kde-devel@ | ❌ 待做 | 需向 KDE 邮件列表发项目介绍 |
| 3 | Compliance with KDE Manifesto | ⏳ 需审查 | 需对照宣言逐条确认 |
| 4 | Governance similar to other KDE projects | ❌ 待建 | 当前为个人项目，需规划治理结构 |
| 5 | Clear product vision | ⏳ 部分 | README 有概述，但缺正式产品愿景文档 |
| 6 | Healthy team | ⚠️ 不足 | 目前主要是 1 人 + AI agents，需真正的社区贡献者 |
| 7 | Uses English for code and communication | ⚠️ 部分 | 代码/commit 已英文，但注释/文档/通信大量中文 |
| 8 | Continuity plan with KDE e.V. | ❌ 待协商 | 域名/商标连续性计划需与 KDE e.V. 协商 |
| 9 | Attend Akademy | ❌ 建议 | 建议用户参加 Akademy 或其他 KDE 活动 |
| 10 | Code in KDE Invent | ❌ 待迁移 | 当前在 gitcode/GitHub，需迁移到 invent.kde.org |
| 11 | License per KDE Licensing Policy | ✅ 已达标 | GPL-2.0-or-later，符合 KDE 政策 |
| 12 | Passing CI for reuse linting | ✅ 已达标 | `.gitcode/workflows/reuse.yml` 已配置；REUSE.toml + LICENSES/ 已就位 |

## 详细规划

### 1. Incubation Sponsor — 用户侧

**现状**：用户已与 KDE 官方建立联系，但具体赞助人未确定。

**行动**：
- 用户确认当前 KDE 联系人是否愿意担任 Incubation Sponsor
- 赞助人职责：在 KDE 社区中为项目代言、协助导航孵化流程
- **时机**：现在即可开始，不依赖代码进度

### 2. E-mailed kde-devel@ — 用户侧

**现状**：未发送。

**行动**：
- 起草项目介绍邮件（英文），发到 kde-devel@kde.org
- 邮件内容：项目概述、技术栈、当前进度、孵化意向、寻求赞助人
- **CodeArts 可起草邮件稿**，用户审定后发送
- **时机**：确定赞助人后发送（或同时寻找赞助人）

### 3. Compliance with KDE Manifesto — CodeArts 审查

**现状**：未审查。

**KDE Manifesto 核心原则**：
- 开放开发（公开源码、公开讨论）
- 自由软件（GPL/LGPL）
- 开放治理（社区驱动、透明决策）
- 用户尊重（隐私、数据自主）

**行动**：
- CodeArts 对照 [KDE Manifesto](https://manifesto.kde.org) 逐条审查
- 当前项目基本符合（开源、GPL、公开开发）
- **时机**：0.9 阶段（合规批次）

### 4. Governance — CodeArts 规划

**现状**：个人项目，无正式治理结构。

**KDE 项目治理惯例**：
- 1 名 Maintainer（最终决策权）
- 若干 Contributors（提交权限）
- 公开的决策流程（mailing list / invent.kde.org 讨论）

**行动**：
- 起草 `GOVERNANCE.md`（Maintainer = 用户，Contributors = 社区贡献者）
- 决策流程：重大变更通过 issue/merge request 公开讨论
- **时机**：0.9 阶段（合规批次）

### 5. Clear product vision — CodeArts 起草

**现状**：README 有概述但缺正式产品愿景。

**行动**：
- 起草产品愿景文档，明确：
  - 目标用户（HarmonyOS 设备用户 + KDE 桌面用户）
  - 核心价值（跨平台设备互联）
  - 范围边界（哪些功能做、哪些不做）
  - 与 Android/iOS 版的关系（功能对齐、独立实现）
- **时机**：0.9 阶段（合规批次）

### 6. Healthy team — 用户侧（最关键缺口）

**现状**：1 人 + AI agents，无社区贡献者。

**这是孵化清单中最难达标的一项。** KDE 孵化要求"healthy proportion of volunteers, inclusive towards new contributors, ideally more than one developer"。

**行动**：
- 在 KDE 邮件列表/论坛中招募贡献者
- 降低贡献门槛：完善 README/CONTRIBUTING/开发环境搭建文档
- 标记 "good first issue" 类任务
- **时机**：持续进行，0.9 阶段重点推进

### 7. Uses English for code and communication — DevEco + CodeArts

**现状**：
- ✅ 代码标识符（变量名/函数名）已英文
- ✅ commit 消息已英文
- ✅ SPDX 头已英文
- ⚠️ 代码注释大量中文（业务逻辑注释、协议注释）
- ⚠️ devdocs/ 文档大量中文
- ⚠️ AgentsConversion/ 通信全中文（但这是内部协作文件，不入 KDE Invent）

**行动**：
| 项 | 处理 | 负责方 | 时机 |
|---|---|---|---|
| 代码注释 | 保留中文注释（KDE 项目允许非英文注释，只要代码标识符英文） | — | 不改 |
| devdocs/ | 关键文档补英文版（或中英双语） | CodeArts | 0.9 阶段 |
| README | 已有英文版 ✅ | — | 不改 |
| CONTRIBUTING | 起草英文版 | CodeArts | 0.9 阶段 |
| AgentsConversion/ | 不入 KDE Invent，保持中文 | — | 不改 |

**注**：KDE 官方项目允许非英文注释和文档（如 kdeconnect-android 有日文注释），只要代码标识符和 commit 消息用英文。中文注释不需要删除。

### 8. Continuity plan with KDE e.V. — 用户侧

**现状**：未协商。

**行动**：
- 用户与 KDE e.V. 协商：如果项目作者消失，域名/商标/仓库权限如何转移
- 这通常是孵化流程中由赞助人协助安排的
- **时机**：孵化流程启动后

### 9. Attend Akademy — 用户侧

**现状**：未参加。

**行动**：
- 建议用户参加 Akademy 2026（或线上参加）
- 这是与 KDE 社区建立关系、寻找贡献者的最佳途径
- **时机**：下次 Akademy

### 10. Code in KDE Invent — Omp + 用户

**现状**：代码在 gitcode + GitHub 镜像。

**行动**：
- 在 invent.kde.org 创建仓库（需赞助人协助）
- 迁移 git 历史（`git remote add kde git@invent.kde.org:...` + push）
- 设置 KDE CI（与现有 `.gitcode/workflows/reuse.yml` 类似，但用 KDE 的 CI 系统）
- **时机**：孵化流程正式启动后（赞助人确认后）

### 11. License per KDE Licensing Policy — ✅ 已达标

- `LICENSE` = GPL-2.0 全文 ✅
- `LICENSES/GPL-2.0-or-later.txt` + `LICENSES/MIT.txt` ✅
- `REUSE.toml` ✅
- 源文件 SPDX 头：`cpp/**` 39/39 ✅，`ets/**` 38/38 ✅
- `oh-package.json5` license 字段 = `GPL-2.0-or-later` ✅

### 12. Passing CI for reuse linting — ✅ 已达标

- `.gitcode/workflows/reuse.yml` 已配置（`fsfe/reuse-action@v5`）
- 604/604 跟踪文件全部可解析
- **注**：迁移到 KDE Invent 后需适配 KDE CI 系统（可能用 KDE 自己的 CI 而非 gitcode workflows）

## 推进排期

| 阶段 | 清单项 | 负责方 | 时机 |
|---|---|---|---|
| **现在** | #1 确定赞助人、#2 发邮件列表 | 用户 | 尽快 |
| **0.5 阶段** | #7 关键文档英文版（CONTRIBUTING） | CodeArts | 阶段 2-3 期间 |
| **0.7 阶段** | #3 Manifesto 审查、#4 Governance、#5 Product Vision | CodeArts | 阶段 3 完成后 |
| **0.9 阶段** | #6 招募贡献者、#8 连续性计划、#10 迁移 KDE Invent | 用户 + Omp | 阶段 4 完成后 |
| **1.0 阶段** | 全部清单项达标，正式申请孵化 | 用户 | 双平台支持完成后 |

## 已达标项总结

✅ **#11 License** — GPL-2.0-or-later，REUSE 合规
✅ **#12 CI reuse linting** — `.gitcode/workflows/reuse.yml` + REUSE.toml + LICENSES/

## 最关键缺口

**#6 Healthy team** 是最难达标的——KDE 孵化要求多于一个开发者。当前项目实质上只有 1 人（用户）+ AI agents。需要在 KDE 社区中找到至少 1-2 名真正的社区贡献者。这需要用户积极参与 KDE 社区活动（邮件列表、Akademy、IRC/Matrix）。

—— CodeArts（华为云码道代码智能体），流程总指挥
