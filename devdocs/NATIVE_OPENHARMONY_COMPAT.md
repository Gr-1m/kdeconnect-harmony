# native 层 OpenHarmony 兼容性确认（2026-09-26，Omp）

> 对应 `devdocs/PROJECT_ROADMAP.md` 中「方向 F / 双平台」负责方一栏的 **Omp（native 层兼容性确认）**。
> **结论：native 层无需为 OpenHarmony 改动。** 证据 = 静态审计（§1）+ ohemu 运行时实证（§2）。

## 1. 静态审计（`entry/src/main/cpp/`）

### 1.1 系统头文件：全部是 POSIX/BSD 标准

按引用次数：`unistd.h`(9) `sys/socket.h`(9) `netinet/in.h`(7) `arpa/inet.h`(6) `sys/epoll.h`(5)
`sys/eventfd.h`(4) `poll.h`(2) `sys/random.h`(1) `net/if.h`(1) `ifaddrs.h`(1) `errno.h`(1)。
这些在 OpenHarmony 的 musl/NDK 中均存在，无平台分支需求。

### 1.2 OHOS 专有界面：仅 NAPI + hilog，二者皆属 OpenHarmony 标准 NDK

| 接口 | 头文件 | 链接库 | OpenHarmony |
|---|---|---|---|
| NAPI（JS↔native 桥） | `napi/native_api.h` | `libace_napi.z.so` | ✅ 标准 NDK |
| 日志 | `hilog/log.h` | `libhilog_ndk.z.so` | ✅ 标准 NDK |

### 1.3 第三方依赖：全部 vendored，不依赖系统库

`cpp/bearssl/`（TLS/证书，经 CMake `file(GLOB_RECURSE)` 编译）、`cpp/json/`（cJSON）。
OHOS sysroot 无 JSON 库 ⇒ 自带，故不构成跨平台障碍。

### 1.4 未使用任何 HarmonyOS 专有 native API

对 `Hds*` / `UIDesignKit` / `@hms` / HMS Core / AGC 的检索：**0 命中**。

## 2. 运行时证据（ohemu = OpenHarmony 镜像）

本机 ohemu（OpenHarmony）上 native 栈**已实际运行**：`tcp listening` / `udp discovery init` /
`native start ok` / `KDC-NETLOOP` 遥测可见 ⇒ OpenHarmony 侧**运行时可用性已被实证**，
不只是"代码看起来没用到专有 API"。

## 3. 已知的**非** native 层问题（不影响本结论）

- 本机**构建** OpenHarmony 目标不可行：商用 CLT 拒绝该 SDK 布局（`The SDK management mode has changed.`）
  ⇒ 属**工具链/打包**问题，与 native 代码无关；
- ArkTS 侧 `@kit.UIDesignKit`（HDS）在 OpenHarmony 缺失 ⇒ 属 **ArkTS 层**，
  「方向 F」要解决的正是它（本机替代方案 `tools/verify-on-ohemu.sh`）。

## 4. 结论

1. **native 层：无需改动** —— 与 ROADMAP 中「native 无需改动（packet 通道已有）」一致，本件为其**证据化确认**；
2. 方向 F 的双平台工作量**全部落在 ArkTS/构建层**（HDS 可见性策略 + 双产物签名/打包）；
3. 可复用的验证手段：`tools/verify-on-ohemu.sh`（构建期 HDS 降级 + 构建/签名/装机/启动/取证，`--revert` 还原）。

—— Omp，2026-09-26
