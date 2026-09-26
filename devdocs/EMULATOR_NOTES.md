> **【导入说明 2026-09-26】** 本文件原为**工作区根目录**的机器本地笔记（不在仓库内），而 `AGENTS.md` 三处引用它

## 0. ⚠️ 操作纪律（2026-09-26 实测踩到，务必遵守）

`tools/verify-on-ohemu.sh` 会在**同一个文件**（`entry/src/main/ets/pages/Index.ets`）上做两件事：
① 施加 HDS 降级（否则 ohemu 白屏）；② 若你在其上再叠加自己的实验改动，两者**处于同一文件**。

**因此：`git checkout -- entry/src/main/ets/pages/Index.ets` 会同时抹掉"你的实验改动"和"HDS 降级"** ⇒
重装后 HDS 静态导入回来了 ⇒ **白屏**（2026-09-26 实际发生）。

**正确顺序**（每次实验收尾都照此）：
1. `git checkout -- entry/src/main/ets/pages/Index.ets`（清掉一切工作区改动，回到主线）；
2. **再跑一次** `tools/verify-on-ohemu.sh`（它会重新降级 + 构建 + 签名 + 装机 + 启动）⇒ 设备上得到一个**可正常运行**的版本；
3. 若只是想装"主线原始行为"的包（例如做 A/B 对照），步骤 2 直接完成，**不要**再叠加实验改动。

> 判据：白屏时 hilog 必有 `SyntaxError: '@hms:hds.hdsBaseComponent' does not provide an export name 'HdsTabsController'`；
> 正常时应有 `plugin routes registered: 7` + `native start`。

> ⇒ 引用悬挂。现导入仓库 `devdocs/EMULATOR_NOTES.md`，让两台机器与后续 agent 都可见。
>
> **适用范围**：ohemu（OpenHarmony QEMU）模拟器的启动/连接/调试流程与历史事故记录。
> 与模拟器**当前**能力相关的实测事实以 `AGENTS.md`「模拟器调试」节为准（如：runtimeOS=HarmonyOS 时 HDS 静态导入会白屏、
> ohemu 无 `uinput` 不能做点击级验证、改名后签名材料无需重做、`tools/verify-on-ohemu.sh` 一条命令跑通）。

# 鸿蒙模拟器环境笔记

> 记录时间：2026-09-02，2026-09-03 更新，2026-09-05 复验　**当前路线：宿主 ohemu 模拟器 + 宿主代码，不用 IDE**（Win10 VM 路线见第五节，已搁置）

## 目录约定

- 模拟器镜像/日志放 `~/WorkSpace2/`（不放家目录顶层）：`openharmony-qemu-x86_64-x86_64_virt-phone/`（镜像）、`ohemu.log`（运行日志）
- 签名材料/产物放工程 `kdeconnect-harmony-PreDev/sign/`（已加 .gitignore），一键脚本 `kdeconnect-harmony-PreDev/tools/sign-debug.sh`

---

## 一、Windows VM 下载清单（DevEco Studio 路线，已搁置）

| 项目 | 来源 | 大小（约） | 备注 |
| --- | --- | --- | --- |
| DevEco Studio 安装包 | developer.huawei.com/consumer/cn/deveco-studio/ | ~1.5GB | 需登录华为开发者账号（免费注册），当前最新 6.0.2(22) |
| HarmonyOS SDK | DevEco Studio → SDK Manager（首次启动自动弹出） | ~10-15GB | 需**实名认证**才能下载模拟器镜像 |
| 模拟器镜像 | DevEco Studio → Device Manager → 添加本地模拟器 | ~2-4GB | 手机设备，分辨率 1080×2400，内存给 4G+ |
| WSL2 | Win10 系统功能 | 0 | 见下方启用方法 |
| WSL2 内核更新包（若 21H2 报错） | 微软官方下载 | ~15MB | 仅 Win10 21H2 可能需要 |

**安装路径要求**：DevEco 安装路径和 SDK 路径必须是**纯英文、无空格**，例如 `D:\DevEco`、`D:\HarmonyOS_SDK`。

### WSL2 启用步骤

