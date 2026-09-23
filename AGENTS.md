# KDE-H Connect 仓库级 AGENTS.md

> **2026-09-12 迁移说明（zcode 落地）**：本文件自旧工作区拷入**仓库根**（新正本，Syncthing 双机可见；旧工作区已降级为只读参考）。阅读下文时按此映射：
> - 「主开发对象 `kdeconnect-harmony-PreDev/`」→ **现在就是本仓库根**（重建后的工程直接位于仓库根：`entry/`、`AppScope/`、`tools/`…）；
> - 「中心仓库 gitcode 尚未同步 / 不 add remote」→ 本仓库已 clone 自 gitcode（remote origin 已配置，分支 `dev/zcodeinit`），**push 仍需用户明确授权**（CodeArts 掌握 commit/push 时机）；
> - 「两机协作走共享目录/DevEco 副本」→ **已废弃**，改为 Syncthing 实时同步（机器本地产物以两侧 `.stignore` 排除）；
> - 参考实现（`kdeconnect-meta/` 等）仍在旧工作区，Win10 不可达——需要查 schema/上游源码时请 Linux 侧 agent（zcode / CodeArts）代查。
> C++ 侧规范见 `devdocs/CPP_GUIDE.md`；ArkTS 侧见 `devdocs/ARKTS_GUIDE.md`；工作流见 `devdocs/PROCESS.md`。

---
# KDE Connect 鸿蒙版工作区

> 项目位置：本机 CachyOS 工作区（**2026-09-12 起为项目正本**）。此前曾短暂放在 libvirt 共享目录（Win10 VM 经 virtiofs 可见，内含 DevEco 专用副本）——**该位置已不再是项目位置，副本已于 2026-09-12 按用户决定整体删除**。QEMU 模拟器镜像/日志一直在宿主工作区。

主开发对象 `kdeconnect-harmony-PreDev/`（OpenHarmony API 26 / Stage 模型 / ArkTS，bundleName `org.kde.kdeconnect.harmony`），其余子项目是协议规范与参考实现。本根目录**不是** git 仓库；`kdeconnect-meta` / `kdeconnect-android` / `kdeconnect-kde` 是独立 git 仓库（上游参考代码，通常只读）；**`kdeconnect-harmony-PreDev` 已是 git 仓库**（2026-09-12 初始化，分支 `master`），**中心仓库为 gitcode <https://gitcode.com/Gr1m/kdeconnect-harmony>**（**已同步：`dev/zcodeinit` 与 `main` 均已 push，2026-09-15 起**，见「双机协作」）。**本文件与仓库内 `kdeconnect-harmony-PreDev/AGENTS.md` 是同一份**（仓库版供 Win10 侧 agent 加载），改任一份必须同步另一份（提交需用户授权）。

## 子项目与命令

- `kdeconnect-meta/` — 协议规范（无应用代码）。`schemas/` 下每个 JSON Schema 定义一种 NetworkPacket 的 `body`；`protocol.md` 由 `schemas/schema2md.py` 生成。**改任何 schema 后必须在 `kdeconnect-meta/` 内 `make check` 确认同步**，重新生成用 `make`。
- `kdeconnect-android/` — Android 参考（Kotlin/Java，minSdk 23 / targetSdk 37，CI 用 JDK 21）。构建+测试：`./gradlew assembleDebug lintDebug testDebugUnitTest`。
- `kdeconnect-kde/` — 桌面参考（C++20 / Qt 6.7+ / KF 6.0+ / CMake）。上游对 AI 贡献有硬政策（不接受 AI 主导 MR、禁 unicode、不代写 MR 描述、不擅自 commit/push），改动前必须读其 `AGENTS.md` 与 `CONTRIBUTING.md`。
- `kdeconnect-harmony-PreDev/` — 鸿蒙实现。构建 `hvigorw assembleHap`（本机 `hvigorw` 已在 PATH：`/opt/command-line-tools/bin`，**无本地 wrapper，不要 `./hvigorw`**）；依赖已装则跳过 `ohpm install`。本终端有网且项目目录可写，可在本终端构建；**安装到模拟器（hdc）建议在用户终端跑**。环境搭建与踩坑见该目录 `SETUP_NOTES.md`，模拟器调试见**工作区根目录** `EMULATOR_NOTES.md`。

