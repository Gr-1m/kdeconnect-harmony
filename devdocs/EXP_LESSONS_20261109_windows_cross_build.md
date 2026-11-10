# 经验记录：Windows(Win10) 交叉编译打通（2026-11-09）

> 结论：native 全 Rust 栈已能在 Win10 上 `hvigorw --no-daemon assembleHap` 出包、装真机、起服务
> （`79bfe87` + `win10-ssh.sh` 补丁；HAP 2026-11-09 23:19，真机 `63Q0226131002161` 起栈 `trusted=2`）。
> 本文记录**四层失败链**与可迁移经验，配置细节见 `devdocs/CPP_GUIDE.md` §9。

## 1. 失败链（按被发现的顺序，每层都真实发生）

| # | 现象 | 真实根因 | 修法 |
|---|---|---|---|
| 1 | `CMakeLists.txt:32 FATAL_ERROR 未找到 OHOS SDK native 目录` | Windows 上可执行文件名是 `clang.exe`，`EXISTS ".../llvm/bin/clang"` 恒假 | `2b49851`：判据加 `clang.exe` 双判 |
| 2 | 工作区 `RUST_CLANG/RUST_LLVM_AR` 被写成 `// placeholder` → 全平台配置失败 | 协作者直接改 `cpp/**`（且 `//` 不是 CMake 注释，CMake 用 `#`） | 回退 + 立规「非 owner 只提补丁申请」（MSG201/202） |
| 3 | `cc-rs: failed to find tool "C:/Program"` | cc-rs 按空格切分 `CC` 值，而 SDK 装在 `C:\Program Files\…`；且 `CC_<triple>` 由 `add_custom_command` **显式注入** ⇒ 外部 6 个 `$env:`/`setx` 全被覆盖 | `57cbfbf`：允许 `OHOS_LLVM_LINK` 覆盖 |
| 4 | 打了补丁仍失败，`OHOS_LLVM_LINK` 被忽略 | **`WIN32` 在本工程恒假**：交叉编译到 OHOS（`CMakeCache: CMAKE_SYSTEM_NAME=OHOS`）⇒ `if(WIN32)` 永不进入 | `79bfe87`：改按「磁盘上是否真有 `clang.exe`」判宿主 |
| 5 | `--sysroot` 里也有空格 | 只把 junction 指到 `llvm` 不够：`CC` 值同时含 `…/llvm/bin/clang.exe` 与 `--sysroot=…/sysroot`，**两个路径都要无空格** | `79bfe87`：`RUST_NDK_ROOT`（= `OHOS_LLVM_LINK`）统一派生 `llvm` + `sysroot`；junction 指向 `native` |
| 6 | Windows 无 `/bin/sh` | 链接器此前是仓库内 sh wrapper | `79bfe87`：Windows 改用 `clang.exe` + `CARGO_TARGET_*_RUSTFLAGS=-C link-arg=--target/--sysroot` |
| 7 | `PackageHap` 报 `spawn java ENOENT`；`DEVECO_SDK_HOME` 被判 invalid | 远程/裸 shell 没有 `JAVA_HOME`；`set VAR=值` 带尾随空格 | helper 注入 `JAVA_HOME`/`PATH`（DevEco `jbr`）+ `set "VAR=值"`（`6bd6bb0`） |

## 2. 可迁移经验（与项目无关的通用规律）

1. **交叉编译时不要用 `WIN32` 判宿主**：`WIN32` 描述的是**目标**平台；宿主用 `CMAKE_HOST_WIN32`，
   或干脆用「磁盘上是否存在某文件」这种**证据式判据**（本项目最终采用后者：宿主无关、不会误判）。
2. **先读构建系统自己的产物，再猜**：`CMakeCache.txt`（`CMAKE_SYSTEM_NAME=OHOS`）与 `build.ninja`
   （实际注入的 `CARGO_TARGET_*_LINKER` / 是否有 `RUSTFLAGS`）能一分钱不花地否定错误假设；
   本轮两处「是不是没生效」都是这样确证/推翻的。
