> **【导入说明 2026-09-26】** 本文件原为**工作区根目录**的机器本地笔记（不在仓库内），而 `AGENTS.md` 三处引用它
> ⇒ 引用悬挂。现导入仓库 `devdocs/EMULATOR_NOTES.md`，让两台机器与后续 agent 都可见。
>
> **【2026-10-21 整合】** AtomCode 整理的 `harmony-emulator-run-guide.md`（基于 Spatialization 示例项目 2026-10-19 验证）
> 已整合：§2.5 排障（hdc 端口残留 + 冷启动）、§4 对比表 unsigned HAP 差异、§6 路线 A unsigned HAP 说明、
> §9 踩坑记录新增 hdc server 残留端口、§11 推荐路径更新路线 A 快捷流程。
>
> **适用范围**：Linux 端模拟器的启动/连接/调试流程与历史事故记录。涵盖两条路线：
> - **路线 A**：devecocli + 原生 Emulator（HarmonyOS 商用镜像，支持 HDS 组件）
> - **路线 B**：ohemu（OpenHarmony QEMU 社区镜像，轻量快速）
>
> 与模拟器**当前**能力相关的实测事实以 `AGENTS.md`「模拟器调试」节为准。

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

---

## 1. 环境清单

| 组件 | 路径 | 说明 |
|---|---|---|
| devecocli | `~/.bun/bin/devecocli` | HarmonyOS 命令行工具（bun 全局包 `@deveco/deveco-cli`） |
| command-line-tools | `/opt/command-line-tools/` | 内含 `ohpm`、`hvigorw`、`Emulator` |
| 原生 Emulator | `/opt/command-line-tools/emulator/Emulator` | 版本 26.0.0.400，QEMU 系 |
| OpenHarmony SDK | `/opt/ohos-sdk/26/` | API 26，`env.sh` 提供环境变量，`toolchains/hdc` 为设备调试工具 |
| ohemu 镜像 | `~/WorkSpace2/openharmony-qemu-x86_64-x86_64_virt-phone/` | OpenHarmony 7.0.0.32 / API 26，x86_64 原生 |
| libxml2 shim | `~/.local/share/ohos_libshim/libxml2.so.2` | 软链 → `/usr/lib/libxml2.so.16`，解决 CLT ld.lld 依赖 |
| KVM | `kvm_intel` 模块 | 虚拟机内 `/dev/kvm` 可能不存在，需宿主机提供 |

### 前置检查

```bash
which devecocli ohpm hdc hvigorw         # 工具链在不在
lsmod | grep kvm                          # KVM 模块是否加载
ls -la /dev/kvm                           # KVM 设备节点（虚拟机内可能不存在）
devecocli emulator list                   # 现有虚拟设备
devecocli emulator image list --all       # 可下载的系统镜像
```

### libxml2 shim（构建必需）

系统 libxml2 升到 2.15（`libxml2.so.16`），而 CLT 的 BiSheng `ld.lld` 依赖 `libxml2.so.2`。不改系统，用软链旁路：

```bash
mkdir -p ~/.local/share/ohos_libshim
ln -sf /usr/lib/libxml2.so.16 ~/.local/share/ohos_libshim/libxml2.so.2
```

构建时必须带环境变量（`--no-daemon` 必需，已启动的 hvigor daemon 不会继承新环境变量）：

```bash
LD_LIBRARY_PATH=$HOME/.local/share/ohos_libshim hvigorw --no-daemon assembleHap
```

> **路径别放 `/tmp`**：临时目录清理会把 shim 删掉，症状是链接期莫名失败（`clang++: unable to execute command: No such file or directory`）。

---

## 2. 路线 A：devecocli + 原生 Emulator（HarmonyOS 商用镜像）

适用于：需要 HarmonyOS 商用 API（HDS 组件、沉浸光感材质等）的验证。

### 2.1 接受协议（两层，顺序有讲究）

协议有两层，**CLI 层接受了，原生层还是要再接受一次**：

```bash
# 第一层：devecocli CLI 层（非交互）
devecocli emulator license accept

# 第二层：原生 Emulator 二进制层（非交互）
/opt/command-line-tools/emulator/Emulator -license accept
```

> 踩坑：只做了第一层，`emulator start` 时原生二进制仍会打印协议并拒绝启动。
> 第二层的 `y/N` 提示**不读管道输入**（`printf 'y\n' |` 无效），必须用 `-license accept` 参数。