## 鸿蒙构建要点（勿回退，详见 SETUP_NOTES.md）

- `@ohos/hvigor*` 不在任何公开 registry，已软链到 `oh_modules/@ohos/`，**勿删、勿在 oh-package.json5 声明**。
- `modelVersion` 必须 `"6.0.0"`；`compileSdkVersion` 等必须字符串 `"26.0.0"`；`deviceTypes` 用 `["default"]`（API 26 不支持 `"phone"`）。
- 调试签名已打通：`tools/sign-debug.sh`（构建+签名+安装+启动，SDK 本地材料，无需 DevEco/华为账号）。最大坑：p12 中 `openharmony application release` 条目是私钥自签包装，**真正的叶证书是 profile 模板 JSON 内嵌的 `development-certificate`**；证书链须 leaf→App CA→Root，`keytool -exportcert` 必须加 `-rfc`。材料/产物在 `sign/`（已 gitignore），细节见脚本头注释。
- **native 网络栈必须在 `module.json5` 声明 `ohos.permission.INTERNET`**：未声明时沙箱内 `socket()` 直接失败，hilog 只留 `udp init failed` 一行且 errno 被隐私策略掩成 `<private>`，现象极像代码 bug 实为权限。声明后 UDP/TCP 立即恢复。
- **`devecocli`（deveco-cli）build/device 已实测可用**：`devecocli build` ≈ `hvigorw assembleHap` 薄封装（调 CLT 内置 hvigorw.js，任务链一致，另 merge `compile_commands.json` 供 LSP；不签名，装模拟器仍走 `sign-debug.sh`）；`devecocli device list` 可见 QEMU 模拟器（127.0.0.1:5555）。`devecocli check lint` 被类型门禁卡死，见下条。
- **ArkTS 静态检查以 `hvigorw assembleHap` 编译期检查为准（lint 当前不可用，已实证）**：本机 CLT 是商用 HarmonyOS 版，codelinter 内置类型门禁（工程 `sdk.dir` 指向 openharmony SDK → 判定 OpenHarmony 项目，商用 CLT 直接拒绝）使 `codelinter`/`devecocli check lint` 硬报错「CLT 类型不匹配」（"No defects found" 是假象，勿采信）；门禁只卡 lint 不卡 build。旁路已验证走不通：`--inIde true` 可绕过门禁，但 CLI 独立运行缺 IDE 提供的文件清单，各 lint agent 全部 "no check file"（targets undefined）；`--sdkPath` 占位值或真实 openharmony SDK 路径同样 0 文件。OpenHarmony SDK（`/opt/ohos-sdk`）不自带 codelinter（仅 ets-loader 内 eslint 组件，无 CLI 入口）。**唯一让 lint 生效的路径 = 安装 OpenHarmony 官方 CLT（含 OHOS 版 codelinter），需联网下载、须经用户同意**。工程根 `code-linter.json5` 是官方默认模板，当前无工具消费，为将来切商用 SDK 保留。
- **libxml2 soname 坑（2026-09-13 实测，挡住所有 Linux 侧构建）**：系统 libxml2 升到 2.15（`libxml2.so.16`），而 CLT 的 BiSheng `ld.lld` 依赖 `libxml2.so.2`，CMake 探测编译器即失败（`CMake will not be able to correctly generate this project`，与业务代码无关）。旁路不改系统：`mkdir -p ~/.local/share/ohos_libshim && ln -sf /usr/lib/libxml2.so.16 ~/.local/share/ohos_libshim/libxml2.so.2` 后 `LD_LIBRARY_PATH=$HOME/.local/share/ohos_libshim hvigorw --no-daemon assembleHap`（`--no-daemon` 必需：已启动的 hvigor daemon 不会继承新环境变量）。**路径别放 `/tmp`**：临时目录清理会把 shim 删掉，症状是链接期莫名失败（`clang++: unable to execute command: No such file or directory`，2026-09-14 实测踩过两次；`/tmp/ohos_libshim` 现为指向该稳定目录的软链，仅为兼容旧习惯）。

## 协议约束