管理员 PowerShell 依次执行：

```powershell
# 1. 启用 Hyper-V、虚拟机平台、WSL2
dism /online /enable-feature /all /featurename:Microsoft-Hyper-V
dism /online /enable-feature /all /featurename:VirtualMachinePlatform
dism /online /enable-feature /all /featurename:HypervisorPlatform

# 2. 安装 WSL2
wsl --install

# 3. 重启
Restart-Computer
```

重启后验证：`systeminfo | findstr /i "Hyper-V"`（四项应全为"否"）。

> ⚠️ Win10 LTSC 21H2 是 WSL2 支持的最低版本，若 `wsl --install` 报错，需手动安装微软"WSL2 Linux 内核更新包"。若仍失败，建议重装 guest 为 Win10 22H2/23H2 或 Win11。
>
> ⚠️ **执行 dism 命令前必须先给 VM 打快照！** KVM 客户机里启用 Hyper-V 是高危操作，有真实坏机案例（见文末"踩坑记录"）。

---

## 二、ohemu（宿主 Linux 原生 QEMU 模拟器）— 当前路线

### 项目信息

- **预构建镜像（推荐）**：https://github.com/harmony-contrib/ohos-qemu — 最新 release `v20260818`，含 **x86_64 原生**镜像（宿主 KVM 直接跑，无 TCG 模拟开销），标准系统（可装应用、支持 HDC）
- **选镜像**：`openharmony-qemu-x86_64-x86_64_virt-phone.tar.gz`（手机形态，0.62 GB）；另有同尺寸 `-2in1`（平板/PC 形态）
- **其他来源（不推荐）**：
  - OpenHarmony-EduDist x86_64（5.0.2）：官方网盘链接 **2026-08-31 已过期**
  - `zestylemon/ohos-qemu-images`：仅 ARM64，在 x86_64 宿主上 TCG 模拟很慢
  - `openharmony/vendor_ohemu` 源码自构建：`./build.sh --product-name x86_64_virt`，需 200GB+ 磁盘 / 16GB+ 内存 / 数小时~数十小时

### 与 DevEco 模拟器对比

| | ohemu（宿主原生） | DevEco 模拟器（Win10 VM） |
| --- | --- | --- |
| 启动速度 | 秒级 | 分钟级（三层虚拟化） |
| 资源占用 | QEMU + 镜像，<2GB | Win10 + DevEco + 模拟器，>10GB |
| API 兼容性 | OpenHarmony 社区版（低于商用 NEXT 的 API 26） | HarmonyOS NEXT（API 14+） |
| UI 预览 | 支持（VNC/SPICE） | 支持（原生窗口） |
| 适用场景 | 协议层/基本功能测试 | 完整功能测试、UI 开发 |

### 宿主侧使用方法

```bash
# 1. 安装 QEMU（已完成，本机 QEMU 11.1.1）
# paru -S qemu-full

# 2. 下载 x86_64 phone 镜像（0.62 GB，装到自己家目录，无需 sudo）
# 直连 GitHub 在本机失败，用 gh-proxy.com 加速（实测 ~2.2 MB/s）
curl -fL -o ~/Downloads/ohos-qemu-x86_64_virt-phone.tar.gz \
  "https://gh-proxy.com/https://github.com/harmony-contrib/ohos-qemu/releases/download/v20260818/openharmony-qemu-x86_64-x86_64_virt-phone.tar.gz"
# 校验（官方 digest，v20260818 phone）：a07b1ae43323350faef1de8a42532adfd610b2eb95ab0413dc0966e84832bd12
sha256sum ~/Downloads/ohos-qemu-x86_64_virt-phone.tar.gz
tar xf ~/Downloads/ohos-qemu-x86_64_virt-phone.tar.gz -C ~/

# 3. 启动（KVM 加速；/dev/kvm 已确认可读写；**setsid 必须**，见踩坑记录 2026-09-03b）
cd ~/WorkSpace2/openharmony-qemu-x86_64-x86_64_virt-phone
setsid nohup ./launch/linux.sh -r 720x1560 -m 8G -s 4 > ~/WorkSpace2/ohemu.log 2>&1 < /dev/null &

# 4. hdc 连接（默认端口 5555，guest 启动约 60s 后监听）
hdc tconn 127.0.0.1:5555
hdc list targets -v
```

