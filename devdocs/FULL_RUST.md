# 全 Rust 原生栈（dev/native-rust）

> 2026-11-07 起，`dev/native-rust` 分支把 native 层从 C++17 + BearSSL 整体切到 Rust。
> 本文件记录架构、构建、验证证据与行为差异；`devdocs/CPP_GUIDE.md` 在本分支只作历史参考。

## 1. 目标与边界

- **目标**：`entry/src/main/cpp/**` 的 native 网络栈全部由 Rust 实现，输出仍是
  `libkdeconnect_napi.so`；ArkTS 侧 `Index.d.ts` 契约零改动。
- **不在本分支改动**：`entry/src/main/ets/**`、资源、ArkTS 侧插件/页面。
- **构建仍由 hvigor/CMake 驱动**：CMakeLists 只负责调用 cargo 并把 `.so` 放到
  `intermediates/cmake/.../obj/<abi>/`，不再编译 C++。

## 2. 目录与分层

```
entry/src/main/cpp/rust/full/
├── Cargo.toml                 # workspace
├── core/                      # kdc_native：可 host 测试，无 NAPI 依赖
│   ├── src/types.rs           # 常量/NetConfig/NetEvent/角色
│   ├── src/events.rs          # 事件出口（回调由 NAPI 注入）
│   ├── src/packet.rs          # 帧切分/identity/packet（复用 kdc_core）
│   ├── src/cert_ext.rs        # X.509 subject CN
│   ├── src/cert_gen.rs        # rcgen 自签 EC P-256（CN=deviceId）
│   ├── src/net_util.rs        # 私网判定 + 端口探测
│   ├── src/tls.rs             # rustls 配置/自定义 verifier/TlsSession
│   ├── src/connection.rs      # 单条控制链路状态机（线程）
│   ├── src/discovery.rs       # UDP 绑定/广播/收包
│   ├── src/payload.rs         # payload 传输任务（独立线程）
│   ├── src/state.rs           # 共享注册表/信任/发现节流/端口缓存
│   ├── src/stack.rs           # 生命周期 + listener/discovery/timer 线程
│   └── tests/stack_e2e.rs     # 两套栈真实 TLS 互联 E2E
└── napi/                      # kdeconnect_napi：ohos-rs cdylib
    ├── build.rs               # napi-build-ohos + 模块名
    └── src/lib.rs             # Index.d.ts 的 19 个导出 + TSFN 事件桥
```

`rust/kdc_core` 保留：packet/cert 纯函数已与 C++ 基线做过 7896 组逐字节差分，
全 Rust 栈直接复用，不重复实现。

## 3. 线程模型（与旧 epoll 栈的对应）

- **1 条控制链路 = 1 个线程**：线程独占 `TcpStream` + `rustls` 会话；读用 50ms
  `SO_RCVTIMEO`，循环同时排空发送队列，避免多写者帧交错。
- **listener 线程**：非阻塞 accept + 50ms 轮询；私网校验、未配对连接上限、
  再交给连接线程。
- **discovery 线程**：非阻塞 UDP 收包；500ms 同设备去抖 + 2s 事件去重。
- **timer 线程**：200ms tick；周期广播（5s×5 → 60s）、DeviceLost（60s）、payload
  tick（超时/回收/进度）。
- 共享状态只在 `state::Shared` 的短临界区里；网络/文件 I/O 不在锁内。
  旧栈的 `connMutex_` → `mu_` 锁序问题在结构上消失。

## 4. 协议/安全行为（与 C++ 基线对齐）

- 拨号方 = **TLS server**，被拨方 = **TLS client**；明文 identity 先于 TLS，
  加密通道内二次交换 identity。
- 对端证书只从 TLS 层取；`CN == deviceId` 在任何 `Connected` 之前 fail-closed。
- TrustStore 钉扎：已登记证书逐字节比较，不符 → `EACCES` +
  `certificate mismatch (device re-pair required)` + 断链。
- 同 `(host, deviceId)` 300ms 限流；同设备存活链路放行（合法替换）。
- 新链路先登记再关闭旧链路；替换不派发 `Disconnected`、不误杀在传 payload。
- 未配对设备只接受 `kdeconnect.pair`；payload 接收要求设备已信任。
- 发现：逐网卡定向广播 + 全局广播兜底；已建链默认不重播。
- 端口未知（0）：后台线程探测 1716–1764，缓存只记验证过的端口，用前复验。
- payload：发送方监听 ≥1739，先发控制帧再 accept；30s 握手/接受超时，
  30s 无进展超时，接收完成后由 `keepPayload/discardPayload` 处置 spool。

## 5. 构建

### 5.1 HAP

```bash
LD_LIBRARY_PATH=$HOME/.local/share/ohos_libshim \
  hvigorw --no-daemon assembleHap
```

CMake 从 hvigor 传入的 `OHOS_SDK_NATIVE` 推导 NDK 根，设置：

