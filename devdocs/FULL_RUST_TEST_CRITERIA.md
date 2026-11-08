# 全 Rust 原生栈 — 测试口径说明（Omp-Native，2026-11-08）

> 配套：`devdocs/FULL_RUST.md`（架构/差异/风险）、`devdocs/FULL_RUST_REVIEW_REQUEST_20261108.md`（评审请求）。
> 目的：把「哪些行为被什么测试证明、哪些没有」写清楚，供评审按同一口径复跑/质疑。

## 1. 测试分层

| 层 | 位置 | 命令 | 覆盖对象 | 当前结果 |
|---|---|---|---|---|
| L0 纯函数差分 | `rust/kdc_core` | `cargo test --manifest-path entry/src/main/cpp/rust/kdc_core/Cargo.toml` | 帧切分/identity/证书工具；与 C++ 基线 **7896 组逐字节差分**（R1，历史证据） | 46 passed |
| L1 核心单元 | `rust/full/core` | `cargo test -p kdc_native` | 见 §2 清单（19 个） | 19 passed |
| L2 双栈集成（host） | `rust/full/core/tests/stack_e2e.rs` | 同上（1 个用例、3 个场景） | 两套 Rust 栈真实 TCP/TLS：连接/身份/配对/控制帧/payload + **两条负路径** | 1 passed（3.6s） |
| L3 设备集成（ohemu） | 平板 5555 | `HDC_TARGET=127.0.0.1:5555 tools/sign-debug.sh all` + `tools/launch-app.sh` | init/start、TCP/UDP 1716、与**真实 KDE 桌面** TLS/identity/配对/文件接收 | 见 FULL_RUST §6（人工取证） |
| L4 构建/打包 | 工程根 | `hvigorw --no-daemon assembleHap` | 双 ABI 交叉编译、`.so` 进 HAP、NAPI 注册与契约 | BUILD SUCCESSFUL |
| 门禁聚合 | `entry/src/main/cpp/tests/run.sh` | `./run.sh` | L1 + `cargo check -p kdeconnect_napi` + 注入契约检查 | PASS |

## 2. L1 用例清单（18）

```
cert_ext::extracts_cn_from_generated_cert / rejects_garbage
cert_gen::shift_is_calendar_years / generated_validity_matches_calendar_years
        / leap_day_validity / cert_cn_matches_device_id
discovery::binds_and_sends_loopback / default_port
net_util::port_probe_finds_listener / private_ipv4_boundaries
packet::extracts_frames_from_bytes / identity_roundtrip / oversize_line_is_dropped / packet_metadata
        / device_name_filter_follows_spec
payload::filename_extraction / payload_listener_binds_range
stack::listener_falls_back_when_busy
tls::builds_both_configs
```

L2 单用例包含三个顺序场景（同一进程，避免全局事件回调竞争）：

1. **正向**：A 拨 B（A=TLS server，B=TLS client）→ 双方 `connected`；B→A `kdeconnect.ping`；
   A→B 200KB payload → 字节一致 + `keepPayload` 落盘；`disconnect` 后 B 收 `disconnected`。
2. **负路径 CN 不符**：A 的证书 CN ≠ A 的 identity deviceId → B 收 `error EACCES`（含 "CN"），
   且**不派发** `connected`。
3. **负路径钉扎不符**：B 预置 A 的受信证书为另一张合法证书 → 连接时 B 收
   `error EACCES "certificate mismatch ..."`，且不派发 `connected`。

## 3. 行为覆盖矩阵

