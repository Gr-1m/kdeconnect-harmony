# KDE-H Connect — C++ Native 标准化开发指导（v0.1）

> 2026-09-12，zcode（本机 native agent，兼部分总指挥职责）起草。
> 适用于新仓库 `<workspace>/kdeconnect-harmony`（gitcode 中心仓库 clone，分支 `dev/zcodeinit`）的重建工作。
> 读者：C++ native agent（当前 zcode）、CodeArts（评审/单测/CI）；DevEco Code 只需关注 §5 契约与 WP 表中的契约触碰点。
> 背景与全局约束见仓库根 `KICKOFF_PROMPT.md`（工作区级说明），本文不重复，只做 C++ 侧的落地规范。

## 0. 事实源优先级

1. `kdeconnect-meta/schemas/`（协议 JSON Schema，**唯一事实源**，只读）
2. `entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts`（NAPI 接口契约，**唯一定义源**）
3. `KICKOFF_PROMPT.md` + 工作区 `AGENTS.md`（流程与硬约束）
4. 参考实现 `kdeconnect-kde/`、`kdeconnect-android/`（只读，按符号名搜索）

冲突时按上面顺序裁决；发现文档与代码不符，先在 `AgentsConversion/` 发消息对齐，再改代码。

## 1. 重建策略：携带移植，不从零重写

旧工程 `~/WorkSpace2/KDE_connect_hap/kdeconnect-harmony-PreDev` 的 native 栈已端到端验证
（UDP 发现 → TCP → BearSSL TLS → identity 交换 → 配对 → ping，连桌面 KDE 实测通过）。
**重建 = 把已验证基线搬进新仓库，再按 M1 计划扩展**，不要推倒重写已验证的网络栈。

### 基线移植清单（WP-0）

| 旧（PreDev） | 新（本仓库） | 说明 |
|---|---|---|
| `entry/src/main/cpp/net/`（10 组 .h/.cpp） | 同路径 | 网络栈：udp_discovery / tcp_server / tcp_connection / tls_engine / packet_io / cert_gen / net_stack / net_types / net_log / napi_exports |
| `entry/src/main/cpp/napi/` + `napi_init.cpp` | 同路径 | tsfn 事件桥 + 模块注册（`NAPI_MODULE` 写法，勿改） |
| `entry/src/main/cpp/json/`（cJSON） | 同路径 | vendor，不碰 |
| `entry/src/main/cpp/bearssl/` | 同路径 | BearSSL 0.6 vendor（~277 .c），不碰 |
| `entry/src/main/cpp/types/libkdeconnect_napi/` | 同路径 | d.ts 契约 + oh-package.json5 |
| `entry/src/main/cpp/CMakeLists.txt` | 同路径 | GLOB 方案，归 native agent 维护 |
| `tools/sign-debug.sh`、`tools/launch-app.sh` | 同路径 | 构建+签名+装模拟器链路 |
| `SETUP_NOTES.md` 构建坑清单 | 并入本文 §7 或单独保留 | 见 §7 |

**不带入**：旧仓库的 git 历史（新仓库已有中心仓库 Initial commit）；ArkTS 侧改动由 DevEco Code 按同一原则自行移植（其中 `Index.ets` 有一处用户明确保留的未提交改动「connected 后主动发 pair」，移植与否由用户决定，native 侧不依赖它）。

## 2. 目录结构规范

**WP-0 移植期**：保持旧布局不动（`net/` `napi/` `json/` `bearssl/`），降低移植风险。
**M1 改造期（WP-1/2/3 落地时）**：演进为：

```
entry/src/main/cpp/
├── CMakeLists.txt          # native agent 维护
├── napi_init.cpp           # 模块注册（NAPI_MODULE 宏）
├── napi/                   # tsfn 事件桥、JS↔C++ 类型转换
├── net/                    # socket/TLS 连接管理（udp/tcp/tls/net_stack）
│   └── net_util.*          # 网络地址策略（isPrivateIpv4；安全判定，host 可测）
├── proto/                  # 协议编解码：帧读写、identity 构造/解析、跨端常量（从 net/packet_io 拆出）
├── payload/                # (新) 二进制 payload 传输通道
├── security/               # (新) 连接限流、信任存储、证书钉扎
├── json/  bearssl/         # vendor，只读
└── types/libkdeconnect_napi/Index.d.ts   # 契约唯一定义源
```