packet 以换行分隔的 JSON 字符串发送：`{"id", "type", "body", "version"}`，带二进制负载时加 `payloadSize`（-1 为流式）和 `payloadTransferInfo`。鸿蒙版 packet 的 `type` 与 `body` 字段必须与 `kdeconnect-meta/schemas/` **严格一致**；新增/修改 packet 类型先改 schema、`make check` 通过，再改实现。对照参考实现时注意：两端插件目录名**不严格一一对应**（Android 拆 `*receiver`，KDE 拆 `send*`，mpris 拆 control/remote），以 packet type 为准，勿以目录名对齐。
网络栈为 **native C++（NAPI）**：UDP 发现、TCP server/连接、BearSSL 0.6 TLS 握手、证书自生成、packet 序列化均在 `kdeconnect-harmony-PreDev/entry/src/main/cpp/` 实现（`net/` 下按 udp_discovery / tcp_server / tcp_connection / tls_engine / cert_gen / packet_io 分文件），由 NAPI 桥接给 ArkTS。BearSSL 与 cJSON 均 vendor 在 `cpp/` 下（OHOS sysroot 无 JSON 库）：BearSSL 经 CMake `file(GLOB_RECURSE)` 编译，hvigor 按 ABI 自动交叉，**勿另写独立交叉编译脚本**。
**跨端常量（必须三端一致，改一处要改三处）**：protocolVersion=8；UDP 1716；TCP 1716–1764；payload 端口 ≥1739；单包 32 MiB；identity 包 8 KiB；配对 timestamp 容差 ±1800 秒（**秒**，非毫秒）；deviceId 正则 `^[a-zA-Z0-9_-]{32,38}$` 且 = 证书 CN，**必须持久化**（每次启动重生成会导致对端视为新设备）；证书有效期 -1y→+10y；验证码 = 双方公钥 DER 按字节序排序拼接 + SHA256 前 8 位 hex 大写（v8 再追加配对 timestamp）。
**实现坑（易踩，详见 `docs/14`）**：TCP 是流，读循环须自维护缓冲按 `\n` 切分（一次 message ≠ 一个完整包，半包等下次，非法 JSON 丢弃该行继续，勿抛异常中断读循环）；identity 包**不含证书**，对端证书须从 TLS 层获取；必须忽略自己的 deviceId（防自连死循环）；未配对设备只收 `kdeconnect.pair`，其余包丢弃并 unpair；v8 须在加密通道内二次交换 identity 并校验 deviceId/protocolVersion 未变；发送侧用单写者队列防 JSON 帧交错；插件回调逐个隔离异常。
**鸿蒙平台硬约束（现有架构的原因，勿回退）**：ArkTS `cert` 模块只能解析/校验证书、**不能签发** → 自签证书生成必须在 native（本项目用 BearSSL 自生成）；HUKS 密钥不出 TEE 不可导出，与系统 TLS 要求 PEM 私钥不兼容——若将来改用系统 `TLSSocket`，密钥必须走 `cryptoFramework`（可导出）。

## 鸿蒙 UI 要点

- 单页 `pages/Index.ets`：标题置顶 → 状态栏 → 功能（手动连接/发现设备）→ 日志，自上而下分行卡片布局；背景深空渐变 + `radialGradient` 光斑。
- 卡片材质走「沉浸光感」：`@ohos.arkui.uiMaterial`（API 26，`ImmersiveMaterial` + 通用属性 `systemMaterial`），`uiMaterial.isImmersiveMaterialSupported()` 探测设备能力，**QEMU 模拟器运行时未实现该 API**（d.ts 有声明），须 catch 后降级 `backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)` 毛玻璃——探测失败勿写屏幕日志。
- 状态栏安全高度由 `EntryAbility.onWindowStageCreate` 里 `setWindowLayoutFullScreen(true)` + `getWindowAvoidArea` 读入 AppStorage，页面用 `this.getUIContext().px2vp()` 换算（全局 `px2vp` 在 API 26 已废弃）。
- 已连接设备列表（`connectedDevices`）由 ArkTS 依据 native 的 `connected`/`disconnected` 事件维护，断开按钮调 `native.disconnect(deviceId)`。**层间契约：native 必须在所有断开路径（主动断、对端断、TLS 失败）都派发 `Disconnected` 事件**，否则 UI 残留死连接。
- **配对协议分层**：`pairingRequest` 事件是 TLS 握手层的 identity 帧（**不是**配对请求），ArkTS 只回填设备名、**勿自动回发 pair**（双方互发 pair 请求会导致 KDE 配对超时）；真正的配对请求是 `packetReceived` 里的 `kdeconnect.pair` 帧，由 `PacketRouter.handlePair` 应答。**已连接设备行只保留「配对 / 解除配对」（2026-09-13 用户最终裁决，对齐 iOS）——没有「断开」按钮**：「解除配对」= 发 unpair `{pair:false}` + 本侧重复置 `paired=false`（条目保留为「未配对」），**不主动断链、不做抑制**（KDE 自己管理链路，可能重拨，UI 只反映 `connected`/`disconnected` 事件）。**连接/配对会话**：手动连接与发现页连接都走 `startSession`（**任何情况都必须给 toast 反馈**：成功/失败都要提示，失败只给错误码）；配对统一由行内「配对」触发并弹验证码确认框；配对成功自动跳回「已连接设备」分区。
- 事件语义（已端到端验证）：`connected` 在 TLS 握手 + 双方 identity 完成后派发，带 `deviceName`/`role`；`disconnected` 在主动断与对端断（含 readTls==0）均派发。桌面 KDE 只对已配对设备发 mount 共享目录请求——guest 未实现文件共享时该请求失败属**预期行为**，非 bug。
- 开发偏好：UI/业务层尽量用官方 ArkTS 实现，native C++ 只保留官方 API 覆盖不到的部分（socket/TLS 网络栈）。

