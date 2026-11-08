# KDE Connect 鸿蒙版

**中文** | [English](README.md)

[KDE Connect](https://kdeconnect.kde.org/) 的 HarmonyOS（OpenHarmony API 26）移植版——让你的设备通过局域网互相通信的多平台工具。

> **状态**：**0.8.4** —— native 栈已全量迁移到 Rust（`ohos-rs` + `rustls`，TLS 1.3/1.2）。核心网络（UDP 发现、TCP、TLS、配对）、文件分享（批量进度 UI）与插件集可用。已在 HarmonyOS 模拟器（折叠/平板）与真机（MatePad Mini、Mate 80 Pro）上与 KDE 桌面端验证。

## 截图

<!-- 截图将在此处添加。见 screenshots/ 目录。 -->
<!-- 建议截图：主界面、配对弹窗、媒体控制、文件接收、设置页 -->

## 功能

| 功能 | 状态 | 协议包 |
|---|---|---|
| 设备发现与配对 | ✅ 可用 | `kdeconnect.identity`, `kdeconnect.pair` |
| 文件分享 | ✅ 可用（0.8.4 起批量 UI） | `kdeconnect.share.request`, `share.request.update` |
| 剪贴板同步（双向） | ✅ 可用 | `kdeconnect.clipboard`, `kdeconnect.clipboard.connect` |
| 查找设备（响铃） | ✅ 可用 | `kdeconnect.ping` |
| 电池状态（双向） | ✅ 可用 | `kdeconnect.battery`, `kdeconnect.battery.request` |
| 网络状态上报 | ✅ 可用 | `kdeconnect.connectivity_report` |
| 远程命令 | ✅ 可用 | `kdeconnect.runcommand` |
| 媒体控制（控制方） | ✅ 可用 | `kdeconnect.mpris`, `kdeconnect.mpris.request` |
| 远程输入（触摸板） | ✅ 可用 | `kdeconnect.mousepad.*` |
| 通知 | ✅ 展示（平台不支持回复/操作） | `kdeconnect.notification.*` |

## 架构

```
┌──────────────────────────────────────────────┐
│              ArkTS（UI + 插件）               │
│  ┌────────────┐ ┌──────────────┐ ┌─────────┐ │
│  │   插件     │ │ PacketRouter │ │  UI 层  │ │
│  └─────┬──────┘ └──────┬───────┘ └─────────┘ │
├────────┼───────────────┼─────────────────────┤
│        │      NAPI 桥（ohos-rs）               │
├────────┼───────────────┼─────────────────────┤
│  ┌─────┴───────────────────────────────────┐  │
│  │ Rust native — entry/src/main/cpp/rust/full/ │
│  │  kdc_native（core）+ kdeconnect_napi       │
│  │  发现 · TCP · TLS(rustls) · 证书(rcgen)     │
│  │  packet 帧 · payload spool · 配对状态机     │
│  └────────────────────────────────────────────┘
└──────────────────────────────────────────────┘
```

- **Rust native（`ohos-rs` + `rustls`）**：UDP 发现、TCP 服务端/连接、TLS 1.3/1.2、自签证书生成（rcgen）、packet 序列化、payload 传输与 spool、配对状态机——全部位于 `entry/src/main/cpp/rust/full/`（`core` + `napi` 两个 crate）。
- **ArkTS**：插件框架（注册表驱动）、UI、业务逻辑；NAPI 契约冻结在 `entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts`。
- **C++ 基线**：0.8.4 起已从 `main` 移除，冻结在分支 `backup/main-cpp`（仅历史参考/回退）。

## 技术栈

| 层 | 技术 |
|---|---|
| UI / 业务 | ArkTS（OpenHarmony API 26，Stage 模型） |
| Native 网络 | Rust（ohos-rs, rustls, rcgen, serde, sha2） |
| 构建 | hvigorw（HarmonyOS）, CMake → cargo（native） |
| 协议 | KDE Connect 协议 v8 |

## 构建

### 前置条件

- HarmonyOS Command Line Tools（`/opt/command-line-tools`）
- OpenHarmony SDK（`/opt/ohos-sdk`）
- Rust 工具链（native 栈已全 Rust 化）：

  ```bash
  rustup target add aarch64-unknown-linux-ohos x86_64-unknown-linux-ohos
  ```

  CMake 只调用 `cargo` 产出 `libkdeconnect_napi.so`；架构、测试口径与已知风险见 `devdocs/FULL_RUST.md`。
- **Windows 交叉编译**（Win10 侧 DevEco）：6 个用户级环境变量（`CC_/AR_*`、`CARGO_TARGET_*_LINKER`）
  加 `hvigorw --stop-daemon`——见 `devdocs/CPP_GUIDE.md`“Windows 交叉编译前置”小节。
- Python 3（用于编码守卫）
- **新克隆的首次构建**：先 `ohpm install`（`oh_modules/` 不入库），再执行一次
  `tools/sync-revision.sh --install` 安装 git hooks（版本标记 + 编码守卫）

### 构建 HAP

```bash
# libxml2 旁路（系统 libxml2 > 2.12 时需要）：
mkdir -p ~/.local/share/ohos_libshim
ln -sf /usr/lib/libxml2.so.16 ~/.local/share/ohos_libshim/libxml2.so.2

# 构建：
LD_LIBRARY_PATH=$HOME/.local/share/ohos_libshim hvigorw --no-daemon assembleHap
```

### 签名并安装到设备

```bash
# 调试签名（本地材料，无需华为账号）：
tools/sign-debug.sh
```

### 运行测试

```bash
entry/src/main/cpp/tests/run.sh
# = cargo test -p kdc_native（19 个单测 + 1 个双栈互联 E2E）
#   + cargo check -p kdeconnect_napi（NAPI 符号无法在宿主链接）
#   + NAPI 契约完整性检查（Index.d.ts ↔ 导出字段）
```

## 项目结构

```
kdeconnect-harmony/
├── entry/src/main/
│   ├── cpp/
│   │   ├── rust/full/        # Rust native workspace
│   │   │   ├── core/         # kdc_native：发现/TCP/TLS/证书/packet/payload/状态
│   │   │   └── napi/         # kdeconnect_napi：NAPI 导出与事件
│   │   └── types/            # Index.d.ts（冻结的 NAPI 契约）
│   ├── ets/
│   │   ├── plugins/          # 插件（注册表驱动）
│   │   ├── net/              # PacketRouter
│   │   ├── common/           # PayloadHistory、共享类型
│   │   ├── components/       # DevicesTab, SettingsTab, FilesTab, DeviceInfoDialog
│   │   └── pages/            # UI（Index.ets）
│   └── module.json5          # 权限、abilities
├── tools/                    # sign-debug.sh, check-encoding.py, sync-revision.sh
├── devdocs/                  # 开发者指南、runbook、路线图
├── docs/kdeconnect-oh/       # 冻结接口契约与车道手册（参考）
├── LICENSES/                 # REUSE 许可文本（GPL-2.0-or-later、CC0-1.0）
├── screenshots/              # 应用截图
├── LICENSE                   # GPL-2.0-or-later
```

## 协议兼容性

实现 KDE Connect 协议 v8，严格遵循 schema（`kdeconnect-meta/schemas/`）。跨端常量：

| 常量 | 值 |
|---|---|
| 协议版本 | 8 |
| UDP 端口 | 1716 |
| TCP 端口范围 | 1716–1764 |
| Payload 端口 | ≥1739 |
| 单包最大 | 32 MiB |
| Identity 包 | 8 KiB |
| 配对时间戳容差 | ±1800 秒 |

## 开发环境

本项目在局域网内的两台机器上协作开发，文件同步由 [Syncthing](https://syncthing.net/) 完成：

| 机器 | 操作系统 | 职责 |
|---|---|---|
| **CachyOS**（Linux） | CachyOS（Arch 系） | Rust native 开发、host 侧测试、KDE Connect 桌面端（协议对端验证）、git 操作（单写者） |
| **Win10** | Windows 10 LTSC 21H1 | ArkTS 开发（DevEco Studio）、HarmonyOS 模拟器与真机调试（MatePad Mini） |

- 两台机器通过 Syncthing 共享同一个工作区——**同一文件不要两侧同时编辑**
- `.git` 只存在于 Linux 侧；Win10 侧通过 `AgentsConversion/GIT_REVISION.md` 对齐文件对应的提交
- KDE Connect 桌面端运行在 CachyOS 上，作为端到端测试的协议对端

## 开发

### 新增插件

1. 创建 `entry/src/main/ets/plugins/MyPlugin.ets`，继承 `PluginBase`
2. 声明 `supportedPacketTypes`（incoming）和 `outgoingPacketTypes`（outgoing）
3. 实现 `onPacketReceived()`，可选实现 `onCreate()`/`onDestroy()`
4. 在 `PluginRegistry`（`Index.ets`）中注册
5. 框架自动处理能力协商和包路由

### 编码规范

- Rust：见 `devdocs/FULL_RUST.md`（架构、不变式、测试）
- C++（历史，冻结在 `backup/main-cpp`）：见 `devdocs/CPP_GUIDE.md`
- ArkTS：见 `devdocs/ARKTS_GUIDE.md`
- 工作流：见 `devdocs/PROCESS.md`
- 所有文本文件必须是合法 UTF-8（由 `tools/check-encoding.py` pre-commit hook 强制）

## 许可证

GPL-2.0-or-later — 与上游 kdeconnect-android（GPL-2.0-only）与 kdeconnect-kde（GPL-2.0-or-later）兼容，
可直接移植两端代码。见 [LICENSE](LICENSE)。（2026-09-19 由 GPL-3.0 变更）

## Agent 分工

本项目由**安全开发工程师 Gr%1m** 提出需求与关键裁决；日常实现、评审与验证由多个 AI Agent 分工完成（协作规则与踩坑记录见 `devdocs/PROCESS.md`）。

| 角色 | 承担 | 说明 |
|---|---|---|
| **omp**（Linux 侧） | Rust native 全栈、host 测试与真桌面验证 | 发现/TCP/TLS/证书/NAPI 桥/payload；`backup/main-cpp` 仅历史参考 |
| **DevEco Code**（Win10 侧） | ArkTS：UI、插件框架与插件集 | 在 DevEco Studio 中构建，真机 / 模拟器验证 |
| **CodeArts** | ArkTS/UI owner；代码评审与裁决支持 | 维护 `devdocs/PROCESS.md` 与协作台账 `AgentsConversion/` |
| **AtomCode** | 总指挥：任务派发、跨车道协调、唯一 commit/push、构建与模拟器验证 | 迁移方案、评审、验收判据 |
| **ZCode** | 早期 C++/native 与构建奠基 | 后交棒 omp |

两侧通过 Syncthing 共享工作区协作：**同一文件不双写**；`.git` 只存在于 Linux 侧（Win10 侧用
`AgentsConversion/GIT_REVISION.md` 对齐「文件对应哪个提交」，编码守卫拦掉乱码）。

## 致谢

- [KDE Connect](https://kdeconnect.kde.org/) — KDE 社区的原始项目
- [kdeconnect-android](https://invent.kde.org/network/kdeconnect-android) — Android 参考实现
- [kdeconnect-kde](https://invent.kde.org/network/kdeconnect-kde) — 桌面参考实现
- [kdeconnect-meta](https://invent.kde.org/network/kdeconnect-meta) — 协议 schema
- [Syncthing](https://syncthing.net/) — 去中心化文件同步，支撑双机协作开发
