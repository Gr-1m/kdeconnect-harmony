# RUNBOOK —— A1 远程输入 / A2 通知读取 真机验收（MatePad Mini）

> 2026-10-11。DevEco。体例对齐 `RUNBOOK_KI1_REAL_DEVICE.md`。
> 适用设备：**MatePad Mini `MLR-AL10`**，serial `5KPBB25901205531`，UDID `8AF6B36863DF4E08536C7DA8EC1F2B1B1D79DC6FA1C7D12FF4BA740227030C5C`
> 对端：KDE 桌面（Omp 侧）`192.168.3.4`，TCP 1716 · 已验证与本机/平板**同网段**（平板 `192.168.3.3` / Win10 `192.168.3.26`）
> 待验版本：0.8.0（A1 远程输入 + A2 通知读取）
> **证据原则**：每条判据都要有**可复核的原始输出**（命令 + 输出），不接受"看起来是好的"。

---

## 0. 前置条件与**当前阻塞**（2026-10-11 实测）

| 项 | 状态 |
|---|---|
| 设备连接 | ✅ `hdc list targets` → `5KPBB25901205531` |
| 网络同段 | ✅ 平板 `192.168.3.3` · Win10 `192.168.3.26` · 桌面 `192.168.3.4:1716`（Win10 侧 `Test-NetConnection` = True） |
| **平板→桌面 L3** | ✅ **实测通**：平板 `ping 192.168.3.4` → `2 packets transmitted, 2 received, 0% packet loss`（26–40ms） |
| 桌面 1716 监听 | ✅ 有（`Test-NetConnection 192.168.3.4:1716` = True ⇒ `kdeconnectd` 在跑） |
| 平板侧 TCP 探测 | ⚠️ **不可判**：平板 shell 无 `/dev/tcp`（`sh: can't create /dev/tcp/…`）⇒ **不构成"不通"的结论**；以配对时的实际表现为准 |
| 应用已装 | ❌ 未安装 |
| **签名** | ❌ **阻塞（配额）**：安装未签名 HAP 报 `code:9568320 error: no signature file`；<br>`~/.ohos/config/` 15:08 只生成了 `default_kdeconnect-harmony_2YoD….{cer,csr,p12}`，**配套 `.p7b`（provision）缺失**；<br>既有 `Gr1m_kdeconnect-harmony_2YoD….p7b` 只授权 UDID `454D5505…`，**不含本平板 `8AF6B368…`** |

### ⚠️ 阻塞项与**预计解除时间**（用户 2026-10-11 确认）
**华为侧配额头寸受限**；按本项目开发历史，**约 1–2 天后（满 30 天）发放下月配额** ⇒ 届时在 DevEco Studio 完成自动签名即可放行。
> 其余前置（设备在连 / 三方同网段 / 桌面 1716 在监听）**均已就绪** ⇒ 配额一到即可**一次跑通**本 Runbook 全部判据。

### 需**用户**执行的一步（唯一阻塞项）
在 DevEco Studio 中完成**自动签名**（保证平板已连接）：
`File → Project Structure → Signing Configs → 勾选 "Automatically generate signature"` → 登录华为账号并同意生成。
成功后 DevEco 会把 `signingConfigs` 写入 `build-profile.json5`（**本仓约定：该配置不入库**，提交前需还原为 `[]`）。

---

## 1. 安装与启动

```bash
HDC="C:\Users\xiaoyi\AppData\Local\OpenHarmony\Sdk\26.0.0\toolchains\hdc.exe"
# 1) 构建（已签名产物由 DevEco 自动签名产出）
devecocli build                     # 或 DevEco GUI Build
# 2) 安装（用签名产物；路径随 DevEco 配置可能是 .../outputs/default/entry-default-signed.hap）
& $HDC -t 5KPBB25901205531 install -r <signed>.hap      # 期望：install bundle successfully.
# 3) 启动并清日志
& $HDC -t 5KPBB25901205531 shell hilog -r
& $HDC -t 5KPBB25901205531 shell aa start -a EntryAbility -b org.kde.kdeconnect
```

**判据 P0（安装启动）**
1. `install bundle successfully.`（无 `9568320/9568257`）
2. 启动后出现 native 栈就绪日志：`tcp listening` / `udp discovery init` / `native start ok`
3. **无白屏**；无 `jscrash`/`CPP_CRASH`

---

## 2. 完整验收（需桌面 KDE 对端）

### 2.1 连接与配对（前置链条）
1. 平板「发现设备」应看到桌面（UDP 发现）；
2. 点「配对」→ 两端验证码**逐位一致** → 确认 → 进入「已连接设备」；
3. 桌面侧 `kdeconnect-cli -l` 显示平板的 deviceId 并带 `(paired and reachable)`。

### 2.2 A1 远程输入（触控板 + 键盘）
入口（CodeArts MSG137 裁决1）：设备详情 → 第 6 个功能卡片「远程输入」→ **全屏对话框**。

