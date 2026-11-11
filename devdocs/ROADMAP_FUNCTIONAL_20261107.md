# 功能性开发规划（2026-11-07，下一阶段）

> 状态：规划稿，待用户确认优先级。基线 = 0.8.3（main `351c923`）。
> 依据：已实现插件盘点、`kdeconnect-meta/schemas` 全集对照、`docs1105` 平台能力边界、`INCUBATION_STATUS` 与 0.9.0 窗口登记。

## 1. 现状基线（已实现，13 类 packet）

identity/pair、ping、findmyphone、battery(+request)、connectivity_report、clipboard(+connect)、
mpris(+request)、mousepad(+request/keyboardstate)、remote input 按键、notification(基础读取)、
share.request（收发 payload + 自动保存/另存/丢弃）、runcommand(+request/output)、systemvolume(+request)。

## 2. 协议缺口（对照上游 schema）

| 缺口 | 价值 | 平台可行性 | 归属 |
|---|---|---|---|
| `notification.reply` / `notification.action` | 桌面回消息/关闭通知 | ⚠️ 鸿蒙无 RemoteInput 等价能力，回复注入倾向受限；dismiss 仅能取消自己发布的通知 ⇒ **需可行性验证** | ArkTS |
| `share.request.update` | 传输进度对端同步 | ✅ 可行（补充字段） | Native/ArkTS |
| `sftp.request` | 桌面挂载手机目录（当前桌面报 "Failed to mount filesystem"） | ✅ 可行但**工作量大**：需实现 SSH/SFTP server（russh 线备料，见 chunk 23） | Native |
| `notification` action 映射增强 | 通知操作按钮转发 | ⚠️ 同 reply 受限 | ArkTS |
| `digitizer(.session)` | 绝对坐标触控板 | ✅ 可行 | ArkTS/Native |
| `presenter` | 遥控演示翻页 | ✅ 可行（纯 packet，工作量小） | ArkTS |
| `mousepad.echo` | 光标回传 | ✅ 小改动 | Native |
| `lock` / `lock.request` | 远程锁屏 | ❌ 需系统权限/MDM | — |
| `contacts.*`（4） | 联系人同步 | ⚠️ `@ohos.contact` 权限等级待验证（可能需 ACL） | ArkTS+Native |
| `sms.*`（6） | 短信同步/发送 | ❌ `@ohos.telephony.sms` 为系统 API | — |
| `telephony`(+mute) | 来电/静音 | ❌ 受系统权限限制 | — |

## 3. 已实现功能的收尾项（同属功能开发）

- **文件分享闭环**：多文件队列、失败重试、接收开关/自动保存开关真正生效（当前「即将支持」）、进度 UI；
- **剪贴板增强**：图片/大文本、自动同步开关；
- **MPRIS 完善**：专辑封面、更多控制（seek/volume）；
- **通知**：已读/清除的本地体验，桌面侧展示分组。

## 4. 建议排期（按依赖与价值）

| 阶段 | 内容 | 价值 | 工作量 | 依赖 |
|---|---|---|---|---|
| **S1（收尾，立即）** | 证书 `notBefore` 修复（now−1y，见 PROTOCOL_AUDIT §1）；在途标题栏穿透/GENTLE 提交；RAG 语料更新（chunk 09/24 + 新增 25/26） | 正确性 | S | 用户确认 |
| **S2（功能）** | 文件分享闭环（多文件/失败重试/开关生效/进度）+ `share.request.update` | 高 | M | 无 |
| **S3（功能）** | 剪贴板增强 + MPRIS 完善 + presenter（快赢） | 中 | M | 无 |
| **S4（可行性验证）** | 通知 reply/action 与 contacts 权限实测；结论落文档（能做则排期，不能做标注解释项） | 决策 | S | 真机/权限 |
| **S5（底层门禁，与功能并行）** | TLS 1.3（rustls）+ napi-rs 接入 + A+ HUKS 加密（0.9.0 窗口登记项） | 互操作/安全 | L | G2 已闭环 |
| **S6（大件）** | SFTP 文件浏览（桌面挂载手机目录） | 高 | L | S5 的 Rust 线就绪 |
| **S7（UI 结构）** | HdsNavigation 直接内容原型（**暂停中**，待用户定胶囊路线） | 观感 | L | 用户裁决 |

## 5. 验收口径（S2/S3 为例）

- 文件分享：双向发送/接收各 ≥3 文件（含大文件），失败有错误码提示，开关状态跨重启持久化；
- 剪贴板：文本/图片双向同步延迟 <2s，自动同步开关生效；
- MPRIS：播放/暂停/上一首/下一首/音量全通，封面正常显示；
- presenter：桌面侧翻页与手机按钮一一对应；
- 每批：`hvigorw assembleHap` + native tests + 三实例冒烟（文本取证）+ 独立提交。

## 6. 已确认排期（2026-11-07 用户批准）

> 只对 S1、S2、S4 排期；S3/S5–S7 暂不启动。日期以 2026-11-07（周六）为 D0。