| 行为 | 覆盖层 | 证据 |
|---|---|---|
| identity 帧构建/解析、帧切分/超限丢弃 | L0/L1 | 单元 + 7896 组差分 |
| deviceId 正则 / 私网地址策略 / 端口探测 | L1 | 边界用例 |
| 自签证书：CN=deviceId、-1y→+10y 日历语义 | L1 | UTCTime 断言 + openssl |
| TLS 角色（拨号=server / 被拨=client）、双向证书捕获 | L2/L3 | 双栈 E2E + 真实 KDE |
| CN != deviceId fail-closed | L2/L3 | 负路径用例 + 设备日志 |
| TrustStore 钉扎 fail-closed | L2 | 负路径用例 |
| 控制帧收发、事件契约（pairingRequest/connected/packetReceived） | L2/L3 | 设备 ArkTS 收到并渲染 |
| payload 收发 / 进度 / 落盘 / 取消 | L2/L3 | 双栈 E2E + 桌面→平板 Saved |
| 发现广播/收包/去抖、端口缓存 | L1/L3 | 单测 + 设备 1716 监听/广播日志 |
| 生命周期 start/stop/重入 | L2/L3 | 场景切换 + 设备重启 |
| NAPI 契约（19 导出 + 事件字段） | L3/L4 | 设备 ArkTS 零改动跑通；`Index.d.ts` diff 为空 |
| 构建/打包（双 ABI、NEEDED、模块注册） | L4 | `.so` 符号与 HAP 内容检查 |

## 4. 未覆盖 / 限制（评审必须知道）

1. **Android 对端**：未实测。占位 CA 名（防 SunJSSE 过滤）与 TLS 套件兼容性仅有 Qt/OpenSSL 证据。
2. **设备发送方向**：桌面→平板已验证；平板→桌面的 UI/`sendPayload` 路径仅在 host 双栈 E2E 覆盖。
3. **C++ vs Rust 同场景 A/B**（同一模拟器、同一对端）：未做；L1/L2/L3 证明的是 Rust 自身行为。
4. **压测/长稳**：并发连接、连接风暴限流、长时间大文件、后台冻结恢复未做；
   线程模型为「每连接/每 payload 一线程」，未在高并发下测。
5. **fuzz/sanitizer**：无 cargo-fuzz；Rust 侧无 `unsafe`（除 FFI 声明），但解析路径未做畸形输入模糊测试。
6. **构建环境**：宿主机 = CachyOS + rustc 1.98.1；OHOS 交叉用 CLT/OpenHarmony NDK（BiSheng 亦验）。
   Win10/DevEco 侧需 PATH 有 cargo + 两个 ohos target（首次构建需网络）。
7. **运行时 crypto**：设备上仅证明「与 Qt/OpenSSL 的 TLS 握手可完成」（ECDHE/ECDSA/AES-GCM 实际跑过），
   未跑独立黄金向量矩阵。

## 5. 判定标准（评审口径）

- **必须**：`cargo test -p kdc_native`（18+1）与 `entry/src/main/cpp/tests/run.sh` 全绿；
  `hvigorw --no-daemon assembleHap` 成功；`git diff main -- .../Index.d.ts` 为空。
- **应当**：至少一次设备冒烟（init/start + 与真实 KDE 的连接/配对/一次 payload），
  日志可复现（命令见 FULL_RUST §6）。
- **可后置**：Android 对端、设备发送 UI、A/B 对照、压测、fuzz（建议列入合并后 0.9.0 窗口）。

## 6. 复现环境

```text
rustc 1.98.1 / cargo（rustup stable）
targets: aarch64-unknown-linux-ohos / x86_64-unknown-linux-ohos
OHOS SDK: /opt/command-line-tools/sdk/default/openharmony/native（或 /opt/ohos-sdk/26/native）
模拟器: SpatialPad 127.0.0.1:5555（HDC_TARGET 指定；5559 归 ArkTS）
对端: 主机 KDE Connect kdeconnectd（192.168.3.4:1716）
```

> 测试端口约定：L2 用 TCP 18080–18085 / UDP 19171–19176；payload 用 1739+。
> L2 是**单个 `#[test]`**（三场景顺序执行），避免 `events::set_callback` 全局单例在并行测试下互相覆盖。

—— Omp-Native，2026-11-08
