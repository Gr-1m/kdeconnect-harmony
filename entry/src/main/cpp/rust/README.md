# R1：`packet_io` / `cert_util` → Rust 迁移报告

> 任务书：`AgentsConversion/MSG93_TO_CODEARTS.md`（AtomCode 起草，CodeArts 审核，用户授权）。
> 分支：`dev/rust-r1`（从 `dev/zcodeinit` 的 `354ccef` 切出）。**不触碰 NAPI 与 TLS**（按任务书边界）。

## 1. 产物与结构

```
entry/src/main/cpp/
├── rust/
│   ├── kdc_core/            # Rust crate（staticlib + rlib）
│   │   ├── Cargo.toml       # 依赖仅 serde/serde_json/sha2/base64（无 ring/aws-lc/TLS）
│   │   └── src/
│   │       ├── lib.rs       # #![deny(unsafe_code)]；模块声明
│   │       ├── packet.rs    # packet_io 的 Rust 实现（455 行，14 个测试）
│   │       ├── cert.rs      # cert_util 的 Rust 实现（10 个测试）
│   │       └── ffi.rs       # C ABI 边界（全 crate 唯一 unsafe 处，逐项注释）
│   ├── wrappers/            # OHOS 交叉工具链：{aarch64,x86_64}-linux-ohos-clang、ohos-ar、.cargo/config.toml
│   └── build_host.sh        # host 侧构建 .a（run.sh 调用）
├── net/cert_util.cpp        # **薄 shim**（原 C++ 实现已删除，公开签名逐字不变）
├── net/packet_io.cpp        # **薄 shim**
└── net/rust_shim.h          # C ABI 声明 + 「容量不足则扩容重试」调用助手
```

**FFI 约定**（`ffi.rs` 头注释）：调用者分配缓冲 + 返回「所需长度」重试；负数 = 语义失败；
Rust 不返回堆指针 ⇒ 无跨堆释放问题。多字段输出用 NUL 分隔单缓冲（`deviceId\0deviceName\0deviceType\0`）。

## 2. 验收判据逐条对照（MSG93 §5）

| # | 判据 | 结果 |
|---|---|---|
| 1 | `cargo test` 全绿（含移植的既有断言 + ≥2 组 golden 向量） | ✅ **24 passed / 0 failed**（14 packet + 10 cert）；golden：带 ts=1745000000 → `D0223B99`，ts=0 → `41F0A922`、ts=-7 → `CBC47CA2`，均取自真实 C++ 打印 |
| 2 | `tests/run.sh` 全绿 | ✅ **19 单元 + 3 net + 6 payload = 28 cases, 0 failed**（用 Rust 实现、经 shim 驱动原 C++ 用例） |
| 3 | `hvigorw assembleHap` 通过（arm64-v8a + x86_64） | ✅ BUILD SUCCESSFUL；`entry/.cxx/.../{arm64-v8a,x86_64}/rust-target/<triple>/release/libkdc_core.a` 由 CMake `add_custom_command` 产出并链入 `.so` |
| 4 | `.h` 零改动（`git diff` 为空） | ✅ `packet_io.h` / `cert_util.h` 均无 diff |
| 5 | spike 报告 + 差分对照 | ✅ 本文件 + **~7900 组与迁移前 C++ 实现的逐字节差分**（见 §3） |

## 3. 行为对照证据（关键）

1. **差分测试**（临时 CLI 在 /tmp，未入库）：Rust 侧与**真实 C++ 实现**同输入逐字节比对 **7896 组**：
   base64 202、derToPem 1500、pemToDer 950、extractSpki/DN 4542、verificationCode 702；
   输入含随机字节/长度、TLV 长度字段变异、截断、随机嵌套 DER、PEM 空白/`=`注入/双段/大小写、i64 极值时间戳。
2. **packet 侧 golden**：真实 C++ harness 与 Rust 同输入 12 行输出 **DIFF IDENTICAL**，并固化为断言
   `build_identity_matches_cpp_byte_for_byte`（防将来 `serde_json` 版本漂移改变输出）。
3. **既有 15 个 C++ 用例的断言全部移植**到 Rust（`tests/test_main.cpp` 未改动，且仍全绿）。

## 4. 与 .h 注释/任务书不一致处（以 C++ 为准，已记录）

