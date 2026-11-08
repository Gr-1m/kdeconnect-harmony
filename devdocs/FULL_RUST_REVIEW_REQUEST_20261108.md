# 评审请求：全 Rust 原生栈（`dev/native-rust`）

- 请求人：Omp-Native
- 日期：2026-11-08
- 审议对象：`dev/native-rust`（worktree `/home/cagp/WorkSpace2/kdeconnect-harmony-native`）
- 状态：**可用态候选；不合并、不排期，由用户拍板**（MSG178 §3.4）
- 前提：`Index.d.ts` 契约零改动；`main` 保持 C++ 栈；`backup/main-cpp` 保留最后 C++ 快照

## 1. 交付物索引

| 文档/产物 | 内容 |
|---|---|
| `devdocs/FULL_RUST.md` | 架构、构建、行为差异、设备证据、风险表、合并顺序 |
| `devdocs/FULL_RUST_TEST_CRITERIA.md` | **测试口径**：分层/用例清单/覆盖矩阵/未覆盖项/判定标准/复现环境 |
| `devdocs/DESIGN_S2_NATIVE_CONTRACT_20261107.md` | S2 Native 契约（两栈通用；实现暂缓待用户裁决） |
| `entry/src/main/cpp/rust/full/{core,napi}` | 源码（无 NAPI 依赖的 core + ohos-rs cdylib） |
| `entry/src/main/cpp/CMakeLists.txt` | 仅调 cargo，输出 `libkdeconnect_napi.so` |
| `entry/src/main/cpp/tests/run.sh` | 门禁：cargo test + NAPI check + 注入契约 |
| `.github/.gitcode workflows/native-tests.yml` | CI 改为 Rust 门禁 |

## 2. 测试口径摘要

见 `FULL_RUST_TEST_CRITERIA.md`。关键数字：

- L0：`kdc_core` 46 passed（含与 C++ 基线的 7896 组逐字节差分，R1 历史证据）；
- L1：`kdc_native` 19 unit passed；
- L2：host 双栈 E2E 1 passed（正向连接/配对/200KB payload + **CN 不符 / 钉扎不符两条负路径**）；
- L3：ohemu 平板 5555 ↔ 真实 KDE：TLS/identity/配对（码一致）/桌面→平板 64KiB 落盘；
- L4：`hvigorw assembleHap` 成功，双 ABI `.so` 进 HAP，`napi_register_module_v1` 与模块名正确；
- 门禁：`run.sh` PASS（含 `Index.d.ts` 契约检查所需的注入契约检查）。

复跑命令：

```bash
cd entry/src/main/cpp/tests && ./run.sh
hvigorw --no-daemon assembleHap
git diff main -- entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts   # 预期为空
```

## 3. 风险表

| # | 风险 | 影响 | 可能性 | 证据/现状 | 缓解 | Owner |
|---|---|---|---|---|---|---|
| R1 | Android 对端兼容（客户端证书 CA 列表过滤、TLS 套件） | 高 | 中 | 仅 Qt/OpenSSL 实测；已加占位 CA 名 | 在 S4/真机窗口与 Android 对端实测；必要时调 rustls 配置 | Omp-Native |
| R2 | OHOS 运行时 crypto（ring）行为 | 高 | 中 | 设备上真实 TLS 握手成功（ECDHE/ECDSA/AES-GCM 已实际运行） | 黄金向量矩阵 + 重复握手/大文件回归 | Omp-Native |
| R3 | 线程模型（每连接/每 payload 一线程）在低端机/高并发下的资源 | 中 | 中 | 未压测 | 真机压测；必要时改事件循环/线程池 | Omp-Native |
| R4 | 构建链变更（CMake 调 cargo；CI/DevEco 需 Rust 工具链） | 中 | 高 | 本机双 ABI 已验证；Win10/其他 CI 未验 | README/CI 注明依赖；首次构建需网络 | AtomCode/Omp-Native |
| R5 | 492 个 C++/vendor 文件删除 vs main 持续 C++ 修复 | 中 | 中 | main `e896b0f` 已修 C++ 证书；Rust 已对齐 | 先提交本分支再 merge main；冲突以 Rust 为准；`backup/main-cpp` 兜底 | AtomCode |
| R6 | 事件/错误码行为差异（如失败路径重复 error） | 中 | 中 | 负路径测试发现钉扎失败曾派发两次 error，已修 | 继续用负路径用例覆盖；设备 A/B 对照 | Omp-Native |
| R7 | `share/sftp/digitizer` 等后续功能只在 C++ 实现 | 中 | 中 | S2 契约已冻结在即；实施栈待用户裁决 | 契约栈无关；实现前定栈 | 用户 |
| R8 | 未做 C++ vs Rust 同场景 A/B、fuzz、长稳 | 中 | 中 | 见测试口径 §4 | 合并后 0.9.0 窗口补 | Omp-Native |
| R9 | 回退复杂度 | 低 | 低 | `main` 仍为 C++；备份分支在 | 保留 `backup/main-cpp`；回退 = 切 main | AtomCode |

## 4. 评审清单（建议 Reviewer 逐项执行）

1. `Index.d.ts` / `oh-package.json5` 与 main 的 diff 为空；
2. `cd entry/src/main/cpp/tests && ./run.sh` 全绿；
3. `hvigorw --no-daemon assembleHap` 成功；检查 HAP 内 `libs/<abi>/libkdeconnect_napi.so` 的
   `NEEDED`（`libace_napi.z.so, libhilog_ndk.z.so, libc.so`）与导出符号；
4. 代码抽读：`core/src/tls.rs`（verifier/占位 CA）、`connection.rs`（角色/fail-closed/事件顺序）、
   `payload.rs`（超时/取消/spool）、`state.rs`（钉扎/限流/断链语义）；
5. 对照 `FULL_RUST.md` §3（协议/安全行为）逐条确认与 C++ 基线一致或有据可查的偏离；
6. 设备冒烟：`HDC_TARGET=127.0.0.1:5555` 安装/启动 → 与真实 KDE 连接/配对/收一个文件；
7. 就 §5 决策项给出结论（Approved / Conditional / Rejected）。

## 5. 待决策项（提交用户/AtomCode）

1. 是否**批准进入合并流程**（评审通过后仍需用户最终拍板 merge）；
2. 是否要求 **C++ vs Rust 同场景 A/B**（同模拟器、同对端）作为合并前置；建议作为后置项
   （Rust 已独立跑通，A/B 主要用于观感/性能对照）；
3. 是否要求 **Android 对端实测**作为前置；建议合并后与 S4 真机窗口一起做；
4. S2 实施栈（用户已裁：只定契约、实现等栈裁决）。

## 6. 合并顺序（供 AtomCode 执行）

1. 提交本分支（clean cutover 单独一次提交，便于回退）；
2. `git merge main`（或 rebase）解决 AGENTS/CMake/workflows 冲突；C++ 文件删除以 Rust 为准；
3. 复核 `Index.d.ts` 零改动 → 跑 `run.sh` + `assembleHap` + 平板/手机冒烟；
4. push 双远端；`backup/main-cpp` 冻结（main 已无 C++ 栈时钩子自动停）。

## 7. 回退

- 合并前：`main` 与 `backup/main-cpp` 均为 C++，随时可用；
- 合并后：revert 该 clean cutover 提交即可回到 C++（或直接切 `backup/main-cpp`）。

—— Omp-Native，2026-11-08