- `OHOS_NDK` / `OHOS_NDK_HOME`（napi-build-ohos 链接 `libace_napi.z.so`）
- `CC_<triple>` / `AR_<triple>`（ring 的 C 部分必须用目标 clang）
- `CARGO_TARGET_<TRIPLE>_LINKER` → `rust/wrappers/<triple>-clang`

产物：`entry/build/default/intermediates/cmake/default/obj/<abi>/libkdeconnect_napi.so`
（`NEEDED` = `libace_napi.z.so, libhilog_ndk.z.so, libc.so`；导出
`napi_register_module_v1`；`.init_array` 构造器注册模块名 `kdeconnect_napi`）。

### 5.2 Host 测试

```bash
cargo test -p kdc_native \
  --manifest-path entry/src/main/cpp/rust/full/Cargo.toml
```

覆盖：私网边界、端口探测、DER/CN、identity/packet、证书生成、rustls 配置、
两套栈真实 TLS 互联 + packet + 200KB payload + settle。

### 5.3 手动交叉编译（诊断用）

```bash
NDK=/opt/ohos-sdk/26/native
OHOS_NDK=$NDK OHOS_NDK_HOME=/opt/ohos-sdk/26 \
CC_aarch64_unknown_linux_ohos="$NDK/llvm/bin/clang --target=aarch64-linux-ohos --sysroot=$NDK/sysroot -D__MUSL__" \
AR_aarch64_unknown_linux_ohos="$NDK/llvm/bin/llvm-ar" \
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER=$PWD/entry/src/main/cpp/rust/wrappers/aarch64-linux-ohos-clang \
cargo build --release --manifest-path entry/src/main/cpp/rust/full/napi/Cargo.toml \
  --target aarch64-unknown-linux-ohos
```

## 6. 验证证据（本分支）

| 项 | 结果 |
|---|---|
| `cargo test -p kdc_native` | 18 unit + 1 E2E 全绿（E2E 含正向 + **CN 不符 / 信任钉扎不符两条负路径**） |
| E2E：A 拨 B | TLS 角色 server/client 正确；双方 `connected`；identity/`pairingRequest` 到达 |
| E2E：B→A packet | `kdeconnect.ping` 原样 `packetReceived` |
| E2E：A→B 200KB payload | 双向 finished；sha/字节一致；`keepPayload` 落盘成功 |
| `hvigorw assembleHap` | BUILD SUCCESSFUL；双 ABI `.so` 进 HAP |
| 打包产物 | `libkdeconnect_napi.so` 1.9MB/2.3MB；Rust `napi_register_module_v1` 可见 |
| **ohemu 平板 5555** | `native.init/start` OK；线程 `kdc-listener/kdc-discovery/kdc-timer`；TCP/UDP 1716 监听 |
| **设备 ↔ 真实 KDE** | 手动连接 `192.168.3.4:1716`：TLS server 握手成功，捕获对端证书 CN，`pairingRequest`/`connected`/`packetReceived` 全部送达 ArkTS |
| **配对** | KDE 侧验证码 `D2EE1E3E` 与 App `D2 EE 1E 3E` 一致；`acceptPairing` 后双方 `Paired` |
| **桌面→平板 payload** | 64 KiB 随机文件：`payloadTransfer started/progress/finished`；App 显示 `native-test.bin Saved`（DocumentViewPicker 落盘） |

设备验证中修掉的三个真问题（均保留为回归注释）：

1. `CertificateRequest` 占位 CA 的 DER 长度写错（`30 14` → `30 12`），Qt 回
   `fatal alert: DecodeError`；
2. TSFN 使用 `callee_handled=true`，napi-rs 按 `(err, value)` 调用，ArkTS 的
   `(event)` 收到 `null` → `TypeError: Cannot read property packet of null`；
3. hilog FFI 参数顺序/类型错误（`type, level, domain, tag, fmt`），日志被吞。

多模拟器并存时用 `HDC_TARGET=127.0.0.1:5555 tools/sign-debug.sh all` 指定目标
（5559 留给 ArkTS 车道）。该能力由 **main `528721c`（tools 车道）** 提供；本分支不再
重复改 `tools/**`（曾一度本地实现，已还原以避免双实现/合并冲突）。

## 7. 已知差异/风险

1. **TLS 实现**：rustls + ring 取代 BearSSL；启用了 TLS1.2/1.3。若老 Android 端
   仅支持特定套件，需按实际握手失败日志收敛协议版本/套件。
2. **客户端证书请求**：rustls 的 `CertificateRequest` 使用占位 CA 名
   （CN=KDE Connect），避免 SunJSSE 按 CA 列表过滤导致不出示证书；Qt 不受影响。
3. **ring 运行时**：OHOS musl 上的 crypto 行为已在 host/E2E 验证，设备侧仍需
   一次真实配对/大 payload 的黄金向量回归。
4. **panic=abort**：解析路径禁止 `unwrap`（网络字节全部走 `Result`/`Option`）；
   若未来加入 `unwrap`，恶意包可致进程终止。
5. **线程数**：每条连接/每个 payload 一个线程；移动端并发规模有限，但需在
   真机确认没有线程数/栈空间压力。
