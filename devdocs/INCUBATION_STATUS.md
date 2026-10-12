# INCUBATION_STATUS.md — KDE 孵化进度跟踪（Atomcode 维护）

> 2026-09-22 建。负责人：Atomcode（AGENTS.md「KDE 孵化跟踪」节授权）。每次里程碑变化更新本文件并 MSG 全员。

## 当前阶段：未启动（Pre-Candidate）

## Checklist 状态（对照官方 12 项）

| # | 项 | 状态 | 备注 |
|---|---|---|---|
| 1 | Incubation Sponsor | ⬜ 未有 | 待发 kde-devel@ 邮件请求 |
| 2 | 邮件 kde-devel@ 及相关列表 | ⬜ | 日期待填 |
| 3 | 遵守 KDE Manifesto | ✅ 可承诺 | 用户已与官方沟通 |
| 4 | 治理结构类似 KDE 项目 | ✅ | `GOVERNANCE.md` 已创建（106行，含决策机制/代码所有权/版本管理/沟通规范） |
| 5 | 清晰产品愿景 | ✅ | KDE Connect 协议的鸿蒙实现 |
| 6 | 健康团队（>1 开发者） | ⚠️ 部分 | 需社区协作补足 |
| 7 | 代码/沟通用英文 | ✅ | 代码、commit、README 均英文 |
| 8 | 域名/商标延续计划 | ⬜ | 随孵化谈 |
| 9 | 参加 Akademy/本地活动 | ⬜ | 建议 |
| 10 | 代码在 KDE Invent | ⬜ | 当前 gitcode+GitHub，待迁移 |
| 11 | 许可符合 Licensing Policy | ✅ | GPL-2.0-or-later（2026-09-19 变更，兼容上游） |
| 12 | REUSE CI lint | ✅ | SPDX 头已全仓补齐 + GitHub Actions 全绿 |

## 里程碑记录

| 日期 | 事件 |
|---|---|
| 2026-09-19 | 用户与 KDE 官方社区正式沟通命名；显示名/bundleName 对齐官方（commit 8314759） |
| 2026-09-19 | 许可变更 GPL-2.0-or-later（commit 74fd271）——满足 checklist #11 |
| 2026-09-22 | 孵化跟踪职责确立（本文件建立） |
| 2026-10-11 | GOVERNANCE.md 创建（#4 ✅）+ CONTRIBUTING.md 创建 + REUSE CI 全绿（#12 ✅） |
| 2026-10-11 | 0.8.0 完全交付（A1远程输入 + A2通知读取，309例测试） |
| 2026-10-11 | **G2（Rust 工具链 API 26 实测决策门）正式关闭**——ohemu 运行时 45/45（hdc 直跑）；回溯条款：0.9.0 TLS 接入异常时重开（CodeArts MSG141 TO_ALL） |
| 2026-10-11 | **A+ 密钥加密方案指派**（PEM 结构不动 + keyPem 落盘改 HUKS AES-256-GCM 加密；DevEco 实施 / Omp 验证 / AtomCode 实施后评审；0.9.0 窗口，不碰 0.8.x 在途） |
| 2026-10-11 | **测试基建 T9/T10 落地——TEST_COVERAGE_PLAN 10 项全闭环**（宿主纯逻辑通道 62 例秒级 + ohosTest 134 例）；积压三提交（64c5d1e/0ae1a25/fc13675）评审通过（flash 参考评审，devdocs/REVIEW_BACKLOG3_20261011.md） |

## 下一步行动（按序）

1. 注册 KDE Identity → KDE Invent 建项目（个人空间）导入代码；
2. 开 Incubation Request issue（贴 checklist + 项目背景）；
3. 英文邮件至 kde-devel@kde.org 请求担保人；
4. 团队健康度（#6）随社区互动补足（治理/贡献/REUSE CI 均已收口）；
5. 以上 1–3 涉及对外沟通，**发起前请用户确认**（既定纪律）。

—— 维护：Atomcode（glm5.3-flash）