### 2.2 下载系统镜像

先根据项目 `build-profile.json5` 里的 `targetSdkVersion` 选镜像（本项目为 `26.0.0` → 镜像 `HarmonyOS 7.0.0(26.0.0)`）：

```bash
# 手机镜像约 2.1GB，下载后位于
# ~/Library/Huawei/Sdk/system-image/HarmonyOS-7.0.0/phone_all_x86/
printf 'y\n' | devecocli emulator image download \
  --device-type phone \
  --os-version "HarmonyOS 7.0.0(26.0.0)"
```

> 踩坑：镜像下载时会**交互式**弹出 SDK License Agreement，非交互环境下直接跑会报
> `Please agree to the agreement first` 且下载失败。解决：`printf 'y\n' |` 管道喂入 `y`
>（与原生二进制的提示不同，**CLI 层的提示是读 stdin 的**）。

### 2.3 创建虚拟设备

```bash
devecocli emulator create SpatialPhone \
  --device-type phone \
  --os-version "HarmonyOS 7.0.0(26.0.0)"
```

实例配置落在 `~/.Huawei/Emulator/deployed/SpatialPhone/`（`config.ini` 等）。

可选设备类型：`phone / foldable / widefold / triplefold / tablet / 2in1 / 2in1 foldable / wearable / tv`。

### 2.4 启动模拟器

```bash
devecocli emulator start SpatialPhone
```

启动后等待系统自启（约 30s~1min），确认设备就绪：

```bash
export PATH=/opt/ohos-sdk/26/toolchains:$PATH
hdc list targets        # 应显示 127.0.0.1:5555
```

> **KVM 要求**：原生 Emulator 需要 `/dev/kvm`。在物理机上直接可用；在虚拟机内需确保嵌套虚拟化已启用且 `/dev/kvm` 存在。

### 2.5 排障：start 成功但 hdc list targets 不出现设备

现象（2026-10-20 实际遇到）：

```
$ devecocli emulator start SpatialPhone
Emulator "SpatialPhone" was launched but did not appear in hdc list targets within the timeout.
```

- `Emulator.log` 每秒刷 `hdc is not connected, hdc list target not identify`；
- Emulator 进程在跑，但监听的是 5557 而不是 5555（`ss -ltnp | grep 555`）；
- `hdc tconn 127.0.0.1:5557` 报 `[Fail]Connect failed`（端口 accept 队列积压，不接新连接）。

根因（两个问题叠加）：

1. **宿主 hdc server 是很久以前的残留进程**，仍持有旧设备的 5555 端口注册（昨晚关机时未清理）→ 今天的新 Emulator 拿不到 5555，被迫用 5557；
2. Emulator 走了 **snapshot 热启动**（`isHotBoot=true`、`-bootmode snapshot`，快照内存 `ram.bin`），guest 里的 hdc 守护还带着快照时的旧连接状态，不再向宿主 server 注册 → 5557 上永远等不到设备。

修复（顺序重要）：

```bash
# 1. 重启 hdc server，清掉陈旧端口状态
/opt/ohos-sdk/26/toolchains/hdc kill -r

# 2. 停掉卡住的实例
devecocli emulator stop SpatialPhone

# 3. 冷启动（devecocli start 没有 bootMode 参数，用原生二进制；
#    coldboot 保留数据，已装应用不丢）
/opt/command-line-tools/emulator/Emulator -start SpatialPhone -bootMode coldboot
```

之后 `hdc list targets` 应显示 `127.0.0.1:5555`。

预防：
- start 超时后**不要反复重试**，先 `ss -ltnp | grep 555` 看 Emulator 实际监听的端口；
- 不是 5555 → 基本就是陈旧 hdc server 状态，按上面三步走；
- 冷启动约 1~2 分钟，比热启动慢，但 guest 状态是干净的。
- **snapshot 热启动还可能损坏 guest 显示**（2026-10-24 实测）：宿主窗口撕裂/颜色怪异、`Emulator -screenshot` 抓出的画面全黑或花屏（文件极小，~26KB 纯色）——snapshot 恢复的 guest GPU 状态不完整。修复同上三步：停实例 → `hdc kill -r` → `-bootMode coldboot`。**日常启动一律用 coldboot**，不要用 devecocli start（其默认走 snapshot）。一键冷启动：`tools/start-both.sh`（停旧实例 → `hdc kill -r` → 三实例 coldboot〔折叠 5555 / 平板 5557 / 手机 5559，2026-10-26 起〕→ 等就绪 → 截图自检；2026-10-24 固化，10-26 随实例重建更新）。

