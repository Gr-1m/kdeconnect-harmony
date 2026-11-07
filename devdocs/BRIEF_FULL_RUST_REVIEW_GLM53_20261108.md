# 评审须知（自包含）— 全 Rust 原生栈独立评审（Omp-GLM5.3 临时会话）

> 你（临时评审会话）不需要了解本项目日常协作形式。**只要读这一份 + 下列材料，按 §5 清单执行即可**。
> 评审对象与命令均在本文件内；除非清单要求，不需要改任何代码。

## 1. 项目一句话

HarmonyOS（API 26）上复刻 KDE Connect 协议的客户端（ArkTS + Native）。
`main` 分支的 Native 层是 **C++ + BearSSL**；被评审分支 `dev/native-rust` 把它**整体换成 Rust**
（ohos-rs + rustls，TLS13/TLS12），输出仍是同一个 `libkdeconnect_napi.so`，**ArkTS 侧契约 `Index.d.ts` 必须零改动**。
本次评审决定：该分支能否在 **0.9.0 之前（拟 0.8.4）** 合并进 `main`。

## 2. 位置与引用

- 仓库：`/home/cagp/WorkSpace2/kdeconnect-harmony`（主工作区，`main`）
- 被评审 worktree：`/home/cagp/WorkSpace2/kdeconnect-harmony-native`（分支 `dev/native-rust`）
- 被评审提交：**`d87fe81`**（`Merge branch 'main' into dev/native-rust`；已 push 双远端 origin/github）
- 对比基线：`main`（C++ 栈，HEAD `c6d62f8` 或更新）

## 3. 必读材料（按序）

1. `devdocs/FULL_RUST.md` — 架构、构建、**行为差异（§3）**、设备证据、风险表 R1–R9、合并顺序
2. `devdocs/FULL_RUST_TEST_CRITERIA.md` — 测试分层 L0–L4、18 用例、**未覆盖项**、判定标准
3. `devdocs/FULL_RUST_REVIEW_REQUEST_20261108.md` — **§4 评审清单（你的作业）**、§5 待决策项、§6 合并顺序
4. `devdocs/DESIGN_S2_NATIVE_CONTRACT_20261107.md` — S2 文件分享 Native 契约（错误码映射）
5. `devdocs/PROTOCOL_AUDIT_FINDINGS_20261107.md` — 协议一致性审计（证书有效期等）
6. 代码（抽读）：`entry/src/main/cpp/rust/full/core/src/{tls,connection,payload,state,discovery}.rs`
7. 对照基线：`git diff main -- entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts`（应为空）

## 4. 环境与命令（均在被评审 worktree 根目录执行）

```bash
cd /home/cagp/WorkSpace2/kdeconnect-harmony-native

# 契约零改动（应无输出）
git diff main -- entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts

# 核心测试（L1/L2；napi crate 的宿主 unit-test 因缺 napi_* 符号无法链接，属预期）
cd entry/src/main/cpp/rust/full && cargo test -p kdc_native && cd -

# 构建（libxml2 soname 兼容层必需；--no-daemon 必需）
export LD_LIBRARY_PATH="$HOME/.local/share/ohos_libshim${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
hvigorw --no-daemon assembleHap
```

- 设备冒烟（可选）：模拟器 `127.0.0.1:5555`（折叠）/`5557`（平板）/`5559`（手机）；
  `HDC_TARGET=127.0.0.1:5555 tools/sign-debug.sh all` 后 `tools/launch-app.sh`。
- 全量门禁聚合：`cd entry/src/main/cpp/tests && ./run.sh`。

## 5. 评审清单（逐项留证，作业清单）

1. `Index.d.ts` 与 main 的 diff 为空；
2. `./run.sh` 全绿；`cargo test -p kdc_native` 全过；
3. `assembleHap` 成功；HAP 内 `libs/<abi>/libkdeconnect_napi.so` 的 `NEEDED`
   （`libace_napi.z.so, libhilog_ndk.z.so, libc.so`）与导出符号正确；
4. 抽读：`tls.rs`（verifier/占位 CA/TLS 版本）、`connection.rs`（角色/fail-closed/事件顺序/证书不符去重）、
   `payload.rs`（超时/取消/spool）、`state.rs`（钉扎/限流/断链语义）、`discovery.rs`；
5. 对照 `FULL_RUST.md §3` 逐条确认与 C++ 基线一致或有据可查的偏离；
6. 设备冒烟（可选）：与真实 KDE 桌面连接/配对/收一个文件；
7. 复核风险表 R1–R9 是否漏项/低估（重点 R1 Android 对端、R3 线程模型、R4 构建链依赖）。

## 6. 交付与约束

- 报告写入 `devdocs/REVIEW_FULL_RUST_GLM53_20261108.md`：
  **结论（Approved / Conditional / Rejected）**、清单逐项证据、发现的问题按 P0–P3 分级、对 R1–R9 的复核意见；
- 完成后发消息文件 `AgentsConversion/MSG189FromOmp_GLM53_TO_ATOMCODE.md`（或按你们会话的约定通知总指挥）；
- **只读评审**：不改代码、不 commit、不 push；需要跑构建/设备命令可以，但须在报告中给出证据；
- **截止 2026-11-10**；本临时会话评审结束后关闭。

## 7. 判定口径

- **Approved**：清单 1–5 全过、无 P0/P1、风险表可接受；
- **Conditional**：有 P1 或条件项（列出闭合条件与期限，例如 R1 需 Android 实测、R3 需压测）；
- **Rejected**：存在 P0 或契约/安全不可接受项（必须附复现证据）。