## 双机协作（gitcode 中心仓库 + 本机开发 / Win10 DevEco 验证，2026-09-12 起）

- **中心仓库**：<https://gitcode.com/Gr1m/kdeconnect-harmony>（GPL-2.0-or-later，2026-09-19 由 GPL-3.0 变更）。**已同步（2026-09-15）**：`main` 与本机工程**同根**（初始提交 `8d6c639`），本机开发分支 `dev/zcodeinit` 已 push（首个 push 2026-09-15，`71c7b46..3c34001`），`main` 已推进到与 `dev/zcodeinit` 一致。开发仍在 `dev/zcodeinit`，**每次 push 需用户/CodeArts 明确授权**（CodeArts 掌握时机）。仓库范围**只有 `kdeconnect-harmony-PreDev/` 工程**（meta/android/kde 参考仓库与根 `docs/` 不入仓库）。
- **GitHub 镜像（2026-09-15 建）**：<https://github.com/Gr-1m/kdeconnect-harmony>（GPL-2.0-or-later，2026-09-19 由 GPL-3.0 变更）。本机已配置第二远端 **`github`**（SSH；`~/.ssh/config` 需有 `github.com` → `IdentityFile ~/.ssh/github_ed25519`，否则报 `Permission denied (publickey)` —— 2026-09-15 踩过）。该仓库初始只是 `LICENSE` 空壳、与本机历史**无关**，已用 gitcode 侧历史**强推覆盖**（`git push --force github main:main`，`dev/zcodeinit` 一并新推；两分支与 gitcode 指向同一提交）。日常 push 仍走授权；两个远端内容应保持一致。
- **本机 CachyOS** 为开发正本；**Win10**（LTSC 21H1，DevEco Studio 26.0.0.821）用 DevEco 构建、跑模拟器做验证。**同一文件不要两台机器同时改**。
- 同步约定：改前先 pull、提交后 push；换行符：Win10 设 `core.autocrlf true`、本机设 `core.autocrlf input`，避免 CRLF diff 噪音。
- **共享目录的版本标记（2026-09-14 起）**：`.git` **不同步**——Syncthing 搬不动活着的 git 仓库（`index`/`refs` 靠原子重命名与锁，冲突副本无法像普通文件那样手工合并，且会让两台机器都「看起来拥有历史」而破坏单写者不变式）。Win10 侧改用 `AgentsConversion/GIT_REVISION.md` 判断「同步过来的文件对应哪个提交」：由 `tools/sync-revision.sh` 在本机每次提交/合并/切分支后自动刷新（git hook）。新机器/新克隆需执行一次 `tools/sync-revision.sh --install`（hook 只写在本机 `.git/hooks`，不随同步）。该标记文件不是仓库内容，勿手改。
- **提交前编码守卫（2026-09-15 起）**：同一个安装脚本还会装 **`pre-commit`**，由 `tools/check-encoding.py` 检查待提交文本文件——出现**非法 UTF-8** 或**替换字符 U+FFFD** 即拒绝提交（`git commit --no-verify` 可绕过）。构建门禁拦不住注释里的乱码：2026-09-15 有 Win10 编辑器按非 UTF-8 重存 `Index.ets`，437 处中文乱码、连字符串收尾引号都被吞掉才让 ArkTS 编译失败。检查器自身与其文档描述里**不得**出现真实的替换字符字面量（否则会被自己拦下）。
- **待 Win10 首验的三件事**：DevEco 商用 SDK 能否构建本 OpenHarmony(API 26) 工程、DevEco 模拟器能否安装运行、lint 面板是否有输出。结论回填 `AgentsConversion/`；若不可用，构建/运行回退本机 ohemu 路线（lint 仍受类型门禁，见「鸿蒙构建要点」）。
- 机器专属事实（对方不可复现）：本机 = 商用 CLT `/opt/command-line-tools`、OpenHarmony SDK `/opt/ohos-sdk`、ohemu QEMU 手机模拟器（镜像/日志在 `~/WorkSpace2/`）、`sign-debug.sh` 签名安装、工作区根 `EMULATOR_NOTES.md`（**不在仓库内**）。Win10 = DevEco SDK/模拟器。
- **UI 规范参考（用户 2026-09-15 放置，改配色/图标时先查）**：Win10 本机 `C:\Users\<user>\Documents\cv\secai-tubiao.txt`（**不在仓库内**，Linux 侧不可复现）记了鸿蒙官方两份 UX 规范入口 —— 色彩 <https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/color-0000001776857164>、应用图标 <https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/application-icon-0000001953444009>。改图标/配色时先取这两份（页面为 JS 渲染，需联网抓取）。