3. **被显式注入的环境变量会覆盖外部同名的环境变量**：查「设了没用」类问题，先看构建脚本里是否
   `set(ENV)`/`-E env` 显式赋值（本项目 `CC_/AR_/CARGO_TARGET_*` 均被 `add_custom_command` 注入）。
4. **空格是最常见的隐式分隔符**：任何「用空格传参」的变量（`CC`、`CFLAGS`、`RUSTFLAGS`）在
   Windows 默认路径下都会炸；解法不是加引号猜语法，而是**消除空格**（junction/无空格前缀），
   并把**派生出的每一条路径**都落到无空格根下（本轮 surface 就是 `sysroot`）。
5. **静默失效的分支比报错的分支危险**：`if(WIN32)` 假 ⇒ 退化成「Linux 语义在 Windows 上跑」，
   表现为别人的包（`ring`/cc-rs）报错，定位成本极高。遇到「补丁打了但没变化」，先证明分支是否进入。
6. **失败要 fail-fast 且可操作**：`message(FATAL_ERROR "…请建 junction 到 native 并 setx …")`
   比 20 分钟后 cc-rs 的 `failed to find tool "C:/Program"` 有价值得多。
7. **远端取证通道一次投入长期收益**：`tools/win10-ssh.sh`（SSH 免密）把「Windows 侧构建/装真机/拉日志」
   从「跨机消息轮询」变成一条命令；本轮 Win10 侧全部结论都来自它。
8. **同一份文件不要两台机器/两个 agent 同时改**：第 2 层事故就是双写；跨机工作区靠 Syncthing 同步时，
   非 owner 只提交补丁申请（`AgentsConversion/MSG*`），由 owner 落地。

## 3. 最终可用配方（Win10，一次性）

```powershell
# ① 无空格 junction 指向 native（内含 llvm/ 与 sysroot/）——目录名随意
cmd /c rmdir C:\Users\<user>\ohos-llvm            # 若旧 junction 指向 native\llvm，先删除
cmd /c mklink /J C:\Users\<user>\ohos-llvm "<sdk>\default\openharmony\native"
setx OHOS_LLVM_LINK C:\Users\<user>\ohos-llvm
# ② 构建
hvigorw --stop-daemon                              # daemon 不继承新环境变量
hvigorw --no-daemon assembleHap                    # 或 Linux 侧：tools/win10-ssh.sh build
```
前置：Rust 工具链 + `rustup target add aarch64-unknown-linux-ohos x86_64-unknown-linux-ohos`。
远程驱动另需 `JAVA_HOME/PATH → DevEco Studio\jbr`（helper 已内置）。

## 4. 证据（2026-11-09）

- `CMakeCache.txt`（Win10）：`CMAKE_SYSTEM_NAME:UNINITIALIZED=OHOS`，无 `WIN32` 项；
- 本地仿真（抽文件真实代码块 `cmake -P`）：`.exe` 分支全链路无空格 / 含空格 → FATAL / 无 `.exe` → sh wrapper；
- Linux 零改动：`build.ninja` 里 `CARGO_TARGET_…_LINKER=…/rust/wrappers/aarch64-linux-ohos-clang` 且无 `RUSTFLAGS`；
- 门禁：`hvigorw assembleHap` ✅、`cargo test -p kdc_native`（含 E 码负路径）✅；
- Win10 远程：`assembleHap` BUILD SUCCESSFUL（HAP 23:19）→ `hdc install` ✅ → `aa start` ✅ →
  hilog `net stack started (full Rust): deviceId=db67beed… trusted=2`。

## 5. 沿革

| 提交 | 作用 |
|---|---|
| `2b49851` | `clang`/`clang.exe` 双判（Windows 存在性判据） |
| `57cbfbf` | `OHOS_LLVM_LINK` + 时空格 WARNING（**`if(WIN32)` 静默失效**） |
| `79bfe87` | 弃用 `WIN32`（按 `.exe` 存在判定）+ `RUST_NDK_ROOT` 统一派生 `llvm`/`sysroot` + Windows 链接器 `clang.exe`+RUSTFLAGS + 含空格 FATAL |
| `6bd6bb0`/`cd4ed14` | `win10-ssh.sh`：`JAVA_HOME/PATH`、`set "VAR=…"` 引号、退出码与日志分支 |
