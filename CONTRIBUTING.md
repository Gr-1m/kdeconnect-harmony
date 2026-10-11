# Contributing to KDE Connect HarmonyOS

欢迎贡献 KDE Connect HarmonyOS 移植项目！本文档指导开发者的工作流程。

## 1. 源代码组织

```
entry/src/main/
  ├─ cpp/              # 原生层（C++/Rust/NAPI）
  │  ├─ net/          # 网络栈（UDP 发现 / TCP / TLS）
  │  ├─ rust/         # Rust 迁移（kdc_core staticlib）
  │  ├─ napi/         # NAPI 桥接
  │  └─ tests/        # 原生测试（host + device）
  ├─ ets/             # ArkTS 应用层
  │  ├─ pages/        # 主页（设备列表 / 功能 / 日志）
  │  ├─ plugins/      # 功能插件（mousepad / notification 等）
  │  ├─ components/   # 复用 UI 组件
  │  ├─ state/        # 业务层控制器
  │  └─ model/        # 数据模型 + 存储
  └─ resources/       # 字符串 / 图片
ohosTest/ets/test/    # ArkTS 设备侧测试（hypium）
tools/                # 脚本工具
  ├─ arkts-logic-test.ps1   # Windows 纯逻辑测试
  ├─ arkts-logic-test.sh    # Linux 纯逻辑测试（bun 优先）
  ├─ sign-debug.sh          # 签名+安装+启动
  └─ smoke-ohemu.sh         # ohemu 一键冒烟
```

## 2. 开发约束

### 2.1 协议一致性（必须遵守）
- 所有 NetworkPacket 的 `body` 字段**必须**与 `kdeconnect-meta/schemas/` JSON Schema 一致
- 修改协议前：① 改 schema（`make check` 验证）→ ② 改实现
- 新增 packet 类型：验证码 ± 8 位必须跨端（A1 / KDE / Android）一致

### 2.2 代码风格

**C++**（`entry/src/main/cpp/`）：
- 参考 `devdocs/CPP_GUIDE.md`（类命名 / 异常处理 / 资源管理）
- 线程安全：互斥锁优先，原子操作仅限标志位
- 内存：智能指针，手动 new/delete 须二人审查

**Rust**（`entry/src/main/cpp/rust/kdc_core/`）：
- 参考 `06-coding-standards.md §2`
- 无全局态、无 async；单纯函数式（便于 host 测试）
- `panic = "abort"` release 配置（无展开开销）

**ArkTS**（`entry/src/main/ets/`）：
- 参考 `devdocs/ARKTS_GUIDE.md` + `06-coding-standards.md §3-4`
- 类型化：所有入站 body 经 `TryFrom<Value>` 校验
- 注入约定：契约必入 `check-injection-contract.py`

### 2.3 测试覆盖

- 新增功能**必须**有测试（单测或集成测试）
- 见 `entry/src/main/cpp/tests/` 和 `entry/src/ohosTest/ets/test/`
- 运行：
  ```bash
  # C++ 主机测试（包含 Rust）
  cd entry/src/main/cpp/tests && ./run.sh
  
  # ArkTS 设备侧
  cd entry/src/main && devecocli build --modules entry@ohosTest
  
  # ArkTS 纯逻辑（无需设备，秒级）
  # Windows: tools/arkts-logic-test.ps1
  # Linux:   bun run tools/arkts-logic-test.sh
  ```

### 2.4 安全性

- 入站数据一律验证（size / 格式 / 范围）
- 通网路径：privilege 检查（见 `net/packet_io.cpp`）
- 密钥管理：不硬编码，不本地持久化（除 trusted_devices）
- 新增权限：声明在 `module.json5` + 说明在 commit msg

## 3. 协作流程

### 3.1 分支策略
- `main`：稳定版本（0.x.y）
- `dev/zcodeinit`：开发主线（日常 push）
- `refactor/arkts-*` 等：特性分支（由专项负责人维护）

