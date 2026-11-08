# kdeconnect-oh —— OpenHarmony/HarmonyOS 版 KDE Connect 客户端

> 目标：在 OpenHarmony / HarmonyOS（API 26 = HarmonyOS 7 起，minAPI 12）上实现 KDE Connect 协议客户端，与桌面 / Android / iOS 端互通。
> 状态：**规划与设计阶段**（本文档套件即交付物，代码未开工）。代号 kdeconnect-oh，独立项目，非 KDE 上游贡献。

## 速览结论

1. **架构**：ArkTS（UI/系统适配/持久化）+ Rust native 核心引擎（协议/TLS/发现/SFTP，rustls(ring)+russh）+ C++ 仅 NDK 独占缝隙。Rust 工具链为官方 Tier 2 目标，napi-rs 有 OHOS fork；唯一回退为 C++ 引擎（`05-language-analysis.md` §6 决策树；结论对权重假设不敏感，见 §4）。
2. **范围哲学**（参考 iOS 受限平台范本 + OH 长时任务优势）：OH 端主打「控制桌面」全能力（触控板/键盘/媒体/音量/命令/演示）+「接收桌面」核心（文件/通知显示/寻机/剪贴板/文件浏览 SFTP）；「桌面控制手机」方向被平台封死（inputEventClient 仅系统应用）。
3. **协议基线**：protocolVersion 8、UDP 1716 广播发现、TCP 1716-1764 TLS、payload 独立通道 1739-1764、SAS 配对验证码、TOFU+证书 pin——字节级规格见 `01-reference-analysis.md`。
4. **安全锚点**：配对准入（SAS 用户比对）+ 证书 pin + 全量 DoS 限额 + fuzz 门；红线清单见 `04-security.md` §8。
5. **首要行动**：G1 已判定（ArkTS TLSSocket 无法表达协议要求的 TLS 角色反转，引擎 TLS 必须走 rustls）；剩余架构级不确定只有 G2（Rust/NAPI/ring 工具链在 API 26 实测）。Phase 0 先做只需 host 环境的 S1'（rustls 双角色握手对桌面），同时准备 OH 环境跑 G2-G7。
6. **执行方法论**：骨架先行（契约冻结后才写实现）+ 注册表式扩展 + 状态唯一持有者 + 错误必须旅行到边界 + 缺陷根因四步——详见 `06 §1` 反补丁五律与 `07 §3` 骨架先行协议；这是对抗「Agent 补丁式堆码」的强制闸门。


**所有者决策记录 2026-10-12**：方案 B（Rust 引擎 + ArkTS 应用层）由所有者最终确认锁定；此前用 C++/ArkTS 做过的实现**废弃不复用**，按 clean-room 立场 greenfield 重开（许可边界见 01 §10）——动机：借重开机会全面标准化（本套件即为标准）。同日核查：G1 依官方 API 参考关闭（证据型结论，无需执行）；**G2 在本机零执行证据且前置缺失**（rustup 未安装，见 09 §3 勘误）——「G2 已验证」为误记，待环境补齐后实测。

**双代理分工路由**（09 §3 就绪卡）：ArkTS Agent 从 `00 -> 08 -> 09 -> 06 §4 + 09 §5` 进入；Rust Agent 从 `00 -> 08 -> 09 -> 01 全文 + 06 §2/§3 + 09 §6` 进入。两车道在 09 §4 的五个集成关卡汇合，`contract/` 变更只走 CCR（08 §9）。

## 文档索引（Agent 与人类的阅读顺序）

| 文件 | 内容 | 谁读 |
|---|---|---|
| `01-reference-analysis.md` | 协议线规格（字节级）+ Android/iOS/桌面实现事实 + 三端防御参数对照，全部带 file:line 引用 | 实现协议/插件前必读；引用事实优先级最高 |
| `02-architecture.md` | 平台已核实事实（P1-P10）、总体架构、NAPI 契约、引擎实现指引、插件能力矩阵、决策门 G1-G7、互操作矩阵 | 架构与功能范围裁定 |
| `03-development-plan.md` | 阶段规划（Phase 0-5）、每阶段 DoD、测试层级 L1-L4、工程结构、风险登记册、**Agent 指挥协议（任务卡模板+全局红线）** | 每个任务的发起依据 |
| `04-security.md` | 威胁模型（T1-T9）、平台安全决策、代码规范、供应链、验证要求、红线清单（NEVER） | 代码审查强制依据 |
| `05-language-analysis.md` | 语言选型收益风险模型（维度/权重/矩阵/**敏感性分析**/G1 判定/决策树/反方观点） | 技术决策存档 |
| `06-coding-standards.md` | **编码规范教学**：反补丁五律、Rust/NAPI/ArkTS 各层骨架模板与不变式、错误分级、插件 Cookbook、十二项审查清单 | 任何编码任务开工前必读对应层 |
| `07-development-walkthrough.md` | **全项目开发导引**：里程碑 M0 起、骨架先行协议、模块实现顺序、联调剧本、缺陷根因协议、上游演进与完成定义 | 任务排序与执行步骤的依据 |
| `08-interface-contract.md` | **冻结接口契约**：命令 API（d.ts 权威）、事件表、错误码表、capabilities.v1、黄金场景与 Mock 规范、CCR 变更控制 | 两车道共同实现目标；任何桥相关工作的唯一接口依据 |
| `09-two-lane-playbook.md` | **双车道执行手册**：目录所有权、两车道就绪卡、并行时间线与五个集成关卡、Rust/AkTS 任务队列与 DoD、闸门命令、追加红线 | ArkTS Agent 与 Rust Agent 各自的入口手册 |
| `10-implementation-blueprint.md` | **实现蓝图（M0 施工总图）**：engine/ 五 crate 逐文件职责、app/ 六层逐目录、contract 产物流水线（.so/types/依赖行三对接点）、运行时对接序列、追溯总表与落位序列 | M0 按图建骨架；每个任务卡从此图挑文件 |
| （已迁出）语言边界 FAQ 与从零上手指南 → `docs/manual/01`、`docs/manual/02` | **给项目所有者的人工手册**（人话版设计与上手），不属于 Agent 治理套件 | 人类读者；Agent 无需读 |

## 文档使用协议

- **任务发起**：按 `03 §9` 任务卡模板，引用必须精确到本文档章节号与上游 `file:line`；编码任务加读 `06` 对应层（03 §9 红线 9）。
- **事实冲突裁决**：`01`（源码事实）> `02`（平台核实）> 其他文档描述；发现冲突先改文档。
- **变更流程**：行为/范围/安全参数变更 -> 先改对应文档 + 风险登记册 -> 再改代码。
- **上游关系**：`kdeconnect-*-master` 与协议 schemas 仓库为只读参考；KDE 贡献政策禁止无人监督 agent 贡献，本项目不向上游推送任何内容。
- **外部事实时效**：本文平台事实核实于 2026-10（API 26 beta 期）；决策门结果可能随 HarmonyOS 7 正式版变化，探针报告为准。

## 环境注意（本机硬规则）

- DevEco Studio / SDK / 模拟器镜像等安装类操作：命令交用户执行，拿到输出再继续。
- `sudo` 一律不执行（最高优先级规则）。
- 桌面互操作依赖本机 kdeconnectd：安装命令由用户执行后回贴结果。
- 攻击性验证（fuzz/渗透用例）仅针对本机与自建对端（`tools/protocol-peer`）。