拆分原则：`proto/` 与 `payload/` 必须只依赖 POSIX + cJSON，**不依赖 NAPI/NDK 头**，以便 WP-4 在宿主机编译跑单测；NAPI 依赖只允许出现在 `napi/`、`napi_init.cpp` 与 `net/` 的事件出口处。
「安全策略判定」类纯函数（当前：`isPrivateIpv4`）放 `net/net_util.*`——它们必须有边界回归用例，不能藏在 `net_stack.cpp` 的匿名命名空间里（P1-1 曾因此在 172.16/12 上写错且无测试可发现）。

## 3. C++ 工作包分工（M1）

| WP | 内容 | 负责 | 交付 / 验收标准 |
|---|---|---|---|
| WP-0 | 基线移植 + 冒烟：§1 清单搬入，`hvigorw assembleHap` 通过，模拟器 `init→deviceDiscovered` 事件实证 | zcode | 构建成功 + 模拟器事件日志 |
| WP-1 | **payload 二进制传输**（M1 最优先）：`payload/` 传输通道（`payloadTransferInfo` 端口 ≥1739，对端另开 TCP 拉取）、d.ts v2 契约扩展（payload 事件 + 进度 + 接收落盘接口） | zcode 实现；d.ts v2 由 DevEco Code 共定 | 桌面 KDE 发文件 → 鸿蒙收到并落盘，进度事件可见 |
| WP-2 | 连接安全加固：同 IP/deviceId 1000ms 限流、仅接受私网地址、信任设备存储（NAPI 存取接口，持久化走 ArkTS Preferences）、证书钉扎、证书变更拒连 | zcode | 连桌面实测：配对过的设备重连免确认、证书变更被拒 |
| WP-3 | mDNS 发现（`_kdeconnect._udp`）+ UDP 双通道、多网卡定向广播 | zcode 实现；CodeArts 先做技术调研（自实现最小 DNS-SD vs vendor mdnsd，出结论再动手） | 与桌面 KDE 的 mDNS 互相发现 |
| WP-4 | 单元测试 + CI：`proto/`（帧切分、identity 编解码、验证码算法）host 可编译单测；gitcode `.gitcode/workflows/` 流水线 | **单测由代码 owner 编写**（native=zcode、ArkTS=DevEco Code）；**CodeArts 指导**（测试计划、覆盖要求、评审，不碰代码）；CI 流水线由 CodeArts 出规格、代码侧落地 yml | host 跑通单测；CI 绿 |
| WP-5 | NAPI 契约维护流程（见 §5） | DevEco Code 发起，zcode 实现，CodeArts 评审 | 流程被实际执行 |
| WP-6 | 构建脚本与 Release 配置：sign-debug.sh 移植、Release 签名/混淆（M4 前完成即可） | zcode | Release HAP 可安装 |

排序即优先级：WP-0 → WP-1 是关键路径（M1 的验收锚点是「桌面发文件到鸿蒙」）。
M2（iOS 功能集插件）主体在 ArkTS 侧（插件注册表/插件基类/每设备一实例），native 只提供 WP-1 的传输能力与既有的收发事件，**native 侧 M2 不新增大模块**。

## 4. 编码规范