启动参数常用项：`-r WxH` 分辨率（默认 800x500）、`-m` 内存（默认 4096）、`-s` 核数（默认 4）、`--headless --vnc-display 21` 无窗口（VNC TCP 5921）、`--serial-port` 串口、`-a kvm|tcg|auto` 加速。日志在 `~/WorkSpace2/ohemu.log`（guest 内核/系统日志直接输出到这里）。

### 已知问题与修复

**hdcd 启动失败**（SELinux 上下文问题，来自 vendor_ohemu issue #92 的 x86_64_virt 调试镜像）：

v20260818 预构建镜像**无此问题**（hdc 直接可连，已实测）。仅当换用其他镜像、hdc 连不上时再参考本节。

### 性能注意事项

- v20260818 预构建镜像是 **x86_64 原生**，宿主有 KVM（`/dev/kvm` 已确认可读写），全速运行，无 TCG 开销
- 宿主资源（32 核 / 30G 内存 / 735G 余量）给模拟器 4 核 + 8G 内存即可
- 若改用 ARM64 镜像（zestylemon 等），x86_64 宿主上 TCG 模拟会很慢，不推荐

### API 版本兼容性

- v20260818 镜像实际是 **OpenHarmony 7.0.0.32 / API 26**（`hdc shell param get const.ohos.apiversion` 实测），与工程 `compileSdkVersion 26.0.0` 匹配，**无需降级**

### 签名 + 安装 APP（2026-09-03 已打通）

- 未签名 HAP 装不上：`error: verify signature failed. code:9568329`，必须本地 debug 签名
- **一键脚本**：`kdeconnect-harmony-PreDev/tools/sign-debug.sh [all|sign-only|install]`（构建 + 签名 + 安装 + 启动全流程已验证）
- 签名材料全来自宿主 SDK，**不需要 DevEco/华为账号**（`/opt/ohos-sdk/26/toolchains/lib/`）：
  - `OpenHarmony.p12`（PKCS12，密码 `123456`）：内含 release 应用私钥 + profile debug 签名私钥
  - `OpenHarmonyProfileDebug.pem`：profile 证书链（root, app-ca, profile-debug 三张）
  - `UnsgnedDebugProfileTemplate.json`：profile 模板（**注意模板里的 development-certificate 才是配对叶证书**）
  - `hap-sign-tool.jar`：签名工具（`sign-profile` → `sign-app` 两步）
- 流程细节与坑：
  1. profile 模板要填：bundle-name、版本、有效期（模板自带的 2021~2023 **已过期**）、`debug-info.device-ids` = 设备 UDID（`hdc shell bm get --udid`）
  2. `keytool -exportcert` 必须加 **`-rfc`**（默认输出 DER 二进制，拼链全废）
  3. 证书链顺序必须是 **leaf → 中间 CA → root**，单张证书报 `11013004 Profile cert must a cert chain`
  4. `hap-sign-tool sign-app` 的 appCertFile 也用完整链；p12 里 `openharmony application release` 条目是**自签名**（issuer=自己），链验证会失败，必须用模板里 App CA 签发的那张同名证书
  5. 签名算法按证书实际值：**SHA384withECDSA**（证书是 ecdsa-with-SHA384）
  6. `-compatibleVersion 26` 对 .hap 必填
- 启动应用：`hdc shell aa start -b org.kde.kdeconnect.harmony -a EntryAbility`（ability 名是 `EntryAbility` 不是 MainAbility）
- 换模拟器实例后 UDID 会变，重跑 `sign-debug.sh` 会自动重新取 UDID 重签 profile

---

## 三、踩坑记录

### 2026-09-03b：ohemu 实测（x86_64 phone v20260818，KVM 全速）

