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
| 合并窗口 | **0.8.x 内、0.9.0 之前完成（拟 0.8.4）**；前置 = CodeArts 全 Rust 评审（Approved 或 Conditional 闭合）+ Omp-Native 在途收尾 + 分支 push + 用户最终批准 |
| 版本计划 | **0.8.x = 当前全部功能开发**（S2/S4/S6 等均在 0.8.x 内完成，含 Rust 合并）；**0.9.0 = 正式进入 KDE 孵化项目**（里程碑版本，非功能版；对外动作需用户确认） |
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