- **语言**：C++17 / C11；NDK clang 编译，基线 `-Wall` 零警告（旧代码已达此水平，不许倒退）。
- **命名**：`namespace kdeconnect`；文件 snake_case；类型 CamelCase；成员变量尾缀 `_`；`constexpr` 常量全大写（与 `net_types.h` 现状一致）。注释中文为主、标识符英文。
- **头文件**：guard 宏 `KDECONNECT_<MODULE>_H`；优先前置声明；接口头不放实现。
- **错误处理**：native 内部错误一律转 `error` 事件（含 `errorCode`/`errorMessage`），不向 JS 抛异常、不崩溃；epoll 循环内 socket 错误记 hilog 后按连接粒度恢复。
- **线程模型**（沿用旧栈，勿破坏）：
  - 单 epoll 线程处理全部 UDP/TCP/TLS I/O；socket 全部 `SOCK_NONBLOCK | SOCK_CLOEXEC`，`EPOLLET` 边缘触发；
  - 事件出口只有一条：`netStack().setEventCallback(Emit)` → `napi/` tsfn → ArkTS 主线程；
  - **发送侧单写者队列**，禁止多线程直接写同一连接（防帧交错）；
  - **锁序（P0-3 ABBA 防护）**：`NetStack::connMutex_` → `PayloadManager::mu_` 是唯一合法方向
    （网络线程 `onConnectionReadable`/`closeConnection` 持 connMutex_ 调 `startReceive`/`onDeviceDown`）。
    因此 payload 模块**不得在持 `mu_` 时**调用会取 `connMutex_` 的宿主回调
    （`sendControlFrame`、`peerCertPem`）——这类调用一律在出锁后执行；
    `epollAdd/epollDel/postPayloadEvent/nowMs` 不取锁，允许在 `mu_` 内调用（契约见 `payload.h`）。
  - 禁止在 ArkTS 主线程（NAPI 方法体内）做阻塞 I/O，方法只做排队/置标志。
- **JSON**：只用 cJSON；packet `type`/`body` 与 `kdeconnect-meta/schemas/` 逐字一致；改 schema 后在 `kdeconnect-meta/` 内 `make check`。
- **vendor 目录**（`bearssl/`、`json/`）：不修改、不格式化、不重命名，升级需换整个目录并在消息里说明版本。

## 5. NAPI 硬规则（踩过坑的，逐条执行）

1. 模块注册必须用 SDK 的 `NAPI_MODULE(name, reg)` 宏；Node 风格 `napi_register_module_v1` 运行时不识别（症状：`.so` 已加载但 exports 全空）。
2. `module.json5` 必须声明 `ohos.permission.INTERNET`，否则沙箱内 `socket()` 直接失败且 errno 被掩成 `<private>`。
3. ArkTS 严格模式禁止结构化类型：类型一律 `import { ... } from 'libkdeconnect_napi.so'`，d.ts 里声明一次，ArkTS 不本地重声明同构 interface。
4. **契约流程**：DevEco Code 提案接口变更 → 同一改动内更新 `Index.d.ts`（方法名/事件名/字段名/返回语义逐字定稿）→ zcode 按 d.ts 实现 C++ → CodeArts 评审。native 不单方面改 d.ts；d.ts 与实现不一致视为 native bug。
5. 事件回调必须走 tsfn；构造事件对象用 `napi_create_object` 逐字段组装（与 d.ts 字段一一对应），字符串走 UTF8；回调体内必须建 `napi_handle_scope`。
6. 事件 `type` 命名与 d.ts 字面量联合类型严格一致；新增事件先改 d.ts 再实现。

## 6. 协议一致性常量（改一处必须核对三端 + meta）

protocolVersion=8；UDP 1716；TCP 1716–1764 顺序探测；payload 端口 ≥1739；单包 32 MiB；identity 包 ≤8 KiB；配对 timestamp 容差 ±1800 秒；deviceId 正则 `^[a-zA-Z0-9_-]{32,38}$` 且 = 证书 CN 且必须持久化；证书有效期 −1y→+10y；验证码 = 双方公钥 DER 按字节序排序拼接 + SHA256 前 8 位 hex 大写（v8 追加配对 timestamp）。