## 模拟器调试（ohemu，本机兜底路线）

QEMU 手机镜像跑在宿主（非真机、非 IDE）：镜像/日志放 `~/WorkSpace2/`（勿散落在 `~` 顶层）。启动必须 `setsid nohup … < /dev/null &`（普通 `nohup &` 会被工具会话回收）；连接 `hdc tconn 127.0.0.1:5555` 后 `hdc list targets` 确认；日志 `~/WorkSpace2/ohemu.log`。全流程（含 Win10 VM 事故教训——根目录 `vm-HarmonyDev.xml` 即该 VM 的 libvirt 配置、`-phone` 与 `-2in1` 镜像差异）见工作区根目录 `EMULATOR_NOTES.md`。

## docs/ 参考资料（他机整理，引用需谨慎）

`docs/` 17 篇 + `AGENTS1.md` 来自另一台机器的参考工作区（子目录带 `-master` 后缀、含 iOS 端，与本工作区目录名**不一一对应**）。用途：01–09 项目理解；**10–11 开发者地图/功能点字典（新 agent 先读 10→11，按任务定位文件符号，省去全库搜索）**；12–15 鸿蒙移植四篇（Android/iOS 实践 / 移植指南 / 协议适配 / 问题与决策记录）；16 会话记录（标注哪些结论已验证、哪些是假设）。**鸿蒙侧结论基于公开文档调研（2026-09），未经真机验证，以实测为准**；文中 `文件:行号` 对应他那台快照，**按符号名搜索，勿按行号**。

## 工具与协作

- `.codeartsdoer/` 是 CodeArts 索引与技能状态，勿手动修改。
- `AgentsConversion/` 是 CodeArts 与 atomcode 双代理的指令记录；其中 `USER_SAY.md` 是实时通信文件，执行命令前后注意检查该目录下的文件变化。

## 维护规则

当项目结构、构建/测试命令、架构边界、开发约定，或本文件记录的其他事实发生变化时，必须在同一次改动中同步更新本文件。

## KDE 孵化跟踪（2026-09-22 起）

- 用户已与 KDE 官方社区正式沟通，命名采用官方品牌（显示名 KDE Connect、bundleName `org.kde.kdeconnect`）；
- **孵化流程的推进与状态跟踪由 Atomcode 负责**：进度记录见 `devdocs/INCUBATION_STATUS.md`（含 checklist 勾选状态），流程要点见思源笔记 `/Dev/开源社区/KDE 项目孵化`；
- 孵化关键里程碑（Invent 建仓/Incubation Request issue/担保人/Review/转正）发生变化时，必须同步更新 `devdocs/INCUBATION_STATUS.md` 并发 MSG 通知全员。
