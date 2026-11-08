# KDE 孵化入口材料包（0.9.0 里程碑 · 草稿，未对外发送）

> 2026-11-08 起草。**对外动作（Identity 注册 / Invent 建仓 / issue / 邮件）一律待用户逐项确认后执行**。
> 事实源：`devdocs/INCUBATION_STATUS.md`、`GOVERNANCE.md`、`docs/kdeconnect-oh/`。

## 0. 前置状态一览（对照官方 12 项 checklist）

| # | 项 | 状态 |
|---|---|---|
| 1 | Incubation Sponsor | ⬜ 待 kde-devel 邮件寻找 |
| 2 | kde-devel@ 邮件 | ⬜ 本文 §4 草稿 |
| 3 | 遵守 KDE Manifesto | ✅ 可承诺 |
| 4 | 治理结构 | ✅ `GOVERNANCE.md` |
| 5 | 产品愿景 | ✅ README |
| 6 | 健康团队（>1 开发者） | ⚠️ 社区互动补足（可先说明多人+多 agent 协作事实与贡献路径） |
| 7 | 代码/沟通英文 | ✅ |
| 8 | 域名/商标 | ⬜ 随孵化谈 |
| 9 | Akademy/本地活动 | ⬜ 建议项 |
| 10 | 代码在 KDE Invent | ⬜ 需 Identity 后导入（§2） |
| 11 | 许可 | ✅ GPL-2.0-or-later |
| 12 | REUSE CI lint | ✅ GitHub Actions 已绿（run 223）；Invent pipeline 待接（`.gitlab-ci.yml`/`.kde-ci.yml` 已备） |

## 1. 执行顺序（建议）

```
0.8.4（Rust 合并）发布
   → ① 注册 KDE Identity（用户）
   → ② Invent 个人空间建项目并从 GitHub 镜像导入（用户；我提供导入后检查清单）
   → ③ 开 Incubation Request issue（用户提交；正文用 §3）
   → ④ kde-devel@ 邮件请求担保人（用户发送；正文用 §4）
   → ⑤ 担保人出现后：补 sponsor、随流程 Review
```

## 2. Invent 建仓检查清单（导入后由我核对）

- [ ] 项目可见性 public；描述/许可证（GPL-2.0-or-later）填好
- [ ] CI 生效：`.gitlab-ci.yml` include KDE 模板 + `.kde-ci.yml`（REUSE/commit checks）
- [ ] 镜像方向：Invent 为主仓后，gitcode/GitHub 降为镜像（或保留双推，需在 issue 中说明）
- [ ] `devdocs/REVIEW_*`、`AgentsConversion/` 等本地文件不随导入（已在 .gitignore）
- [ ] README 补英文构建步骤（hvigorw/DevEco/SDK 26）

## 3. Incubation Request issue 正文草稿（英文）

> 提交位置：KDE Incubator 的 issue 仓库（以 incubator 团队当期模板为准；以下按通用字段组织）

**Title**: Incubation request: KDE Connect for HarmonyOS

**Body**:

```markdown
### Project name
KDE Connect for HarmonyOS (working title; bundle id org.kde.kdeconnect)

### Summary
A HarmonyOS (API 26, Stage model) client implementing the KDE Connect protocol,
interoperable with KDE Connect desktop and Android peers (protocol v8, TLS 1.3/1.2).

### Repository
- Primary: <to be created on KDE Invent after Identity>
- Mirrors: https://github.com/Gr-1m/kdeconnect-harmony , https://gitcode.com/Gr1m/kdeconnect-harmony

### License
GPL-2.0-or-later (REUSE 3.0 compliant, CI green: reuse lint + native tests).

### Why incubation
We want the port to live in KDE infrastructure, follow KDE governance and
release cadence, and eventually be maintained by the KDE community. The project
is a platform port of an existing KDE product, not a fork of protocol logic.

### Maintainers / team
Maintained by <maintainer names/handles to be filled by owner>. Contributions are
coordinated through public issues/MRs; governance follows GOVERNANCE.md in-repo.

### Technical notes
- Native network stack in Rust (ohos-rs + rustls), ArkTS UI (official HarmonyOS APIs).
- Protocol facts derive from kdeconnect-meta schemas; packet types follow upstream.
- Platform-specific substitutions (to be explained in Review):
  * Messages.sh/i18n: HarmonyOS resource-based i18n instead of gettext extraction.
  * metainfo.xml/AppStream: not applicable to HarmonyOS distribution.
  * clang-tidy/clazy: ArkTS has no equivalent; Rust side covered by clippy.

### Self-assessment against incubation checklist
1 Sponsor: seeking via kde-devel.
2 Mailing list: this request.
3 Manifesto: agreed.
4 Governance: GOVERNANCE.md.
5 Vision: README.
6 Team health: <describe contributors / contribution path>.
7 English: yes.
8 Domain/trademark: follow KDE e.V. guidance.
9 Akademy/local events: planned after incubation.
10 Code on Invent: will import after Identity.
11 Licensing: GPL-2.0-or-later.
12 REUSE CI: green on GitHub; Invent pipeline prepared.
```

## 4. kde-devel@ 邮件草稿（英文）

**Subject**: Seeking an incubation sponsor: KDE Connect for HarmonyOS

```text
Hi all,

We are developing a HarmonyOS client for the KDE Connect protocol
(API 26 / Stage model, protocol v8, TLS 1.3/1.2, Rust native core + ArkTS UI),
interoperable with both KDE Connect desktop and Android peers.

The project is GPL-2.0-or-later, REUSE-compliant (CI green), and has a
governance/decision document plus a public issue/MR workflow. We would like to
apply for incubation and are looking for a sponsor from the KDE community.

Repository (mirror until import to Invent):
https://github.com/Gr-1m/kdeconnect-harmony

An incubation request draft is ready; we would appreciate guidance on the
platform-specific substitutions (HarmonyOS resource-based i18n instead of
Messages.sh, no AppStream metainfo for HAP distribution) and on how to best
structure the Incubation Request issue.

Thanks,
<name/handle>
```

## 5. 需要在 issue/邮件中主动说明的替代项（避免 Review 追问）

| 项 | 建议表述 |
|---|---|
| `Messages.sh` | HarmonyOS 使用资源文件 + `string.json` 本地化；无 gettext 提取流程，可提供等效校验脚本 |
| `metainfo.xml` | HAP 分发不经 AppStream；以 README + 截图 + 官网/商店页替代 |
| `product-screenshots` | 已可提供（手机/平板/折叠三端） |
| 团队健康度 | 列出公开贡献路径（issue/MR/文档），说明多人+多 agent 协作事实 |
| CI 差异 | GitLab 侧 REUSE/commit checks 已备（`.gitlab-ci.yml`/`.kde-ci.yml`），导入后启用 |

## 6. 边界

- 本文件为**内部草稿**；任何外发（issue/邮件/Identity/Invent）前须用户确认；
- 邮箱/姓名等个人信息由用户填写，不写入仓库；
- 0.9.0 发布口径 = 孵化入口里程碑（版本号不承载功能变更）。