| 项 | 实际情况（C++ 实测） |
|---|---|
| `computeVerificationCode` 的 timestamp | **无条件**追加十进制串（ts=0 → `"0"`、ts=-7 → `"-7"`）；任务书写的"仅当 timestamp>0"与 C++ 不符 —— **C++/KDE 的实际行为才是对的**（KDE `verificationKey()` 用 `m_pairingTimestamp`，未配对时为 0 并照样拼接） |
| `pemToDer` 宽容度 | 跳过 body 内**任意位置**的 `=`、`\n`、`\r`、空格、制表符；遇非法字符整体失败；取首个 `BEGIN` 段（BEGIN 前可有杂音） |
| `readTLV` | 长形长度 n 必须 1..=4（`0x80` 不定长 → 失败）；越界/溢出 → 失败；至少 2 字节 |
| 可选 `[0] version` | 按 tbs body **首字节**原始比较 `== 0xA0` 探测 |
| `derToPem`（空 DER） | 仍输出 BEGIN/END 头尾（无 body 行） |
| `parseIdentity` | 结尾强制 `isValidDeviceId`（.h 注释未提）；根必须是 object 且 `type` 恰为 `kdeconnect.identity`；deviceId 校验失败时 C++ 会部分回填 name/type/tcpPort（Rust 返回 None 不回填）—— 已核对全部调用方均为「仅 true 时消费」⇒ **不可观测** |
| `tcpPort`/`payloadTransferInfo.port` 越界 | C++ 是 `static_cast<uint16_t>`（UB），Rust 饱和；实际输入均在合法域 |

## 5. 工具链结论（可复用）

- **无需 nightly**：`aarch64-unknown-linux-ohos` / `x86_64-unknown-linux-ohos` 都是 tier-2 预编译 target，
  `rustup target add` 直接拿到 std。
- **rustup 环境坑**：本机 `~/.cargo/bin` 曾存在无默认工具链的 rustup shim，会遮蔽可用的系统工具链
  （`rustup could not choose a version of ...`）⇒ 已 `rustup default stable`（1.98.1，与系统同版）修复。
- **cargo 的 `linker` 相对路径不可依赖**（实测：既非 cwd 也非 config 目录）⇒ CMake 里用
  `CARGO_TARGET_<TRIPLE>_LINKER`（绝对路径）+ `AR_<triple>`（PATH 上的 `ohos-ar`），见 `wrappers/` 说明。
- `panic = "abort"`（release）避免 OHOS sysroot 缺 libunwind 的依赖；wrapper 另补 `-L<llvm/lib/<arch>-linux-ohos>`。

## 5b. 工具链 spike 实测（2026-09-13，独立 agent 复核）

**链接验收**（每个 ABI：`cargo build --release --target <triple>` → 用 wrapper 作为 linker 把 `.a` 静态链进最小 C 程序）：

| ABI | 结果 | ELF 检查 |
|---|---|---|
| aarch64-unknown-linux-ohos | ✅ link exit 0，`ok_aarch64` | ELF64/AArch64/DYN，`NEEDED=[libc.so]`，Rust 符号全部存在 ⇒ **无 unwinder 依赖**（`panic=abort` 生效） |
| x86_64-unknown-linux-ohos | ✅ link exit 0，`ok_x86_64` | ELF64/X86-64/DYN，`NEEDED=[libc.so]`，4/4 符号存在 |
| 附：全静态 | ✅ `-static` 亦可（sysroot 有 libc.a/libdl.a/libm.a） | Type EXEC，0 NEEDED |

**rustup 安装（user-level，未动系统包）**：`rustup-init -y --profile minimal --no-modify-path --default-toolchain stable` → `rustup target add {aarch64,x86_64}-unknown-linux-ohos`；
rustup 1.29.1 / stable = 1.98.1（与本机系统 rustc 同版，无版本回退）。