### 2.6 截图

```bash
# 方式一（推荐，原生 Emulator 自带）
/opt/command-line-tools/emulator/Emulator -instance SpatialPhone \
  -screenshot -screenshotPath <已存在的目录>

# 方式二（hdc）
hdc shell snapshot -f /data/local/tmp/screen.jpeg
hdc file recv /data/local/tmp/screen.jpeg ./screen.jpeg
```

> 踩坑：`-screenshotPath` 指向**不存在的路径**时不会报错，静默存到默认目录 `~/Pictures/`。

### 2.7 devecocli Emulator 日常管理

```bash
devecocli emulator list                    # 实例列表
devecocli emulator start SpatialPhone      # 启动
devecocli emulator stop SpatialPhone       # 停止
devecocli emulator delete SpatialPhone     # 删除实例
devecocli emulator fold -i SpatialPhone    # 折叠屏折叠/展开
devecocli emulator power -i SpatialPhone   # 电源键
devecocli emulator battery -i SpatialPhone # 电量/充电状态
```

---

## 3. 路线 B：ohemu（OpenHarmony QEMU 社区镜像）

适用于：不需要 HDS 商用组件的基础功能/协议层测试；KVM 全速，资源占用低。

### 3.1 项目信息

- **预构建镜像（推荐）**：https://github.com/harmony-contrib/ohos-qemu — 最新 release `v20260818`，含 **x86_64 原生**镜像（宿主 KVM 直接跑，无 TCG 模拟开销），标准系统（可装应用、支持 HDC）
- **选镜像**：`openharmony-qemu-x86_64-x86_64_virt-phone.tar.gz`（手机形态，0.62 GB）；另有同尺寸 `-2in1`（平板/PC 形态）
- **其他来源（不推荐）**：
  - OpenHarmony-EduDist x86_64（5.0.2）：官方网盘链接 **2026-08-31 已过期**
  - `zestylemon/ohos-qemu-images`：仅 ARM64，在 x86_64 宿主上 TCG 模拟很慢
  - `openharmony/vendor_ohemu` 源码自构建：`./build.sh --product-name x86_64_virt`，需 200GB+ 磁盘 / 16GB+ 内存 / 数小时~数十小时

### 3.2 下载与启动

```bash
# 1. 下载 x86_64 phone 镜像（0.62 GB）
# 直连 GitHub 在本机失败，用 gh-proxy.com 加速（实测 ~2.2 MB/s）
curl -fL -o ~/Downloads/ohos-qemu-x86_64_virt-phone.tar.gz \
  "https://gh-proxy.com/https://github.com/harmony-contrib/ohos-qemu/releases/download/v20260818/openharmony-qemu-x86_64-x86_64_virt-phone.tar.gz"
# 校验（官方 digest，v20260818 phone）：a07b1ae43323350faef1de8a42532adfd610b2eb95ab0413dc0966e84832bd12
sha256sum ~/Downloads/ohos-qemu-x86_64_virt-phone.tar.gz
tar xf ~/Downloads/ohos-qemu-x86_64_virt-phone.tar.gz -C ~/

# 2. 启动（KVM 加速；**setsid 必须**，见踩坑记录）
cd ~/WorkSpace2/openharmony-qemu-x86_64-x86_64_virt-phone
setsid nohup ./launch/linux.sh -r 720x1560 -m 8G -s 4 > ~/WorkSpace2/ohemu.log 2>&1 < /dev/null &

# 3. hdc 连接（默认端口 5555，guest 启动约 60s 后监听）
hdc tconn 127.0.0.1:5555
hdc list targets -v
```

启动参数常用项：`-r WxH` 分辨率（默认 800x500）、`-m` 内存（默认 4096）、`-s` 核数（默认 4）、`--headless --vnc-display 21` 无窗口（VNC TCP 5921）、`--serial-port` 串口、`-a kvm|tcg|auto` 加速。日志在 `~/WorkSpace2/ohemu.log`。

### 3.3 API 版本兼容性

v20260818 镜像实际是 **OpenHarmony 7.0.0.32 / API 26**（`hdc shell param get const.ohos.apiversion` 实测），与工程 `compileSdkVersion 26.0.0` 匹配，**无需降级**。

### 3.4 ohemu 已知限制