| 阶段 | 窗口 | 交付 | 归属 | 验收 |
|---|---|---|---|---|
| **S1** | D0–D+2（11-07 → 11-09） | ① `cert_gen.cpp` notBefore = now−1 日历年（复用闰日算法）② 在途改动（标题栏穿透 + GENTLE + tools HDC_TARGET）提交（**待用户确认后由总指挥执行**）③ RAG 语料更新（chunk 09/24 更新 + 新增 25/26，跑 `build_chunks.py`） | ① Omp ② AtomCode ③ AtomCode | `openssl x509 -dates` 显示 today−1y → today+10y；`hvigorw assembleHap` + native tests 绿；RAG 块数与 JSONL 一致 |
| **S2** | D+3–D+7（11-10 → 11-14） | 文件分享闭环：多文件队列、失败重试与错误码、接收/自动保存开关真正生效、进度 UI、`share.request.update` 收发 | ArkTS=CodeArts；Native 侧（进度/队列/错误码）=Omp | 双向各 ≥3 文件（含大文件）；失败有错误码；开关跨重启生效；接口契约先于实现定稿（D+3 当天） |
| **S4** | D+3–D+5（11-10 → 11-12，与 S2 并行） | 通知 reply/action 与 contacts 权限实测结论（能做→排期；不能→作为 Review「解释替代项」记录） | CodeArts（真机/权限实测；Omp 按需协助真机） | 结论文档落 `devdocs/`，含每项 API/权限名与实测结果 |

S2 依赖：分享接口契约（`share.request.update` 字段、多文件 payload 顺序与 transferId 语义）先定稿；
S1 的 ② 由用户确认后执行，不与 CodeArts 在途编辑抢跑。


- 通知 reply/action、contacts 可能因鸿蒙权限模型无法实现 ⇒ 先验证再承诺，不能做时在 README/Review issue 中作为「解释替代项」；
- SFTP 依赖 Rust 线（russh），若 S5 延期则 SFTP 顺延；
- 胶囊路线未定前不启动 S7；
- 功能性开发不改变「Native 只做官方 API 覆盖不到的部分」原则。

## 7. 技术栈与合并决策（2026-11-08 用户裁决）

| 项 | 裁决 |
|---|---|
| Native 方向 | **Rust 为主**：自 **0.8.x（拟 0.8.4 合入）** 起以 `dev/native-rust`（ohos-rs + rustls，TLS13+TLS12）为主开发栈 |
| C++ 去向 | `main` 当前仍为 C++（0.8.3 收口）；合并后 C++ 冻结在 **`backup/main-cpp`**，仅作参考/回退，不再开发 |
| 合并窗口 | **已完成（0.8.4，2026-11-08）**：cutover `813d4ba`；C++ 基线冻结 `backup/main-cpp`（`427612b`，已推双远端）；双评审 Approved/Conditional Approved |
| 版本计划 | **0.8.x = 当前全部功能开发**（S2/S4/S6 等均在 0.8.x 内完成，含 Rust 合并）；**0.9.0 = 正式进入 KDE 孵化项目**（里程碑版本，非功能版；对外动作需用户确认） |
| A+ HUKS | **归 0.8.x（Rust 合并后实施）**：keyPem 落盘改 HUKS AES-256-GCM 加密；**不进 0.9.0**（用户 2026-11-08 确认） |
| A/B | **后置**：C++ vs Rust 同场景 A/B 不作合并前置（Rust 已过 L0–L4 含真实 KDE 桌面）；合并后作回归/性能基线，可选最小冒烟仅补充 |
| S2 实施栈 | **C → B**：先只定契约 + ArkTS 接收批量 UI；合并批准后 Native 侧转 Rust 实现（避免双写，仍在 0.8.x 内） |
| Android「兼容」含义 | 指与 **Android 端 KDE Connect 的互操作**（对端），不是本端跑 Android；并入 S4 真机窗口做一次连接/配对/收文件预演，正式回归放合并后 soak |

### 7.1 平板双面板整治：**方案 C**（用户 2026-11-08 拍板）

- 删除 `DevicesTab` 的 `sideBySide` 分支，平板=手机同一布局（单列、页面级 List）；`HdsSideBar` 承担设备/分区选择；
- 下拉刷新移到主区 section 2（发现设备），手机/平板一致；rail 的 Refresh 随之移除；
- **分区标题行已在 `sectionContent()` 内（DevicesTab.ets:915-923），C 不改**——侧栏收起时主区仍有标题，无上下文丢失；
- **迷你栏不存在**：当前 HdsSideBar 仅有 sideBarWidth（40%/80%）+ isShowSideBar，收起=整栏隐藏；删 rail 后双层面板彻底消除；
- 开发依赖由 Omp-ArkTS 实施时列出并与用户逐项确认：`mainPaneScroller`/`bindToScrollable`/标题栏穿透绑定、`WIDE_RAIL_LIMIT`/`onPaneArea`/`sideBySide?3:2` 容量逻辑、主区 section 2 新增 Refresh；
- 归属：Omp-ArkTS 实现，CodeArts 复核，总指挥三实例复验后提交。

