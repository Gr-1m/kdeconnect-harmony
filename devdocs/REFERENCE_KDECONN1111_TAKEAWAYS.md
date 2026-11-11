# kdeconn1111 参考库借鉴清单（2026-11-11 收，AtomCode 整理）

> 来源：`kdeconn1111/`（577M，2026-11-11 22:55 到货；含四棵上游快照 + `docs/` 四套 + `docs1111/` 当前进度 + `docs/kde-collab/` KDE 官方协作套件 + `docs1105/` RAG 语料）。
> 定位：与 `devdocs/REFERENCE_KDECONN1109_TAKEAWAYS.md` 互补——1109 侧重实现细节，1111 侧重**协作/合规/风险登记方法学**。
> 只读参考，不进仓库索引（目录已在 `.git/info/exclude` 之外的本地参考区）。

## 1. 最重要：KDE 上游 AI 政策红线（直接影响 0.9.0 孵化）

`kde-collab/05-AI政策红线.md`（原文引自 `kdeconnect-kde/AGENTS.md` + `CONTRIBUTING.md`）：

| 红线 | 内容 |
|---|---|
| MR 描述/评审回复 | **人类独占**，AI 代写 → MR 立即关闭 |
| `git push` / 建 MR | **人类独占**；agent 代推可能导致**贡献者封禁** |
| commit trailer | 人类批准后 agent 代提交须用 **`Assisted-by:`**，**不得用 `Co-authored-by:`** |
| 披露 | MR 模板 `Used AI: Yes/No` 必填 |
| 完全自主 agent | 上游明示「无人类监督的 agent（点名 OpenClaw 类）不要向本项目贡献」 |

**对我们的操作含义**（0.9.0 前必须落到纪律）：
1. 我们仓库内部的 `Co-Authored-By: AtomCode …` trailer **只用于自有仓库**；一旦向 KDE 上游（invent.kde.org）提 MR，必须改为 `Assisted-by:`，且 MR 描述/评审回复由你（人类）撰写；
2. 孵化 Incubation issue / 邮件：内容可代拟，**发送动作由你执行**，并在其中如实披露 AI 参与范围；
3. 「谁长期维护这份代码」是上游 Review 的现实门槛——孵化材料里应明确维护人（你）。

## 2. REUSE 3.0 与 OHOS 许可证风险

- 硬要求：每文件 SPDX 头 **或** `REUSE.toml` `[[annotations]]` 覆盖；`LICENSES/` 放实际用到的全文；CI `reuse lint` 必须绿；
- 本地自检：`docker run --rm -v "$PWD":/data fsfe/reuse:5 lint`；
- **OHOS 专有 SDK 与 GPL 系的分发/链接边界未评估**——参考库明确建议在 Incubation issue 里显式写明，请 sponsor 协助找 KDE 法务意见。我们已有 `LICENSES/` + reuse CI（`8a95f96`/`b3664b7`），但**没有 `REUSE.toml`**、也没评估 SDK 链接风险 → 两件 backlog。

## 3. MR/提交规范（对上游客服用）

- 一个 commit 一个逻辑变更；Bugzilla 关键字 `BUG:` / `CCBUG:`；新增公开 API 写 `\since`；**提交与代码 ASCII only**（`->` 不写 `→`）；提交信息英文；
- MR 模板 = Summary + 关联 + **Test Plan（Before/After）** + `Used AI`；Test Plan 是最常被打回的点；
- 我们内部提交目前中文正文（自有仓库 OK），将来对上游要换成英文/ASCII。

## 4. 参考实现状态对照（kdeconn-1108，2026-11-11 快照）

- 有而我们没有：**只读 SFTP**（multi-root、写拒绝、sshfs）、MPRIS 完整控制、系统音量、远程命令、触控板/演示器、通知 actions/reply、剪贴板接收、电池/网络上报；
- 我们有而他们弱：**全 Rust 网络栈**（TLS/证书自生成）、S2 文件分享（批次/待处置/自动保存）、HDS UI 与 V2 试点；
- 他们仍缺：真机 8h 后台、1GB 传输、通知权限全路径、ArkTS 多选 UI、SFTP/cert fuzz → 与我们的发布门清单高度重合。

## 5. 可直接对照的风险（他们的 R 表 → 我们的现状）

| 参考风险 | 我们现状 |
|---|---|
| R4 失败/取消留 partial file | **已处理**：`payload.rs::finish()` 失败/取消路径 `remove_file(spool)` ✅ |
| R6 批量发送无 per-device 队列 | **已有**：发送单写者队列 ✅ |
| R5 ArkTS 事件重排（async 不 await） | 需确认：`PacketRouter`/插件回调是否严格串行（我们插件回调逐个隔离异常） |
| R7 NAPI 单例不可重启 | 同：`Index.d.ts` 契约是全局单例，无 restart |
| R8 `defaultEnabled` 未执行 | **同缺口**：`contract/capabilities.v1.json` 有字段，但 Rust/ArkTS 无消费（grep 无命中）→ backlog |
| R19 payload 端口无临时回退 | 同：我们仅 `1739..=TCP_PORT_MAX` 顺序试，无 ephemeral 回退 → backlog |
| R20 身份持久化失败路径 | 我们已有 backlog：IdentityStore 私钥入 Asset Store（0.8.x 安全补丁） |
| R1 双配对状态机 | **无**：我们 C++ 已删，只有一套 Rust 实现 ✅ |

## 6. 方法学可借鉴（低成本、高收益）

1. **证据分级**：已验证 / 历史验证 / 代码事实 / 推断 / 计划 —— 我们 devdocs 目前只有「已验/未验」两档，可升级；
2. **风险登记表**：ID + 严重度（S1–S4）+ 状态（Open/Decision needed/Mitigated/Verify）+ 证据列 —— 建议我们把 backlog（S6 SFTP、canDispose、defaultEnabled、端口回退）按此登记；
3. **任务卡模板**（目标/边界/契约/不变式/步骤/验收/风险回滚）—— 可直接用于我们下次派单；
4. **「完成」四级定义**：代码完成 → 单元完成 → host 完成 → 设备完成 → 发布完成；只有同时满足才写 ✅；
5. **Go 协议对端**：`docs/kdetestpeer-golang/` 是可运行的 v8 L2 测试 oracle（含 SAS KAT、1MB 哈希一致），比我们靠模拟器快照取证更硬 —— 可考虑纳入 `tools/` 作为回归对端。

## 7. 建议动作（按优先级）

| # | 动作 | 归属 |
|---|---|---|
| 1 | 0.9.0 前把「AI 政策红线」写进仓库 AGENTS（对外动作人类独占、`Assisted-by`） | 总指挥（文档） |
| 2 | 补 `REUSE.toml` + 评估 OHOS SDK 与 GPL 兼容性（Incubation issue 显式写明） | 总指挥 + 用户法务确认 |
| 3 | `defaultEnabled` 语义定案（UI 默认开关 vs 能力广告过滤）并入 backlog | Omp-ArkTS/Omp-Native |
| 4 | payload 端口失败时 ephemeral 回退（可选） | Omp-Native |
| 5 | 评审 devdocs 证据分级 + 风险登记表格式 | 总指挥 |
| 6 | 评估把 `kdetestpeer-golang` 纳入 `tools/` 作回归对端 | 总指挥 + Omp-Native |
