# RUNBOOK：KI-1 真机验收（App 切后台断链 / 后台能力失效）

> 适用：验证 KI-1 修复（**短时任务 + 停栈迁移**）在**真机**上生效。
> **ohemu 无法验收本条**（模拟器没有真机那套后台冻结策略，必然"看起来正常"），ohemu 只做「不回归」。
> 依据：`devdocs/KNOWN_ISSUES.md` KI-1（根因 = 真机 `memmgrservice/MM: OnAppFrozen` 冻结后台进程）。

## 0. 前置

- 真机上已安装**含修复的构建**（由 DevEco 侧按省配额方案构建安装）；
- 桌面（本机）KDE Connect 正常、`kdeconnect-cli` 可用；
- **手机与桌面时钟同区**（后续要拿时间戳对齐双方日志，务必先核）：
  ```bash
  hdc -t <target> shell date    # 手机
  date                          # 桌面
  ```
- 手机与桌面**已配对**；未配对先配对。
- 手机接入（**零 root 优先**）：
  ```bash
  # 首选：无线调试（手机：设置 → 系统 → 开发者选项 → 无线调试，取其 IP:端口）
  hdc tconn <手机IP>:<端口>
  hdc list targets -v           # 期望该行 Connected；若 Unauthorized 需在手机上点「允许调试」
  ```
  USB 备选：`hdc` 需能读写 `/dev/bus/usb/...` 节点，而系统自带 `51-android.rules` 的华为段
  **只覆盖 ADB 接口、不匹配 HDC 接口** ⇒ 需要 root 规则，**命令交用户执行**：
  ```bash
  echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="12d1", MODE="0660", GROUP="uucp"' | sudo tee /etc/udev/rules.d/51-harmony-hdc.rules
  sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=usb
  ```

## 1. 记录被测构建（必须先做）

```bash
TARGET=<target> tools/phone-diag.sh info
```

记录：**包名**（工具自动探测；改名前后各一）、`versionName`/`versionCode`、`appProvisionType`、
`cpuAbi`、**native 库 mtime（= 该包的实际构建时刻）**、设备时间。
> 不记录构建标识，结论无法与代码对应（例：真机上现存旧包 `org.kde.kdeconnect.harmony` 就与主线不同）。

## 2. 前台基线（先证明传输通路本身没问题）

1. App 里连接桌面，等到显示已连接；
2. 桌面 `kdeconnect-cli -l` 应显示目标设备 `(paired and reachable)`；
3. **前台状态下**从桌面分享一个文件 ⇒ App 应收到（「文件」页可见）。
   - 若前台都失败 ⇒ 先解决通路问题（**不属于 KI-1**），本次验收作废。

## 3. 抓取 + 复现（一次跑完，注意配额）

```bash
TARGET=<target> tools/phone-diag.sh capture 180     # 流式 hilog + 桌面侧每 2s 状态
```

capture 开始后依次：

1. 在 App 里**连接桌面**（若尚未连接）；
2. **按 Home 切到后台**（记大致时刻；以手机日志 `AppLifeCycleManager: … isForeground: false` 为准）；
3. 桌面**分享一个文件**给该设备（`kdeconnect-cli --share <文件> --device <deviceId>` 或 GUI）；
4. **保持后台 60~90 秒**：期间不要回前台、不要重装/重启 App。

## 4. 判定（PASS / FAIL）

| # | 观测点 | 取值来源 | PASS | FAIL（没修好 / 没生效） |
|---|---|---|---|---|
| 1 | 后台期间是否申请到短时任务 | 手机 hilog `transient task id=… delay=…ms` | 有该行 | 无 ⇒ 钩子没跑到（查 `onBackground` 是否被调用） |
| 2 | 传输结果 | 手机 `[KDC-PAYLOAD] id=… state=…` | `state=finished` | `state=failed code=110 payload handshake/accept timeout` |
| 3 | 后台期间链路 | 桌面 `kdeconnect-cli -l`（capture 的 `.desktop` 文件，含变化点） | 持续 `(paired and reachable)` | 掉回 `(paired)` |
| 4 | 原生栈是否被冻结 | 手机 `KDC-NETLOOP` 时间戳连续性（约每 5s 一条） | 无断档 | 出现明显断档（= 被冻结） |
| 5 | 系统冻结事件 | 手机 hilog `memmgrservice/MM: OnAppFrozen` | 不出现；或**晚于**短时任务超时（`delay` 到期后） | 在链路应存活期间出现 |
| 6 | 降级路径 | 手机 hilog `requestSuspendDelay failed` / `9900002` | 无 | 有 ⇒ 配额或校验失败，见 §7 |