- **HDS 组件不可用**：ohemu 是 OpenHarmony 社区版，不含 HMS 商用 SDK。工程 `runtimeOS: "HarmonyOS"` 时，HDS 静态导入（`@kit.UIDesignKit`）会导致模块加载失败（白屏）。需用 `tools/verify-on-ohemu.sh` 做构建期 HDS 降级。
- **无 `uinput`**：`which uinput` 为空，只能 `snapshot_display` 取首屏截图，不能模拟点按/滑动。依赖交互的验收须由人在真机/模拟器上确认。**【2026-10-25 更正】仅适用旧 ohemu 镜像——用户重建的 HarmonyOS 7.0.0(26.0.0) 镜像上 `uitest uiInput click` / `uitest dumpLayout` 实测可用（UIServer 通道，不依赖 uinput），点击级验收恢复自动化；dumpLayout 输出 JSON（扩展名仍 .xml）。**
- **一条命令跑通**：`tools/verify-on-ohemu.sh`（构建期降级 HDS + 构建/签名/安装/启动/截图/日志取证；`--revert` 还原；降级态不可提交）。

### 3.5 性能注意事项

- v20260818 预构建镜像是 **x86_64 原生**，宿主有 KVM 全速运行，无 TCG 开销
- 宿主资源（32 核 / 30G 内存 / 735G 余量）给模拟器 4 核 + 8G 内存即可
- 若改用 ARM64 镜像（zestylemon 等），x86_64 宿主上 TCG 模拟会很慢，不推荐

---

## 4. 两条路线对比

| | devecocli Emulator（路线 A） | ohemu（路线 B） |
|---|---|---|
| 镜像 | HarmonyOS 7.0.0(26.0.0) 商用 | OpenHarmony 7.0.0.32 社区 |
| HDS 组件 | 支持 | 不支持（白屏，需降级） |
| 沉浸光感材质 | 支持 | 不支持 |
| KVM 要求 | 需要 `/dev/kvm` | 需要 KVM 模块 |
| 启动速度 | 分钟级 | 秒级 |
| 资源占用 | >2GB | <2GB |
| 签名 | 需要 `sign-debug.sh` | 需要 `sign-debug.sh` |
| unsigned HAP | **可直接安装**（商用模拟器接受） | 装不上（需 debug 签名） |
| 适用场景 | HDS/商用 API 验证 | 协议层/基础功能测试 |

---

## 5. 通用：构建项目

```bash
source /opt/ohos-sdk/env.sh
export PATH=/opt/command-line-tools/bin:$PATH

# 安装依赖（已装则跳过）
ohpm install

# 构建（libxml2 shim 必需，见 §1）
LD_LIBRARY_PATH=$HOME/.local/share/ohos_libshim hvigorw --no-daemon assembleHap
```

产出：`entry/build/default/outputs/default/entry-default-unsigned.hap`

> `devecocli build` ≈ `hvigorw assembleHap` 薄封装（调 CLT 内置 hvigorw.js，另 merge `compile_commands.json` 供 LSP；不签名）。

---

## 6. 通用：签名 + 安装 + 启动

### 未签名 HAP 装不上

`error: verify signature failed. code:9568329` — 必须本地 debug 签名。

> **路线 A 例外**：devecocli 原生 Emulator（HarmonyOS 商用镜像）**接受 unsigned HAP**，无需签名即可 `hdc install`。仅路线 B（ohemu OpenHarmony 社区镜像）强制要求 debug 签名。

### 一键脚本

```bash
cd /home/cagp/WorkSpace2/kdeconnect-harmony

# 全流程：构建 + 签名 + 安装 + 启动
tools/sign-debug.sh

# 仅签名
tools/sign-debug.sh sign-only

# 仅安装（已有签名 HAP）
tools/sign-debug.sh install
```

签名材料全来自宿主 SDK（`/opt/ohos-sdk/26/toolchains/lib/`），**不需要 DevEco/华为账号**：
- `OpenHarmony.p12`（PKCS12，密码 `123456`）：内含 release 应用私钥 + profile debug 签名私钥
- `OpenHarmonyProfileDebug.pem`：profile 证书链（root, app-ca, profile-debug 三张）
- `UnsguedDebugProfileTemplate.json`：profile 模板（**注意模板里的 development-certificate 才是配对叶证书**）
- `hap-sign-tool.jar`：签名工具（`sign-profile` → `sign-app` 两步）

