# SETUP_NAPI_RS — ohos_napi_rs 环境搭建标注（仓库外依赖，换机/协作必读）

> 2026-10-11，AtomCode（qwen3.8-27b）。
> **用户裁决（2026-10-11）**：① `ohos_napi_rs` **保持仓库外**（仓库范围只有 PreDev 工程），但必须标注好安装/环境搭建，防换环境、防协作开发丢失依赖；② 工程内正式接入**不在现在**，等 **0.8.0 稳定版**后，在 **0.8.1 → 0.9.0** 版本窗口内做。
> 冒烟证据来源：`/home/cagp/WorkSpace2/napi_smoke/`（本实例 2026-10-11 真跑）。

## 1. 仓库外依赖清单（本机布局）

| 依赖 | 位置 | 来源 | 版本 |
|---|---|---|---|
| `ohos_napi_rs`（官方 fork，gitee 仓**已归档**勿用） | `/home/cagp/WorkSpace2/ohos_napi_rs/` | `git clone https://gitcode.com/openharmony-tpc/ohos_napi_rs.git` | napi 2.16.11（workspace rust-version 1.65，本机 rustc 1.98.1 满足） |
| 冒烟 crate（可删除重造，留作证据/参照） | `/home/cagp/WorkSpace2/napi_smoke/` | 本实例所建 | libnapi_smoke.so 627K |

**两个位置都在仓库外、在 Syncthing 同步范围外（WorkSpace2 顶层）**：换机 / 新协作者 = 按 §2 重装 + 按 §4 复验冒烟，**不要假设路径存在**。

## 2. 安装步骤（新环境/新协作者照此执行）

前置：rustup stable ≥ 1.78 + `rustup target add aarch64-unknown-linux-ohos`（本机已装）；OHOS SDK 26（`/opt/ohos-sdk`）；cmake（`aws-lc-sys` 构建需要，本机 4.4.4）。

```bash
# 1) clone 官方源（放仓库外；路径可自定，记下即可）
git clone https://gitcode.com/openharmony-tpc/ohos_napi_rs.git ~/WorkSpace2/ohos_napi_rs

# 2) 冒烟 crate（照官方 testcode 最小化，三行 path 依赖 + cdylib）
mkdir -p ~/WorkSpace2/napi_smoke/src
# Cargo.toml / build.rs / src/lib.rs 内容见 §3；.cargo/config.toml 的 linker 用绝对路径指向
# 仓库内 R1 已验证的 wrapper：entry/src/main/cpp/rust/wrappers/aarch64-linux-ohos-clang
# （R1 实测教训：cargo 不按文档字面解析相对 linker 路径 ⇒ 一律绝对路径）

# 3) 交叉编译（预期 5s 级，2 个无害 cfg warning）
cd ~/WorkSpace2/napi_smoke
cargo build --release --target aarch64-unknown-linux-ohos
```

正式接入工程时（0.8.1→0.9.0 窗口内）：`.so` 放 `entry/libs/arm64-v8a/`，ArkTS 侧**手写** `index.d.ts` 声明（官方 build/macro **不自动生成** d.ts，已核本仓无写出逻辑，README 明示手写）。

## 3. 冒烟 crate 最小内容（可复制重造）

`Cargo.toml`：
```toml
[package]
name = "napi_smoke"
version = "0.1.0"
edition = "2021"

[dependencies]
napi = { path = "/home/cagp/WorkSpace2/ohos_napi_rs/crates/napi", default-features = false, features = ["napi_ohos"] }
napi-derive = { path = "/home/cagp/WorkSpace2/ohos_napi_rs/crates/macro", features = ["ohos-explicit-register"] }

[build-dependencies]
napi-build = { path = "/home/cagp/WorkSpace2/ohos_napi_rs/crates/build" }

[lib]
name = "napi_smoke"
crate-type = ["cdylib"]
```

`build.rs`：`fn main() { napi_build::setup(); }`

`src/lib.rs`：
```rust
use napi_derive::napi;

#[napi]
pub fn add(a: i32, b: i32) -> i32 { a + b }
```

`.cargo/config.toml`：
```toml
[target.aarch64-unknown-linux-ohos]
linker = "/home/cagp/WorkSpace2/kdeconnect-harmony/entry/src/main/cpp/rust/wrappers/aarch64-linux-ohos-clang"
```

## 4. 冒烟验收标准（复验时逐项核对）

| 项 | 预期 |
|---|---|
| 构建 | `Finished release`，exit 0，仅 cfg 类 warning |
| 产物 | `libnapi_smoke.so`，ELF 64-bit ARM aarch64 |
| NEEDED | `[libace_napi.z.so, libc.so]`（前者 = OHOS ArkTS NAPI 运行时库，必须出现） |
| 动态导出 | `napi_register_module_v1` 可见（`llvm-nm -D --defined-only`） |
| d.ts | 不生成（预期行为，ArkTS 侧手写声明） |

2026-10-11 实测全过；clone 与冒烟 crate 从 `/tmp` 迁到上述稳定路径后**重跑复验通过**（路径依赖已验证可搬迁）。

## 5. 接入排期（用户裁决）

- **窗口**：0.8.0 稳定后 → 0.8.1/0.9.0 之间（用户 2026-10-11 原话：「等双方 0.8.0 稳定版，然后从 0.8.1 → 0.9.0 之间做这个工作」）。
- 前提依赖：G2 最后一项 **crypto 运行时验证**（ring/rustls 在 OHOS musl 上的真实行为）须在接入前完成，见 `REVIEW_RUST_VS_CPP_20261011.md` §三。
- 接入时的车道纪律照旧：ArkTS 侧接线归 DevEco，提交归 Omp，评审归 AtomCode；本文档随接入 PR 更新为「已接入」状态。

## 6. 协作提示（给未来接手的人）

1. 看到 `Cargo.toml` 里 `path = "/home/cagp/WorkSpace2/ohos_napi_rs/..."` 而路径不存在 → **不是 bug，是仓库外依赖**，按 §2 重装。
2. 不要把 `ohos_napi_rs` vendor 进仓库（用户已裁决保持仓库外）；如将来改判，须用户重新裁决 + 更新本文档。
3. Win10 侧暂不可用 Rust 交叉链（R1 已知限制：DevEco 侧仅要求 PATH 有 cargo 供 host 测试；ohos 交叉在本机 CachyOS 做）——接入 0.8.1/0.9.0 时若 Win10 要跑 Rust 构建，先按 R1 README §5c 评估。

—— AtomCode（qwen3.8-27b），2026-10-11
