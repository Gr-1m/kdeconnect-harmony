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

## KDE Review 前置差距清单（2026-11-07 对照 `docs1105/kde-collab`）

> 依据：`01 §4 Incubation 清单` + `01 §5 KDE Review 清单` + `06 阶段2–4` + `07 Gate C/F`。
> 标注：✅ 已具备；⬜ 待办；🔁 需在 Review issue 中"解释替代"（HarmonyOS 场景不适用）。

### A. Incubator 阶段（Gate F 前）

| 项 | 状态 | 说明 / 差距 |
|---|---|---|
| Incubation Sponsor | ⬜ | 需经 kde-devel@ 找到担保人 |
| kde-devel@ 及列表邮件 | ⬜ | 待发（需用户确认） |
| KDE Manifesto 遵循 | ✅ | 已可承诺 |
| 治理类似 KDE 项目 | ✅ | `GOVERNANCE.md` |
| 清晰产品愿景 | ✅ | README/愿景已述 |
| 健康团队（>1 开发者） | ⚠️ | 需社区互动补足 |
| 英文代码/沟通 | ✅ | 已遵守 |
| 域名/商标延续（KDE e.V.） | ⬜ | 随孵化谈 |
| Akademy/本地活动 | ⬜ | 建议项 |
| 代码在 KDE Invent | ⬜ | 当前 gitcode+GitHub；需 Identity 后个人空间导入 |
| 许可符合 KDE Licensing Policy | ✅ | GPL-2.0-or-later |
| REUSE lint CI | ✅ | REUSE 3.0 + `.github/workflows/reuse.yml`（现网；Invent 侧待接） |

### B. Review 阶段（Incubation 后）

| 项 | 状态 | 说明 / 差距 |
|---|---|---|
| 完成 Incubation | ⬜ | 前置依赖 |
| Android application ID 命名规则 | ✅ | `org.kde.kdeconnect`（无连字符） |
| REUSE 3.0 声明 | ✅ | SPDX 头 + `LICENSES/` + `REUSE.toml` |
| reuse/JSON/XML/YAML lint CI | ✅ GitHub / ⬜ GitLab | `.gitlab-ci.yml`+`.kde-ci.yml` 骨架已在仓库，Invent pipeline 未接通 |
| `Messages.sh`（i18n 提取） | ⬜/🔁 | 鸿蒙资源式 i18n 无 gettext 流程，需在 Review issue 说明替代方案（或提供等效脚本） |
| `metainfo.xml`（AppStream） | 🔁 | 面向 Linux 桌面分发，鸿蒙应用不适用，需解释 |
| product-screenshots 截图 | ⬜ | 可提供（需准备正式截图） |
| clazy/clang-tidy 等健全性检查 | ⬜ | native C++（cpp/**）可纳入 clang-tidy CI；ArkTS 侧无对应工具 |
| 文档（README 构建说明） | ✅/⬜ | README 已存在；"怎么构建（hvigorw/SDK 版本）"建议补齐英文步骤 |
| bugs.kde.org 产品 | ⬜ | sysadmin ticket |
| GitLab CI build 全绿 | ⬜ | 依赖 Invent 迁移 |
| KDE neon build | 🔁 | HarmonyOS 应用无法进 neon，需解释 |
| Flatpak/Snap 等打包 | 🔁 | 不适用，需解释（或提供 HAP 分发说明） |
| repo-metadata 登记（`lifecycle`） | ⬜ | sysadmin ticket + metadata MR |

### C. 结论与建议顺序

1. **先不发起对外沟通**（既定纪律：需用户确认）；内部可先备齐：英文 README 构建说明、正式截图、clang-tidy CI 草案、REVIEW issue 的"解释替代"清单（Messages.sh/metainfo/neon/打包四项）；
2. 用户确认后：KDE Identity → Invent 个人空间导入 → CI 接通 → repo-metadata MR → Incubation Request issue → kde-devel@ 邮件找 sponsor；
3. 差距清单变化时更新本表（本轮已核对：骨架文件 `.gitattributes`/`.gitlab-ci.yml`/`.kde-ci.yml`/`REUSE.toml`/`LICENSES/`/`GOVERNANCE.md`/`CONTRIBUTING.md`/`AGENTS.md`/`README.md`/MR 模板均已在仓库）。


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