### 7.2 后续技术决策（2026-11-08 用户拍板，全部采纳建议）

| 项 | 裁决 |
|---|---|
| 全 Rust 合并 | **批准**；执行时机 = Omp-Native 在途 10 文件（doc 驱动加固）落地 + 门禁后，由总指挥 cutover → `backup/main-cpp` 冻结 → **0.8.4** |
| 桥层职责边界 | **方案 A**：协议逻辑下沉 Rust 引擎。分两阶段：① 合并后先按 kcbridge 形态对齐命令/事件/错误码（机械、可 Mock）；② 0.8.x 内把 `PacketRouter`/配对状态机/插件路由下沉引擎，ArkTS 保留 UI 与插件层、引擎可 Mock |
| 状态管理 V2 | **批准试点**：仅叶子组件对照 + `LogsTab` 页面先行；`animateTo`（DrawerOverlay/Index 两处）专项复验；试点文件与 S2 不重叠 |
| `docs/kdeconnect-oh` | **入库**（11 篇/172K；`.gitignore` 加例外 `!docs/kdeconnect-oh/**`；08 冻结契约/09 车道所有权/10 流水线为权威参考） |
| 四点菜单优化 | backlog（用户：先不急） |
| `signingConfig` | 维持 **`matepadiani`**（Win10 真机零配额已验证） |




## 8. 真机复验收尾与 backlog（2026-11-11，CodeArts MSG225 复核后裁决）

### 8.1 已通过（真机 `63Q0226131002161` / MSG224 版本）

| 项 | 证据 |
|---|---|
| 自动保存 **开态**：png → 相册 | `savePayload #12 isImage=true perm=needed granted=true` → `album=true` → `settle #12 sandboxOnly=false` |
| 自动保存 **开态**：bin → 应用内 | `savePayload #13 perm=none granted=true` → `settle #13 sandboxOnly=true` → `-> in-app` |
| 批次 UI | dump 无 `0/1·0%`、无「接收中」；两条批次 `1/1·100%`，行文案「已保存」/「已保存到应用内 + 导出」 |
| 自动保存 **关态** | `autosave gate … autoSave=false`，文件留「待处置」（预期行为） |

### 8.2 backlog（不阻塞当前收尾）

| 项 | 裁决 | 来源 |
|---|---|---|
| 跨会话 `settled=false` 历史条目（spool 已不存在）仍显示保存/丢弃 | **采纳 CodeArts 方案 B**：`PayloadRow` 新增 `canDispose`，历史分区 `!settled` 不显示按钮、文案「已结束」；列入 **0.8.x 后续补丁** | CodeArts MSG225 §6 |
| `failActiveTransfer`/`failInflightReceives` 重建 failed 未带 `sandboxOnly` | 低优先，随诊断剥离同批补 `sandboxOnly: p.sandboxOnly === true` | CodeArts MSG225 §1.1 |
| `terminalIds` 无上限（长会话内存增长） | 低优先，加与 `DISCARD_KEEP` 同类上限 | CodeArts MSG225 §2.3 |
| native `.transfer_seq` 崩溃窗口（fetch_add 与落盘之间被杀） | **接受现状**：窗口一行代码、概率极低，ArkTS `started` 强制重置已兜底；不追加复杂度 | CodeArts MSG225 §4.1 |
| 诊断日志剥离 | **10 条**（9 ArkTS `KDC diag` + 1 native `[KDC-DIAG] payload emit`），负向分支验证后一次性剥离 | CodeArts MSG225 §5 |

### 8.3 新增 backlog（2026-11-11 用户提出）

| 项 | 说明 | 状态 |
|---|---|---|
| **「打开文件管理 / 打开所在位置」**（参考 iOS 端） | 文件保存后提供入口跳转到**系统文件管理**并定位到该文件（区别于 MSG243 的「打开文件」本身）。HarmonyOS 候选路径：① `startAbility` + `ohos.want.action.viewData`（打开文件，已用于 MSG243）；② 文件管理器 bundle（`com.huawei.hmos.filemanager`）非公开契约，普通应用**不能可靠唤起并定位**；③ `DocumentViewPicker` 只能选目录不能定位；④ 折中：保存时记录路径 + toast/详情里展示「位置：Downloads/…」，或引导用户到「文件」App 手动定位。**结论：需先评估 ② 的可行性（大概率不可行），否则以 ④ 交付** | backlog（0.8.x 评估） |

> iOS 参考实现待查：本机参考库（`kdeconn1111/`）未包含 `kdeconnect-ios-master`，需在 Win10/旧工作区取 iOS 源码后对照（重点关注 `UIDocumentInteractionController`/`QLPreviewController`/`UIDocumentPicker` 的使用场景：是「打开文件」还是「在文件中显示」）。