实现规则（旧栈已验证，移植时不得走样）：
- TCP 是流：读循环自维护缓冲按 `\n` 切分，半包等下次、非法 JSON 丢该行继续；
- identity 包**不含证书**，对端证书从 TLS 层取；
- 必须忽略自己的 deviceId；未配对设备只收 `kdeconnect.pair`；
- v8 须在加密通道内二次交换 identity 并校验 deviceId/protocolVersion/证书 CN 一致；
- TCP 发起方 = TLS server，接收方 = TLS client（三方强制，不可改）。
- **payload 通道证书认证（P0-2，2026-09-13 定稿）**：发送方（TLS server）**必须**请求并校验对端证书
  （`ServerClientAuth`：可接受 CA 名 = 对端证书 subject DN，空则占位名；`verifyPeerLocked` 要求 CN == deviceId）。
  两条 BearSSL 硬事实（host 实验实证，见 `MSG59`）：
  1. 纯 EC 的 `br_ssl_server_init_full_ec` **不会**在 `CertificateRequest` 里列 ECDSA，
     必须先 `br_ssl_engine_set_default_rsavrfy/ecdsa(&eng)`（列表由 `supports-rsa-sign?/supports-ecdsa?` 决定），
     否则对端回空证书 → `ERR_NO_CLIENT_AUTH(29)`；
  2. Qt/OpenSSL 客户端**不按 CA 列表过滤**（ca=bogus 也照样出示证书），Java(SunJSSE) 会过滤——
     所以有对端证书时用真实 DN，未知时才降级为占位名 + 容忍缺失。
- **x509 vtable 必须是静态初始化对象**：不得从 `br_x509_minimal_vtable` 抄字段值（会产生动态初始化，
  在跨 TU 初始化顺序下前几个槽为 0 → `x509-start-chain` 处 call null，已实测）；
  用直通转发函数（`capture_start_chain`/`capture_get_pkey`）在运行期查表。
- **控制连接也必须捕获对端证书（2026-09-13 定稿）**：TLS **server** 角色（= 本机主动发起的连接，
  手动连接/首次连接的主路径）必须请求对端证书：`startTlsHandshake()` 传
  `ServerClientAuth{tolerateNoCert=true}`。否则 `getPeerCertificate()`/`getPairVerificationCode()`
  全返回空 → 配对弹窗**无验证码**、`TrustStore` 存不到对端证书（钉扎失效）、payload 发送方向
  只能走占位 CA 名 + 容忍缺失的降级路径。**实测**：修前 host 集成工具（`tests/desktop_pair.cpp`）
  与本机 KDE 配对时验证码为空串，修后为 `F3C16020` 且与 KDE 通知里的 Key 逐字一致。
  TLS client 角色无需请求（client 分支的 `capture_x509_vtable` 直接拿对端证书）。

## 7. 构建与验证

- 构建：工作区根执行 `cd kdeconnect-harmony && hvigorw assembleHap`（**无本地 wrapper，不要 `./hvigorw`**）。
- **本机构建环境坑（2026-09-13 实测，挡所有 agent）**：系统 libxml2 升到 2.15（soname `libxml2.so.16`），
  而商用 CLT 的 BiSheng `ld.lld` 依赖 `libxml2.so.2` → CMake 编译器探测阶段
  `ld.lld: error while loading shared libraries: libxml2.so.2`，表现为
  `CMake will not be able to correctly generate this project`（**与业务代码无关**）。
  旁路（不改系统、不需 root）：
  ```bash
  mkdir -p /tmp/ohos_libshim && ln -sf /usr/lib/libxml2.so.16 /tmp/ohos_libshim/libxml2.so.2
  LD_LIBRARY_PATH=/tmp/ohos_libshim hvigorw --no-daemon assembleHap
  ```
  注意 `--no-daemon` 必需：已在跑的 hvigor daemon 继承的是旧环境变量，shim 不会生效
  （`--stop-daemon` 后重起亦可）。
- host 单测（WP-4，无需 SDK/模拟器，CI 可直接调）：
  ```bash
  cd entry/src/main/cpp/tests && ./run.sh
  ```
  产出两个二进制：`kdc_native_tests`（纯函数：帧切分/identity/验证码/地址策略/证书工具）与
  `kdc_payload_tests`（payload 端到端：真实 `PayloadManager` + `TlsEngine` + 假宿主，覆盖
  发送/接收/落盘/证书 CN 拒绝/`mu_`↔宿主锁序）。BearSSL 由官方 Makefile 构建到 `/tmp`，不写 vendor 目录。
- 改动 payload/TLS 时，**必须**让 `tests/payload_e2e.cpp` 覆盖的新行为在「回退该修复」后失败
  （回归用例的必要性验证），再提交。