**踩坑（实测，非推测）**：
1. **cargo 不按文档字面解析相对 `linker` 路径**：config 里写 `../wrappers/xxx` 时，cargo 解析到的既不是 cwd 也不是 config 目录（实测落到 `/tmp/kdc-r1-spike/../wrappers/xxx`）；写裸名字也**不走** config 所在目录 ⇒ **裸名字 + PATH** 才是可搬迁的做法（wrapper 与 config 头注释均记录）。
2. PATH 缺 wrapper 时的报错很迷惑（`linker 'aarch64-linux-ohos-clang' not found`）⇒ 头注释里都写了怎么设。
3. `rust/wrappers/` 是 `rust/kdc_core/` 的**兄弟目录**，cargo 不会自动发现该 config ⇒ 要么把 wrappers 放进 PATH（本仓库做法），要么显式 `--config`。
4. wrapper **不加** `-L<llvm/lib/<arch>>`：实测 clang driver 会自行 `-l:libunwind.a` 并从自带 runtime 目录解析；加了 `-L` 还会让 `-c` 编译报 `-Wunused-command-line-argument`（破坏 `-Werror` 构建）。
5. **`.a` 的产出既不经过 linker、也不需要外部归档器**：`crate-type=["staticlib"]` 由 rustc **进程内归档** —— rustc 1.98.1 实测：不给任何 `AR_*` 也产出 `.a`，且与 `AR=<工具链 llvm-ar>` 时**字节数完全相同**（见 §5c）；linker 只在 rustc 需要**链接可执行/动态库**时才用得上，而设备侧 `.so` 由 CMake 的 OHOS clang 链接 ⇒ 故 `-L` 取舍与 wrapper 都不影响 hvigor 产物（双 ABI 均产出 `.a` 并链入 `.so`，已实测）。

## 5c. hvigor 集成的跨平台化（2026-09-14，为「合回主线不打断 Win10 DevEco 构建」）

原先 CMake 的 Rust 步骤是 **POSIX-only**：`COMMAND cmake -E env "PATH=<rust/wrappers>:$ENV{PATH}" AR_<triple>=ohos-ar CARGO_TARGET_<TRIPLE>_LINKER=<wrapper> cargo build …`
—— 三处假设在 Windows 上都不成立：PATH 分隔符应为 `;`、wrapper 是 `#!/bin/sh` 脚本、`ohos-ar` 同样是脚本。
合回主线后 DevEco/hvigor 走到 cargo 必失败（表现为 CMake 配置阶段找不到命令/链接器）。

现改为**只调 cargo**（不改 PATH、不依赖 sh、不设 AR/linker）：

```cmake
find_program(RUST_CARGO_EXECUTABLE cargo)      # 缺失 ⇒ FATAL_ERROR + rustup 安装指引
add_custom_command(OUTPUT ${RUST_LIB}
    COMMAND ${RUST_CARGO_EXECUTABLE} build --release --target ${RUST_TARGET}
            --target-dir ${RUST_TARGET_DIR} --manifest-path ${RUST_CRATE_DIR}/Cargo.toml …)
```

**为什么这样就够（均为实测，非推断）**：
- **linker 用不上**：`crate-type=["staticlib"]` 不链接；设备侧 `.so` 由 CMake 的 OHOS clang 链接（§5b 第 5 条）。
- **AR 用不上**：rustc 1.98.1 对 staticlib **进程内归档** —— 不给任何 `AR_*` 也产出 `.a`，且与
  `AR=<工具链 llvm-ar>` 时**字节数完全相同**（aarch64 23999596 / x86_64 23252468，两 ABI 各验）。
- **净室验证（2026-09-14）**：全新 worktree 里 `hvigorw --no-daemon assembleHap` ⇒ BUILD SUCCESSFUL；
  双 ABI `.a` 由本集成产出、大小与验收证据一致；未 strip 的 `.so` 里可见 `kdc_*`（C ABI）与 Rust v0
  mangled 符号 `_RNCNvNtCsb9jk9Vb6IGI_8kdc_core3ffi18kdc_build_identity0B5_` ⇒ 确实链进了 Rust（非残留）。

⇒ 合回后 Win10/DevEco 侧唯一前提是 **PATH 上有 cargo**（`rustup-init -y` + `rustup target add aarch64-unknown-linux-ohos x86_64-unknown-linux-ohos`）；
缺失时构建直接给出上面那句安装指引，而不是晦涩报错。`rust/wrappers/` 与其 `.cargo/config.toml` 仅保留给
「手动交叉链接冒烟」（需要 rustc 真正链接可执行/动态库时）。

## 6. 已知限制 / 后续

1. **首次构建需要网络**（`cargo fetch` 拉 serde/serde_json/sha2/base64）；之后可离线。
2. `.a` 体积约 23–24 MB（std 静态进库，最终 `.so` 只取用到的成员；如需可加 `strip`/`-C lto` 优化）。
3. R1 **只迁纯函数**：TLS/NAPI/网络栈仍在 C++（按任务书边界）；未验证 rustls/ring client-auth（PROCESS §8 的 B 路线前提）。
4. 后续若要扩面：建议先做 `net_util`（isPrivateIpv4）这类零依赖模块，再评估 TLS。

—— Native（omp）