### 签名流程要点

1. profile 模板要填：bundle-name、版本、有效期（模板自带的 2021~2023 **已过期**）、`debug-info.device-ids` = 设备 UDID（`hdc shell bm get --udid`）
2. `keytool -exportcert` 必须加 **`-rfc`**（默认输出 DER 二进制，拼链全废）
3. 证书链顺序必须是 **leaf → 中间 CA → root**，单张证书报 `11013004 Profile cert must a cert chain`
4. `hap-sign-tool sign-app` 的 appCertFile 也用完整链；p12 里 `openharmony application release` 条目是**自签名**（issuer=自己），链验证会失败，必须用模板里 App CA 签发的那张同名证书
5. 签名算法按证书实际值：**SHA384withECDSA**（证书是 ecdsa-with-SHA384）
6. `-compatibleVersion 26` 对 .hap 必填
7. 换模拟器实例后 UDID 会变，重跑 `sign-debug.sh` 会自动重新取 UDID 重签 profile

### 安装并启动

```bash
export PATH=/opt/ohos-sdk/26/toolchains:$PATH

hdc install sign/entry-debug-signed.hap
# 成功输出: install bundle successfully.

# 启动应用
hdc shell aa start -b org.kde.kdeconnect -a EntryAbility
# 成功输出: start ability successfully.
```

> ability 名以 `module.json5` 中 `abilities[].name` 为准（本项目为 `EntryAbility`）。查错可用 `hdc shell bm dump -n <bundleName>`。

---

## 7. 通用：hypium 测试在模拟器上执行（2026-10-08 实测通过，27/27）

```bash
# 1) 构建测试 HAP
devecocli build --modules entry@ohosTest

# 2) 签名测试 HAP
HAP_UNSIGNED=$PWD/entry/build/default/outputs/ohosTest/entry-ohosTest-unsigned.hap \
HAP_SIGNED=$PWD/sign/entry-ohosTest-signed.hap tools/sign-debug.sh sign-only

# 3) 安装（前提：主 HAP 已装）
hdc install -r sign/entry-ohosTest-signed.hap

# 4) 执行
hdc shell "aa test -b org.kde.kdeconnect -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 120000"
```

判读：末行应为 `OHOS_REPORT_RESULT: stream=Tests run: N, Failure: 0, Error: 0, Pass: N`。

> ① 测试模块名是 `entry_test`（见 `entry/src/ohosTest/module.json5`），runner 为 `OpenHarmonyTestRunner`；
> ② 本流程**不需要 uinput**（不依赖点按），是 ohemu 上少见的"真执行"通道；
> ③ `ohosTest/resources/.../icon.png` 等二进制必须按 blob 提交（勿经文本化钩子改写）。

---

## 8. 日常操作速查

```bash
export PATH=/opt/command-line-tools/bin:/opt/ohos-sdk/26/toolchains:$PATH

# === 路线 A：devecocli Emulator ===
devecocli emulator list                    # 实例列表
devecocli emulator start SpatialPhone      # 启动
devecocli emulator stop SpatialPhone       # 停止
devecocli emulator delete SpatialPhone     # 删除实例

# === 路线 B：ohemu ===
# 启动：见 §3.2
# 停止：kill 掉 QEMU 进程

# === hdc 调试（两条路线通用） ===
hdc list targets                           # 设备列表
hdc shell hilog | grep -i kdeconnect       # 应用日志
hdc shell snapshot -f /data/local/tmp/screen.jpeg  # 截图
hdc file recv /data/local/tmp/screen.jpeg ./      # 拉取截图

# === 一键构建+签名+安装+启动 ===
cd /home/cagp/WorkSpace2/kdeconnect-harmony
LD_LIBRARY_PATH=$HOME/.local/share/ohos_libshim tools/sign-debug.sh
```

---

## 9. 踩坑记录

### 2026-09-03b：ohemu 实测（x86_64 phone v20260818，KVM 全速）

- 镜像下载：直连 GitHub 失败，`gh-proxy.com` 代理可用（~2.2 MB/s），sha256 与官方 digest 一致
- **`nohup ... &` 在工具/脚本会话里启动会被回收**：进程在 guest 启动 58s 处死掉；改 `setsid nohup ... < /dev/null &` 完全脱离会话后稳定存活
- 启动到 hdc 监听约 60s；hdc 用宿主 `/opt/ohos-sdk/26/toolchains/hdc`（Ver 3.2.0f）直接可连，**之前担心的 hdcd SELinux 问题在此镜像上不存在**
- 注意内存账：ohemu 默认给 8G；宿主机 30G，若同时开其他 VM，紧张时 ohemu 降到 `-m 4G`