**判定规则**

- 1+2+3 全 PASS 且 4 无断档 ⇒ **修复生效**；
- 2/3 FAIL、但 1 出现且 5 也出现 ⇒ 申请了短时任务仍被冻结 ⇒ 短时任务**没起作用**（时长/时机问题）
  ⇒ 记录 `actualDelayTime` 与 `OnAppFrozen` 的**时间差**并回报；
- 1 未出现 ⇒ 修改没生效（先查构建是否真的是含修复的包，见 §1）。

## 5. 取证归档

保留并（**脱敏** deviceId/uid 后）记入：

- `devdocs/KNOWN_ISSUES.md` KI-1 的「验收记录」；
- `AgentsConversion/HOUSEKEEPING.md` 的待办状态；
- 原始文件：`/tmp/phone-<时间戳>.log`、`/tmp/phone-<时间戳>.log.desktop`（桌面侧每 2s 状态）。

归档必含：被测构建标识、开始/结束时刻、判定结果、任何异常行（如 `code=110`、`OnAppFrozen`、配额错误）。

## 6. 疑难与坑（均为实测踩过）

- **不要用 `hilog -x` 抓长窗口**：`-x` 的语义是 **`--exit`**（把缓冲读一遍即退出），**不流式**
  ⇒ 长窗口实际只 dump 一次、会漏掉整个事件（本次实测踩到）。用**无参 `hilog`**（流式），
  或先 `hilog -x` 做一次性 dump 再 `hilog` 跟踪。
- **App 日志的过滤**：真机前缀形如 `A00001/<bundleName>/KDEConnect`；也可先
  `hdc shell "ps -ef | grep kdeconnect"` 拿 **PID**，再按 PID 过滤（最可靠）。
- **旧包名**：改名前的构建是 `org.kde.kdeconnect.harmony` ⇒ `bm dump -n org.kde.kdeconnect` 会报错；
  `tools/phone-diag.sh` 已自动探测（`bm dump -a | grep -i kdeconnect`）。
- **无线调试端口会变**：手机重开无线调试后端口变化 ⇒ 需重新 `hdc tconn` 并更新 `TARGET`。
- **`Unauthorized`**：去手机确认「允许调试」弹窗（可能在触发一次 `hdc shell` 后才弹出）。
- **`force stop` 会造成假证据**：`tools/sign-debug.sh` / `launch-app.sh restart` 会强停应用，
  日志里随之出现停栈行 ⇒ **验收窗口内不要重装/重启**。

## 7. 配额纪律

- 短时任务有**当日配额**：`getTransientTaskInfo()`（`@since 20`）返回 `remainingQuota`(ms) 与在途任务表；
- 每次验收**只跑一次** capture；**不要反复切前后台刷任务**；
- 实现侧应保证：仅在有活跃链路/在途 payload 时申请、**一次后台会话只申请一次**、回前台/销毁立即
  `cancelSuspendDelay`；失败（`9900002`/配额耗尽）记日志 + 降级，**不重试风暴**。

## 8. 与 ohemu 的关系

- ohemu 只验**不回归**：`LD_LIBRARY_PATH=$HOME/.local/share/ohos_libshim hvigorw --no-daemon assembleHap`
  成功 → 装机启动 → `plugin routes registered: 7` → 可连桌面；
- **不要**用 ohemu 的"看起来正常"否定或肯定本条（它没有 `OnAppFrozen` 这套策略）。
