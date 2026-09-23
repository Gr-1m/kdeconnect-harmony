# INCUBATION_STATUS.md — KDE 孵化进度跟踪（Atomcode 维护）

> 2026-09-22 建。负责人：Atomcode（AGENTS.md「KDE 孵化跟踪」节授权）。每次里程碑变化更新本文件并 MSG 全员。

## 当前阶段：未启动（Pre-Candidate）

## Checklist 状态（对照官方 12 项）

| # | 项 | 状态 | 备注 |
|---|---|---|---|
| 1 | Incubation Sponsor | ⬜ 未有 | 待发 kde-devel@ 邮件请求 |
| 2 | 邮件 kde-devel@ 及相关列表 | ⬜ | 日期待填 |
| 3 | 遵守 KDE Manifesto | ✅ 可承诺 | 用户已与官方沟通 |
| 4 | 治理结构类似 KDE 项目 | ⬜ | 需补治理描述（当前单主力开发者+agent 协作） |
| 5 | 清晰产品愿景 | ✅ | KDE Connect 协议的鸿蒙实现 |
| 6 | 健康团队（>1 开发者） | ⚠️ 部分 | 需社区协作补足 |
| 7 | 代码/沟通用英文 | ✅ | 代码、commit、README 均英文 |
| 8 | 域名/商标延续计划 | ⬜ | 随孵化谈 |
| 9 | 参加 Akademy/本地活动 | ⬜ | 建议 |
| 10 | 代码在 KDE Invent | ⬜ | 当前 gitcode+GitHub，待迁移 |
| 11 | 许可符合 Licensing Policy | ✅ | GPL-2.0-or-later（2026-09-19 变更，兼容上游） |
| 12 | REUSE CI lint | ⚠️ 半 | SPDX 头已全仓补齐（83 文件），缺 CI job |

## 里程碑记录

| 日期 | 事件 |
|---|---|
| 2026-09-19 | 用户与 KDE 官方社区正式沟通命名；显示名/bundleName 对齐官方（commit 8314759） |
| 2026-09-19 | 许可变更 GPL-2.0-or-later（commit 74fd271）——满足 checklist #11 |
| 2026-09-22 | 孵化跟踪职责确立（本文件建立） |

## 下一步行动（按序）

1. 注册 KDE Identity → KDE Invent 建项目（个人空间）导入代码；
2. 开 Incubation Request issue（贴 checklist + 项目背景）；
3. 英文邮件至 kde-devel@kde.org 请求担保人；
4. 补 REUSE CI job（checklist #12 收口）；
5. 治理结构描述与团队健康度（#4/#6）随社区互动补足。

—— 维护：Atomcode（glm5.3-flash）
