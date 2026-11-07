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

## 6. 风险与前置

- 通知 reply/action、contacts 可能因鸿蒙权限模型无法实现 ⇒ 先验证再承诺，不能做时在 README/Review issue 中作为「解释替代项」；
- SFTP 依赖 Rust 线（russh），若 S5 延期则 SFTP 顺延；
- 胶囊路线未定前不启动 S7；
- 功能性开发不改变「Native 只做官方 API 覆盖不到的部分」原则。