6. **C++ 参考代码**：本分支已完成 clean cutover —— `net/ payload/ napi/ json/
   bearssl/`、`napi_init.cpp` 与旧 C++ host 测试已删除；需要对照时查 git 历史
   （`main` 分支仍保留 C++ 栈）。

## 7.5 任务对齐（AtomCode 2026-11-07 下发）

- **S1 ① 证书有效期（Omp-Native）**：main `e896b0f` 修 C++；Rust 侧 `cert_gen.rs` 同步改为
  **日历语义**（`notBefore = now−1 日历年`，`notAfter = now+10 日历年`，2/29 落到 2/28），
  不再用 `±365×years`。证据：单元测试断言 UTCTime `251107000000Z → 361107000000Z`
  （闰日用例 `270228000000Z → 380228000000Z`）+ `openssl x509 -dates`
  = `Nov 7 2025 → Nov 7 2036`（D0=2026-11-07）。
- **S2（D+3 起，Native 侧）**：文件分享闭环的进度/多文件队列/错误码 + `share.request.update`
  收发；等 ArkTS 侧契约定稿（字段、多文件顺序、transferId 语义）后开工。
- S1 ②（在途提交）与 ③（RAG）归 AtomCode；S3/S5–S7 暂不启动。

## 7.9 评审请求材料（AtomCode MSG178 §3.4 / MSG179 §3）

本分支当前状态 = **可用态（候选，不合并、不排期，由用户拍板）**。

- **测试口径**：`devdocs/FULL_RUST_TEST_CRITERIA.md`（分层/用例/覆盖矩阵/未覆盖/判定/复现环境）。
- **评审请求（附风险表）**：`devdocs/FULL_RUST_REVIEW_REQUEST_20261108.md`。
  （注：`devdocs/REVIEW_*.md` 被 .gitignore 排除，故本文件改用 `FULL_RUST_` 前缀以便入库。）

1. **架构/构建/差异/风险**：本文件 §2–§7。
2. **测试与行为对照**：
   - `cargo test -p kdc_native`（18 unit + 1 双栈 E2E）；
   - `entry/src/main/cpp/tests/run.sh`（cargo test + NAPI check + 注入契约）；
   - `hvigorw --no-daemon assembleHap`（双 ABI Rust `.so` 进 HAP）；
   - 设备侧：ohemu 平板 5555 ↔ 真实 KDE——TLS/identity/配对/文件接收（见 §6）；
   - 协议纯函数与 C++ 基线的逐字节差分沿用 R1 的 7896 组（`rust/kdc_core`）。
3. **`Index.d.ts` 契约零改动（前提）**：`git diff main -- entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts`
   为空；`oh-package.json5` 同为空；ArkTS 侧未修改（设备端 ArkTS 直接用现有契约跑通）。
4. **合并风险清单**：

| 风险 | 说明 | 处置 |
|---|---|---|
| C++ 整栈删除 | `net/payload/napi/json/bearssl` + `napi_init.cpp` + 旧 host 测试全删（492 个文件）；main 仍在改 C++（如 `e896b0f`） | 合并时以 Rust 文件为准；证书语义已对齐 |
| `tools/**` 重复实现 | 分支曾改 `sign-debug/launch-app` 的 HDC_TARGET，与 main `528721c` 重复 | 已在分支还原，合并无冲突 |
| AGENTS/文档冲突 | 双方都改了 `AGENTS.md`（分会话约定 vs 分支注记） | 合并时人工并写；分支注记在合并评审时统一处理 |
| CMake/workflows 替换 | CMake 只调 cargo；native workflows 改为 Rust 门禁 | 合并即生效；需各机构建机装 Rust 工具链 |
| 构建依赖 | 首次构建需网络拉 crate；OHOS 交叉需 NDK + ring 的 C 编译 | 在 README/CI 注明；已完成双 ABI 实测 |
| 行为差异 | rustls vs BearSSL、每连接线程 vs epoll、错误码口径 | §7 已列；Android 真机/老设备未见实测 |
| 回退 | — | `main` 仍为 C++；`backup/main-cpp` 保留最后 C++ 快照 |

5. **合并顺序（建议，由 AtomCode/用户执行）**：
   先提交本分支（clean cutover 单独一次提交）→ rebase/merge 当时的 main（`Index.d.ts`
   零改动需复核）→ 跑 `cargo test` + `tests/run.sh` + `hvigorw assembleHap` + 平板/手机冒烟。

## 8. 与 main / C++ 备份分支的关系

- `main` 仍是 C++ 栈；`backup/main-cpp` 是它的长期快照（保留 C++/BearSSL），
  `tools/sync-main-backup.sh` 在 `main` 提交/合并时自动快进备份；`main` 一旦
  不含 `entry/src/main/cpp/net/net_stack.h`（Rust 并入）即冻结备份。
- 本分支（`dev/native-rust`）合入 `main` 前需先与当时的 `main` 对齐（当前 base
  落后于 main 的文档提交）；合并由总指挥 AtomCode 执行。

—— Omp-Native，2026-11-07