| # | 操作 | 期望（桌面侧可观测） |
|---|---|---|
| A1-1 | 触控板区**单指拖动** | 桌面光标随之移动（方向一致、无跳变） |
| A1-2 | **单击**触控板 | 桌面左键单击（如选中图标） |
| A1-3 | **双击** | 桌面双击（如打开文件） |
| A1-4 | **双指点击** | 桌面中键（如浏览器新标签打开链接） |
| A1-5 | 底部**右键**按钮 | 桌面右键菜单 |
| A1-6 | **双指上下滑** | 桌面滚动（方向一致、不抖） |
| A1-7 | 键盘页输入 `hello` | 桌面焦点处逐字符出现 `hello` |
| A1-8 | 键盘页特殊键（BackSpace/Tab/Return/Esc/方向/F1） | 桌面相应生效 |
| A1-9 | 观察对话框头部键盘指示 | 对端就绪时显示「对端键盘就绪」（`state:true`） |

**判据 P1**：A1-1..A1-9 **全部**达成；移动**无卡顿累积**（节流窗口 16ms 有效：快速划动应连续跟随而非滞后爆发）。
**反例（判 FAIL）**：光标反向/跳变（增量换算错）；拖动结束后仍有残余移动（尾帧未收）；快速划动后桌面"爆发式"位移（节流合并错）。

### 2.3 A2 通知读取
入口（裁决1）：设备详情 → 「通知」**折叠区块**（折叠头显示「通知 (N)」）。

| # | 操作 | 期望 |
|---|---|---|
| A2-1 | 桌面制造一条通知（如 `notify-send "Test" "hello"`） | 平板「通知」区块展开后出现该条（appName / 文本 / HH:mm） |
| A2-2 | 折叠头计数 | 与实际条数一致 |
| A2-3 | 点某条「关闭」 | **仅本侧列表移除**；桌面通知**不受影响**（本期纯本地关闭，设计 §4） |
| A2-4 | 点「清空」 | 该设备通知全清 |
| A2-5 | 断链（关桌面 kdeconnectd 或断网） | 该设备通知**自动清空**（断链清账第 6 项）+ 通知区块随设备消失 |

**判据 P2**：A2-1..A2-5 全达成；**不得**因为通知累积导致 UI 卡顿（每设备上限 50，超出丢最旧）。

### 2.4 并发与稳定性（建议）
- 触控板连续操作 30s + 同时收通知 ⇒ 无卡死/无 THREAD_BLOCK；
- 切后台 30s 再回前台 ⇒ 链路与列表状态正确（KI-1 相关，见 `RUNBOOK_KI1_REAL_DEVICE.md`）。

---

## 3. 仅设备侧子集（**无桌面对端**时也能跑）
| # | 检查 | 判据 |
|---|---|---|
| D1 | 安装/启动 | 见 §1 P0 |
| D2 | 「远程输入」卡片 → 对话框打开 | 看到触控板区 + 键盘/触控板页签 + 左/中/右三键 + 32 个特殊键 |
| D3 | 手势**不致崩**（无对端时发包失败应只记日志） | 拖动/点击/滚动手势操作 30s，无 crash；hilog 有 `sendPacket failed (not encrypted yet?)` |
| D4 | 设备详情「通知」区块 | 折叠头「通知 (0)」+ 空态提示；展开/收起正常 |
| D5 | 无对端时点「远程输入」 | 无已连接设备 ⇒ toast「无已连接设备」（不崩） |

> D2–D5 为**交互**检查 ⇒ **须人工操作**（本机无 `uinput`，自动化不可达）。

---

## 4. 取证口径（照抄即用）
```bash
HDC="C:\Users\xiaoyi\AppData\Local\OpenHarmony\Sdk\26.0.0\toolchains\hdc.exe"
D=5KPBB25901205531
& $HDC -t $D shell hilog -r                                     # 开测前清缓冲
& $HDC -t $D shell hilog | Select-String 'KDC|kdeconnect|RemoteInput|mousepad|notification'
& $HDC -t $D shell hilog | Select-String 'THREAD_BLOCK|jscrash|CPP_CRASH|OnAppFrozen'   # 反证
devecocli ui screenshot --device $D --path .vtmp\a1.png         # 截图留证
# 桌面侧（Omp）：kdeconnect-cli -l   /   notify-send "Test" "hello"
```

---

## 5. 结论模板
```
版本：0.8.0  设备：MatePad Mini 5KPBB25901205531  对端：192.168.3.4
签名：<通过/阻塞：错误码>
§1 P0        ：PASS / FAIL  （证据：…）
§2.1 配对     ：PASS / FAIL
§2.2 A1(9项) ：PASS / FAIL  （失败项：…）
§2.3 A2(5项) ：PASS / FAIL
§2.4 并发     ：PASS / FAIL
未覆盖/待补    ：<如实列出，如"手势在 ohemu 不可自动化，故须人工">
```

---

## 6. 不可自动化与边界（如实声明）
- **触控板/键盘手势**、**通知区块交互**：属点按类交互，ohemu 无 `uinput` ⇒ **只能人工**；
- 「桌面控制手机」方向被平台封死（`inputEventClient` 仅系统应用）⇒ 本 Runbook **不涉及**；
- 对端关闭通知（`kdeconnect.notification.request`）、图标 payload 属**后续增量**（设计 §0 待决）⇒ 不在本次判据内。

—— DevEco