- **host 集成工具（对真桌面，不进 CI）**：`entry/src/main/cpp/tests/run_desktop.sh pair|sendfile|serve`
  用**真实 native 全栈**连真桌面 KDE（默认 `<host>:1716`），把 `tests/desktop_pair.cpp` 当端点：
  可验证「配对 + 双方验证码一致 + 双向 payload（A1/A1b）」，**不需要模拟器**。四条使用注意：
  1. 工具固定 `tcpPort=1735`：与本机同时跑的 kdeconnectd 抢 1716 会让局域网其他设备拨错 daemon（实测混淆）；
  2. spool 目录经 `NetConfig.spoolDir` 指到 `/tmp`（设备默认 spool 是沙箱路径 `/data/storage/...`）；
  3. 对端（KDE）只把 packet 交给插件的前提是**本机 outgoingCapabilities 含该 packet type**——
     发文件必须含 `kdeconnect.share.request`，否则 KDE 记 `discarding unsupported packet`、不来拉 payload（30s 超时）；
  4. 接收方向需先 `setTrustedCertificate(peer, getPeerCertificate(peer))`（模拟 App 的 AP-3），
     否则被 P1-3 信任门禁拒绝（`payload rejected: device not paired/trusted`）。
  另：同一桌面端反复跑会累积陈旧 link，KDE 取**首个 link** 发 packet → 偶发丢包；重跑前重启对端 daemon 最干净。
- 调试对端 KDE：`QT_LOGGING_RULES=kdeconnect.core.debug=true QT_ASSUME_STDERR_HAS_CONSOLE=1 kdeconnectd`
  （只设前者不会输出到重定向文件，实测）；`gdbus monitor --dest org.kde.kdeconnect` 看状态机，
  `gdbus call … device.verificationKey` 读对端验证码（与 App 弹窗里的码逐字比对）。
- **M1 native 侧验证状态（2026-09-13，对真 KDE 实测）**：native→桌面 1 MiB（sha256 一致 ✅）、
  桌面→native 512 KiB（sha256 一致 + `settle` 落盘 ✅）、配对成功（`pairState` 2→3、双方验证码一致 ✅）。
  模拟器侧 A1/A1b/A8/A9/A10 仍需 DevEco 在 Win10 跑（NAT 下走手动连接）。
- 环境体检（每次开工）：`local.properties` 是否被改成 Windows 路径（对策 `OHOS_BASE_SDK_HOME=/opt/command-line-tools/sdk/default/openharmony`）；`oh_modules/@ohos/hvigor*` 软链是否在位（勿 `ohpm install` 重装）；`hdc list targets` 模拟器是否在线。
- 模拟器：`setsid nohup … < /dev/null &` 启动（普通 `nohup &` 会被会话回收）；装设备/模拟器操作优先在用户终端执行。
- 静态检查以 `hvigorw assembleHap` 编译期检查为准（本机 codelinter 类型门禁假象，勿采信）。
- 每次交付前冒烟：构建 → sign-debug.sh → 模拟器 → hilog 关键行（deviceId / packet type / 错误码）。

## 8. 协作纪律（C++ 侧执行细则）

- **流程权威 vs 技术权威（用户 2026-09-12 指定）**：工作流事务——commit/push 时机、协作消息文件清理（哪些可删）、单测指导、CI 规格——由 **CodeArts 指导**，CodeArts **不碰任何代码**（git 操作由各文件 owner 按其指令执行）；技术架构、契约、优先级等方向性决策由 native agent（zcode）主导，DevEco Code 对 ArkTS 技术方案有对等发言权。
- 通信目录：**仓库内 `AgentsConversion/`**（git 忽略、随 Syncthing 同步给 Win10；旧工作区同名目录已留 MOVED 指针）。每次执行命令前后检查该目录变化。
- 未提交纪律：**未经用户明确要求不 commit / 不 push**；旧工程 `Index.ets` 的 pair 改动保持未提交状态，勿回退。
- 参考实现三目录（meta/kde/android）只读。
- 跨层改动（涉及 d.ts 或跨端常量）先走 §5.4 流程；跨机同步一律走 gitcode，不依赖共享目录。
- 本文档由 native agent 维护；结构、命令、分工变化时同改动更新本文并通知各 agent。