- 镜像下载：直连 GitHub 失败，`gh-proxy.com` 代理可用（~2.2 MB/s），sha256 与官方 digest 一致
- **`nohup ... &` 在工具/脚本会话里启动会被回收**：进程在 guest 启动 58s 处死掉；改 `setsid nohup ... < /dev/null &` 完全脱离会话后稳定存活
- 启动到 hdc 监听约 60s；hdc 用宿主 `/opt/ohos-sdk/26/toolchains/hdc`（Ver 3.2.0f）直接可连，**之前担心的 hdcd SELinux 问题在此镜像上不存在**

- 注意内存账：ohemu 默认给 8G；宿主机 30G，若同时开其他 VM（HarmonyDev 8G、Kali 4G），总占用 20G+，紧张时 ohemu 降到 `-m 4G`

### 2026-09-05：复验通过

- 重启后重跑全流程（启动 → `hdc tconn` → 签名 → 安装 → 启动 APP）全部一次通过，无新增坑
- UDID 在模拟器重启后保持不变（`6F70…14A`），已有 `sign/entry-debug-signed.hap` 直接复用，无需重新取 UDID 重签
- 应用 `aa dump` 状态 `#FOREGROUND`，`start ability successfully`，无崩溃

### 2026-09-03：启用 Hyper-V 导致 VM 坏机

- **操作**：Win10 LTSC 21H2 guest 内管理员 PowerShell 跑 `dism /online /enable-feature /all /featurename:Microsoft-Hyper-V` + `VirtualMachinePlatform`，重启
- **结果**：卡自动修复循环，无快照可回滚，高级选项也进不去 → 虚拟机删除重装
- **原因（推测）**：KVM 嵌套 Hyper-V + 较老 guest 版本（21H2），hypervisor 启动后 guest 自身引导挂掉
- **教训**：
  1. **改系统级特性前先打快照**（装完系统 → 装完 DevEco → 再动 Hyper-V，每步一个快照）
  2. 功能一次只开一个，每步重启验证能进系统再开下一个
  3. 不再用 Win10 21H2 LTSC，换 23H2 或 Win11
  4. 嵌套虚拟化路线若再次失败，VM 只保留 DevEco IDE，模拟器走宿主 ohemu

## 四、重装清单（2026-09-03 事故后）

1. **VM 配置**：16G 内存 / 8 vCPU / 150G 磁盘（保持 SATA 总线，免装 virtio 驱动）；CPU host-passthrough + hyper-v enlightenments 保持
2. **系统**：Win10 23H2 64 位（或 Win11 + swtpm 虚拟 TPM），不再用 21H2 LTSC
3. **分阶段快照**：
   - 装完系统 + Windows Update → **快照 A**
   - 装完 DevEco Studio + SDK + 预览器验证可用 → **快照 B**
   - 再开 Hyper-V / 虚拟机平台（一次一个，每步验证能进系统）→ 成功后 **快照 C**
   - 任何一步坏机 → 回滚快照 B，改走"IDE-only + 宿主 ohemu"路线
4. **兜底组合**（VM 模拟器跑不通时的最终形态）：
   - 宿主 ohemu 跑模拟器，QEMU `hostfwd=tcp::5555-:5555` 改成 `hostfwd=tcp:0.0.0.0:5555-:5555` 暴露到 virbr0
   - VM 内 `hdc tconn <宿主IP>:5555`，DevEco 设备列表可直接连宿主上的 ohemu 设备，享受 DevEco 的调试/部署能力

## 五、推荐路径（2026-09-03 更新）

**当前已落地路线（日常开发用这个）**：

1. 宿主写码 + 宿主构建（`hvigorw`，PATH 里有）
2. 宿主 ohemu 模拟器（KVM 全速，镜像已就位）
3. `kdeconnect-harmony-PreDev/tools/sign-debug.sh` 一键签名 + 安装 + 启动
4. `hdc` 直接连宿主模拟器调试（`hdc tconn 127.0.0.1:5555`）

**Win10 VM 路线**（第一、四节）已搁置：Hyper-V 嵌套坏机过一次，且确认不需要 IDE 后不再优先；仅当 ohemu 的 OpenHarmony 社区版 API 不满足需求、需要商用 HarmonyOS NEXT 模拟器或 DevEco IDE 特有功能时再启动（按第四节清单 + 快照纪律操作）。