**推送纪律**：
- 本地提交先 `git commit --no-verify` 则 `pre-commit` 检查编码（禁止非 UTF-8）
- 推送格式：`git push origin <branch>`（非 `--force`，除非领导授权）

### 3.2 代码审查
- 跨车道合并：至少一方评审（AtomCode / CodeArts）
- 新增公开 API：必须有文档注释 + 用例
- 删除/改动既有 API：向后兼容或明确废弃标记

### 3.3 冲突解决
- 同一文件两端改动：read 仓库文件为准（非口头规范）
- 分歧走消息（`MSG<N>`）→ 总指挥裁决 → 记录决策

## 4. 发布流程（0.x.0 版本）

1. **代码冻结**：开发分支冻结 24h，复跑全套件
   ```bash
   LD_LIBRARY_PATH=~/.local/share/ohos_libshim \
     hvigorw --no-daemon assembleHap
   cd entry/src/main/cpp/tests && ./run.sh
   ```

2. **版本号更新**：
   - `AppScope/app.json5`：`versionName` + `versionCode`
   - `entry/oh-package.json5`：`version`
   - `devdocs/CHANGELOG.md`：变更日志

3. **标签 & 同步**：
   ```bash
   git tag -a v0.x.0 -m "Release 0.x.0"
   git push origin main v0.x.0
   git push github main v0.x.0
   ```

4. **真机验收**（见 `devdocs/RUNBOOK_KI1_REAL_DEVICE.md`）：
   - 配对验证码跨端一致
   - 文件传输端到端
   - 控制命令（mousepad / 音量等）
   - 通知同步

## 5. 环境搭建

**Linux 开发环境**：
```bash
# 1. SDKs
  /opt/command-line-tools/  # OHOS 商用 CLT
  /opt/ohos-sdk/            # OpenHarmony SDK（API 26）
  rustup                    # Rust 工具链（stable 1.98+）

# 2. 目标三元组注册
  rustup target add aarch64-unknown-linux-ohos x86_64-unknown-linux-ohos

# 3. libxml2 shim（CLT ld.lld 依赖）
  mkdir -p ~/.local/share/ohos_libshim
  ln -sf /usr/lib/libxml2.so.16 ~/.local/share/ohos_libshim/libxml2.so.2

# 4. 测试工具
  bun install                          # JavaScript 运行时（可选，对标 Node）
  python3 -m venv ~/.kdeconnect-env   # 隔离 Python 环境
```

**Windows DevEco 环境**：
- DevEco Studio 26.0.0+
- 同上 Rust / rustup / targets（仅 napi-rs 相关开发需）

## 6. 常见问题

**Q: 如何在 ohemu 模拟器上验证？**  
A: 使用 `tools/smoke-ohemu.sh`（自动构建 → 签名 → 安装 → 冒烟检查）。若降级 HDS 需 `tools/verify-on-ohemu.sh`。

**Q: 编译报"libxml2.so.2 not found"？**  
A: 见环境搭建第 3 步。构建前确保 `LD_LIBRARY_PATH=~/.local/share/ohos_libshim hvigorw`。

**Q: 如何贡献新插件？**  
A: 参考 `06-coding-standards.md §6 Cookbook`（runcommand 示例）。新增插件需在 `PluginRegistry.ets` 注册。

**Q: 本地测试与 CI 构建不一致？**  
A: 检查编码（UTF-8）和 git 设置（`core.autocrlf`）。Linux：`input`；Windows：`true`。

## 7. 参考

- **协议规范**：`kdeconnect-meta/protocol.md` + `schemas/`
- **设计文档**：`devdocs/` 下各 `DESIGN_*.md`
- **测试**：`docs/` 下旧工作区快照（参考用）
- **上游源码**：`kdeconnect-kde/` / `kdeconnect-android/` / `kdeconnect-ios/`（只读）

## 8. 许可证

本项目采用 **GPL-2.0-or-later**。贡献代码视为同意该许可。  
署名：`SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors`

---

**反馈 & 问题**：在仓库 Issue 或协作消息（MSG*）中报告。

Last updated: 2026-10-11
