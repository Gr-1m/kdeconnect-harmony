# `rust/full` — 全 Rust 原生栈

- `core/` = `kdc_native`：协议/TLS/发现/控制链路/payload/栈生命周期；**不依赖 NAPI**，
  可用 `cargo test` 在宿主机跑完整 E2E。
- `napi/` = `kdeconnect_napi`：ohos-rs cdylib，导出 `Index.d.ts` 的 19 个函数；
  事件经 threadsafe function 回到 ArkTS 主线程。

构建入口是 `entry/src/main/cpp/CMakeLists.txt`（hvigor 调 cargo），
行为与验证说明见 `devdocs/FULL_RUST.md`。

Host 测试：

```bash
cargo test -p kdc_native --manifest-path entry/src/main/cpp/rust/full/Cargo.toml
```

模块名必须与 `.so` 文件名一致（`kdeconnect_napi`），见 `napi/build.rs`。
