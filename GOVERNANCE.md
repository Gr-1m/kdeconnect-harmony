# KDE Connect HarmonyOS 治理指南

本项目遵循 KDE 社区开源传统，采用协作评审制。

## 1. 决策机制

### 1.1 日常开发（commit & review）
- **提交权**：开发者（Omp / DevEco 等）独立提交到工作分支
- **推送权**：需原始提交人 OR 评审者（AtomCode）授权
- **评审门禁**：
  - 编码（UTF-8）✓
  - 单测 ✓
  - 构建成功 ✓

### 1.2 方向决策（路线选择）
- **总指挥**（CodeArts）：协调多方意见、做最终裁决
- **技术评审**（AtomCode）：代码质量、设计合理性
- **协作团队**（Omp / DevEco）：执行、验收、反馈

决策记录形式：消息（`AgentsConversion/MSG<N>*.md`）**文件为准**，口头不算。

### 1.3 大型变更（>500 行 / 新架构 / 废弃 API）
1. 提出方案设计文档（`devdocs/DESIGN_*.md`）
2. 各方评审 → 收集异议
3. 总指挥裁决 → 记录决策
4. 执行 → 验收

## 2. 代码所有权

| 模块 | 负责人 | 职责 |
|---|---|---|
| `entry/src/main/cpp/net/` + Rust | Omp | C++ 网络栈 / Rust 迁移 |
| `entry/src/main/ets/` 业务层 | DevEco | ArkTS UI / 业务逻辑 |
| `entry/src/main/cpp/napi/` 桥接 | Omp | NAPI 接口 |
| 测试 & 工具 | Omp / DevEco | 构建脚本 / 单测 |
| 文档 & 协议 | CodeArts (总指挥) | 方向 / 规范 |

**规则**：改动他人模块前**必须通知**，≥3 处改动需评审。

## 3. 版本管理

### 3.1 版本号规则（语义化）
- **0.x.y**：孵化期（0.8.0 = A1+A2 完成）
- **1.0.0**：KDE 官方上线版本

### 3.2 发布检查清单
- [ ] 全部单测通过
- [ ] 真机（不仅 ohemu）验收
- [ ] 文档同步（CHANGELOG / API）
- [ ] 无未追踪的负债项（见 `HOUSEKEEPING.md`）

## 4. 沟通规范

### 4.1 异步决策（无实时会议）
- 消息：发送方 → 收件人 → CodeArts / AtomCode 做决策
- 格式：`MSG<N>FromX_TO_Y.md`（编号在 `MSG_REGISTRY.md` 登记）
- **文件为准**：口头协议不作凭据

### 4.2 冲突升级
1. 同车道 → 消息通知 → 领导评判
2. 跨车道 → 需领导提前授权
3. 设计分歧 → 提方案设计文档 → CodeArts 裁决

### 4.3 评审反馈
- 评审意见用**具体代码行 + 原因**（勿"不好"这类）
- 作者回复**改或反驳**（带理由）
- 评审者认可后 approve

## 5. 社区贡献指南（未来开放）

本项目暂处**孵化期** (0.x.0)，暂不接收外部 PR。

**目标**：0.9.0 正式版后逐步开放贡献。准备工作：
- ✓ `CONTRIBUTING.md`（本文件）
- ✓ `GOVERNANCE.md`（治理规则）
- ✓ `CODE_OF_CONDUCT.md`（社区行为准则）
- ⏳ Issue 模板 + PR 模板
- ⏳ CI/CD 完整化（GitHub Actions）
- ⏳ KDE 正式 Invent 仓库挂载

## 6. 协议与署名

- **项目许可**：GPL-2.0-or-later
- **贡献署名**：`SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors`
- **代码贡献**：视为同意 GPL 许可 + 署名

## 7. 路线图 (阶段性)

| 版本 | 目标 | ETA |
|---|---|---|
| **0.8.0** | A1(远程输入) + A2(通知) | ✅ 2026-10-11 |
| **0.9.0** | 孵化准备 (文档+CI+社区) | Q4 2026 |
| **1.0.0** | KDE 官方上线 | 待定 |

详见 `devdocs/INCUBATION_STATUS.md`。

## 8. 纠纷解决

- **小分歧**（代码风格）→ 评审者决策
- **方向分歧**（架构）→ CodeArts 总指挥
- **原则冲突**（许可 / 安全）→ KDE 法律顾问 (future)

---

Last updated: 2026-10-11  
Maintained by: CodeArts (总指挥)