### 2026-09-05：复验通过

- 重启后重跑全流程（启动 → `hdc tconn` → 签名 → 安装 → 启动 APP）全部一次通过，无新增坑
- UDID 在模拟器重启后保持不变（`6F70…14A`），已有 `sign/entry-debug-signed.hap` 直接复用，无需重新取 UDID 重签

### 2026-09-03：启用 Hyper-V 导致 VM 坏机

- **操作**：Win10 LTSC 21H2 guest 内管理员 PowerShell 跑 `dism /online /enable-feature /all /featurename:Microsoft-Hyper-V` + `VirtualMachinePlatform`，重启
- **结果**：卡自动修复循环，无快照可回滚 → 虚拟机删除重装
- **教训**：改系统级特性前先打快照；不再用 Win10 21H2 LTSC

### 协议两层（路线 A）

- CLI 层协议接受 `printf 'y\n' |` 管道；原生二进制层不读管道，必须用 `-license accept` 参数
- 只做第一层，`emulator start` 时原生二进制仍会拒绝启动

### hdc server 残留端口导致设备不出现（路线 A，2026-10-20）

- 现象：`emulator start` 成功但 `hdc list targets` 空；Emulator 监听 5557 而非 5555
- 根因：宿主 hdc server 残留进程持有旧 5555 注册 + Emulator snapshot 热启动 guest hdc 守护状态过期
- 修复：`hdc kill -r` → `emulator stop` → `Emulator -start <name> -bootMode coldboot`（见 §2.5）
- 预防：start 超时不要反复重试，先 `ss -ltnp | grep 555` 看实际端口

### /tmp 下放 shim 会丢

临时目录清理会把 libxml2 shim 删掉，症状是链接期莫名失败。shim 必须放稳定目录（`~/.local/share/ohos_libshim/`）。

### runtimeOS=HarmonyOS + ohemu = 白屏

工程 `runtimeOS: "HarmonyOS"` 时，HDS 静态导入（`@kit.UIDesignKit`）在 ohemu（OpenHarmony 社区版）上会导致模块加载失败（白屏）。hilog 必有 `SyntaxError: '@hms:hds.hdsBaseComponent' does not provide an export name 'HdsTabsController'`。用 `tools/verify-on-ohemu.sh` 做构建期 HDS 降级。

---

## 10. Win10 VM 路线（已搁置）

DevEco Studio 路线已搁置：Hyper-V 嵌套坏机过一次，且确认不需要 IDE 后不再优先。仅当 ohemu 的 OpenHarmony 社区版 API 不满足需求、需要商用 HarmonyOS NEXT 模拟器或 DevEco IDE 特有功能时再启动。

重装清单（2026-09-03 事故后）：
1. VM 配置：16G 内存 / 8 vCPU / 150G 磁盘；CPU host-passthrough + hyper-v enlightenments
2. 系统：Win10 23H2 或 Win11（不再用 21H2 LTSC）
3. 分阶段快照：装完系统 → 快照 A；装完 DevEco → 快照 B；开 Hyper-V → 快照 C
4. 兜底：宿主 ohemu + `hostfwd=tcp:0.0.0.0:5555-:5555` 暴露到 virbr0，VM 内 `hdc tconn <宿主IP>:5555`

---

## 11. 推荐路径

**日常开发（路线 B — ohemu）**：

1. 宿主写码 + 宿主构建（`hvigorw`，PATH 里有）
2. 宿主 ohemu 模拟器（KVM 全速，镜像已就位）
3. `tools/sign-debug.sh` 一键签名 + 安装 + 启动
4. `hdc` 直接连宿主模拟器调试（`hdc tconn 127.0.0.1:5555`）

**HDS/商用 API 验证（路线 A — devecocli Emulator）**：

1. `devecocli emulator start SpatialPhone`
2. 宿主构建（`hvigorw assembleHap`）
3. **unsigned HAP 可直接安装**：`hdc install <hap路径>`（无需签名）
4. `hdc shell aa start -b org.kde.kdeconnect -a EntryAbility`
5. `hdc` 连接调试（`hdc list targets`）

**Win10 VM 路线**：已搁置，见 §10。
