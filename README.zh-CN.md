# KDE Connect 鸿蒙版

**中文** | [English](README.md)

[KDE Connect](https://kdeconnect.kde.org/) 的 HarmonyOS（OpenHarmony API 26）移植版——让你的设备通过局域网互相通信的多平台工具。

> **状态**：早期开发阶段。核心网络（UDP 发现、TCP、TLS、配对）和 10 个插件已可用。已在 MatePad Mini 上与 KDE 桌面端真机验证。

## 功能

| 功能 | 状态 | 协议包 |
|---|---|---|
| 设备发现与配对 | ✅ 可用 | `kdeconnect.identity`, `kdeconnect.pair` |
| 文件分享 | ✅ 可用 | `kdeconnect.share.request` |
| 剪贴板同步（双向） | ✅ 可用 | `kdeconnect.clipboard`, `kdeconnect.clipboard.connect` |
| 查找设备（响铃） | ✅ 可用 | `kdeconnect.ping` |
| 电池状态（双向） | ✅ 可用 | `kdeconnect.battery`, `kdeconnect.battery.request` |
| 网络状态上报 | ✅ 可用 | `kdeconnect.connectivity_report` |
| 远程命令 | ✅ 可用 | `kdeconnect.runcommand` |
| 媒体控制（控制方） | ✅ 可用 | `kdeconnect.mpris`, `kdeconnect.mpris.request` |
| 远程输入 | ⏳ 占位 | `kdeconnect.mousepad.*` |
| 通知 | ⏳ 占位 | `kdeconnect.notification.*` |

## 架构

```
┌─────────────────────────────────────────────┐
│              ArkTS（UI + 插件）              │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  │
│  │ 10 个插件 │  │PacketRouter│  │  UI 层    │  │
│  └────┬─────┘  └────┬─────┘  └───────────┘  │
│       │              │                        │
├───────┼──────────────┼────────────────────────┤
│       │   NAPI 桥接（napi_exports.cpp）       │
├───────┼──────────────┼────────────────────────┤
│       │              │                        │
│  ┌────┴─────┐  ┌─────┴──────┐  ┌──────────┐  │
│  │ Rust     │  │ C++ 网络   │  │ Payload  │  │
│  │ kdc_core │  │ UDP/TCP/   │  │ 传输     │  │
│  │(packet_  │  │ TLS(BearSSL│  │          │  │
│  │ io,cert) │  │ /证书生成) │  │          │  │
│  └──────────┘  └────────────┘  └──────────┘  │
│              Native C++ 层                    │
└─────────────────────────────────────────────┘
```

- **Native C++（NAPI）**：UDP 发现、TCP 服务端/连接、BearSSL 0.6 TLS 握手、自签证书生成、packet 序列化、payload 传输
- **Rust staticlib**（`kdc_core`）：`packet_io` + `cert_util` — 从 C++ 迁移以获得内存安全（R1）
- **ArkTS**：插件框架（注册表驱动）、UI、业务逻辑

## 技术栈

| 层 | 技术 |
|---|---|
| UI / 业务 | ArkTS（OpenHarmony API 26，Stage 模型） |
| Native 网络 | C++20, BearSSL 0.6, cJSON（vendored） |
| 核心工具 | Rust（serde, serde_json, sha2, base64） |
| 构建 | hvigorw（HarmonyOS）, CMake（native）, cargo（Rust） |
| 协议 | KDE Connect 协议 v8 |

## 构建

### 前置条件

- HarmonyOS Command Line Tools（`/opt/command-line-tools`）
- OpenHarmony SDK（`/opt/ohos-sdk`）
- Rust 工具链（用于 `kdc_core` staticlib）：

  ```bash
  rustup target add aarch64-unknown-linux-ohos x86_64-unknown-linux-ohos
  ```

  缺 `cargo` 时 CMake 配置阶段会直接给出安装指引；交叉工具链细节见 `entry/src/main/cpp/rust/README.md` §5b。
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
tests/run.sh   # 30 个 host 侧单元/集成测试
```

## 项目结构

```
kdeconnect-harmony/
├── entry/src/main/
│   ├── cpp/              # Native C++（NAPI）
│   │   ├── net/          # UDP 发现、TCP 服务端、TLS 引擎、NAPI 桥（napi_exports.cpp）
│   │   ├── payload/      # Payload 传输
│   │   ├── napi_init.cpp # 模块注册与 NAPI 导出表
│   │   └── rust/         # Rust staticlib 集成（kdc_core：packet_io + cert_util）
│   ├── ets/
│   │   ├── plugins/      # 10 个插件（注册表驱动）
│   │   ├── net/          # PacketRouter
│   │   ├── kdeconnect/   # NetworkPacket、协议类型
│   │   └── pages/        # UI（Index.ets）
│   └── module.json5      # 权限、abilities
├── tools/                # sign-debug.sh, check-encoding.py, sync-revision.sh
├── devdocs/              # 开发者指南（CPP_GUIDE, ARKTS_GUIDE, PROCESS）
├── LICENSE               # GPL-3.0
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

## 开发

### 新增插件

1. 创建 `entry/src/main/ets/plugins/MyPlugin.ets`，继承 `PluginBase`
2. 声明 `supportedPacketTypes`（incoming）和 `outgoingPacketTypes`（outgoing）
3. 实现 `onPacketReceived()`，可选实现 `onCreate()`/`onDestroy()`
4. 在 `PluginRegistry`（`Index.ets`）中注册
5. 框架自动处理能力协商和包路由

### 编码规范

- C++：见 `devdocs/CPP_GUIDE.md`
- ArkTS：见 `devdocs/ARKTS_GUIDE.md`
- 工作流：见 `devdocs/PROCESS.md`
- 所有文本文件必须是合法 UTF-8（由 `tools/check-encoding.py` pre-commit hook 强制）

## 许可证

GPL-3.0 — 与上游 KDE Connect 一致。见 [LICENSE](LICENSE)。

## Agent 分工

本项目由人类作者提出需求与关键裁决；日常实现、评审与验证由多个 AI Agent 分工完成（协作规则与踩坑记录见 `devdocs/PROCESS.md`）。

| 角色 | 承担 | 说明 |
|---|---|---|
| **omp**（Linux 侧） | C++ native 全栈、Rust 迁移、host 测试与真桌面验证、git 单写者 | UDP/TCP/TLS(BearSSL)/证书、NAPI 桥、payload 传输、`kdc_core`（R1 Rust 迁移）；提交与推送只由本侧执行 |
| **DevEco Code**（Win10 侧） | ArkTS：UI、插件框架与 10 个插件 | 在 DevEco Studio 中构建，真机 / 模拟器验证 |
| **CodeArts** | 流程总指挥：任务派发、代码评审、裁决与推送时点 | 维护 `devdocs/PROCESS.md` 与协作台账 `AgentsConversion/` |
| **AtomCode** | 独立复核（评估方，不直接改码） | 迁移方案、全量代码审查、验收判据 |
| **ZCode** | 早期 C++/native 与构建奠基 | 后交棒 omp |

两侧通过 Syncthing 共享工作区协作：**同一文件不双写**；`.git` 只存在于 Linux 侧（Win10 侧用
`AgentsConversion/GIT_REVISION.md` 对齐「文件对应哪个提交」，编码守卫拦掉乱码）。

## 致谢

- [KDE Connect](https://kdeconnect.kde.org/) — KDE 社区的原始项目
- [kdeconnect-android](https://invent.kde.org/network/kdeconnect-android) — Android 参考实现
- [kdeconnect-kde](https://invent.kde.org/network/kdeconnect-kde) — 桌面参考实现
- [kdeconnect-meta](https://invent.kde.org/network/kdeconnect-meta) — 协议 schema
