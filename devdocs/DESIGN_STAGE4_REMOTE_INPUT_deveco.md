# DESIGN_STAGE4_REMOTE_INPUT_deveco — 阶段4 方向B（远程输入 / mousepad）接口设计

> 2026-10-08。作者 DevEco。**状态：待 AtomCode 评审**（CodeArts MSG130 §4.4「关键原则：先让 AtomCode 评审再改动」）。
> 依据：CodeArts MSG130 §4.2–4.4、`devdocs/PROJECT_ROADMAP.md` §方向B、`docs/11-功能点字典.md`（mousepad 行）、
> `FEATURE_GAP.md` #4（我方 RemoteInput 只发不收 ⇒ 本次补齐"发"的 UI 与字段）。
> 现状：`plugins/RemoteInputPlugin.ets`（21 行，仅声明 caps）+ `Index.ets` 已注册；**无 UI**。

---

## 0. ✅ 协议分歧已解决（原前置条件，2026-10-08 关闭）

原疑问：MSG130 §4.2 写 `click` 为字符串 `"single"/"double"/"middle"`，我据 Android 印象提出应为**三布尔**。

**结论（CodeArts MSG132 §2 schema 核对 + AtomCode MSG134 §一/§二 独立复核，全部坐实）**：
- 点击 = **四个布尔** `singleclick`/`doubleclick`/`middleclick`/**`rightclick`** ⇒ **我的判断正确，MSG130 有误**；
- `scroll` = **boolean 标记**（不是增量值）⇒ **MSG130（string）与我的设计（float）都错**，已按 schema 更正；
- `keyboardstate` 的字段是 **`state`**（非我写的 `visible`）⇒ 已更正。

⇒ 字段名/类型以 §1.1–§1.3 为**唯一事实来源**（下文已全部按此重写）。**B0 关闭，B1b 解锁**。

## 1. 协议契约

| 方向 | packet type | 发送/接收方 |
|---|---|---|
| outgoing | `kdeconnect.mousepad.request` | 我方 → 桌面（鼠标/键盘事件） |
| incoming | `kdeconnect.mousepad.keyboardstate` | 桌面 → 我方（对端键盘状态，用于 UI 提示） |

### 1.1 `mousepad.request` body 字段（**全部可选，按需择字段**）
> 字段名/类型已按 schema 核定（AtomCode MSG134 §一/§二，独立复核坐实；MSG130 §4.2 的 `click` 字符串表述已废止）。

| 字段 | 类型 | 语义 |
|---|---|---|
| `dx` / `dy` | number | 位移增量（px）。**`scroll` 为 true 时**表示**滚动**增量，否则为鼠标移动增量 |
| `scroll` | boolean | **滚动标记**（schema 原文："Whether the associated dx/dy movement is a scroll event"）—— **不是**增量值 |
| `singleclick` / `doubleclick` / `middleclick` / `rightclick` | boolean | 左键 / 双击 / 中键 / **右键**（四布尔；`rightclick` 本期实现） |
| `key` | string | 普通字符键（minLength 1） |
| `specialKey` | number | 特殊键码（0–32 **下标语义**，见 §1.3；**0 无效，UI 不得发出**） |

**本期不采用**（AtomCode MSG134 §四 裁决）：`singlehold`/`singlerelease`（拖拽，触控板模型下无自然交互位）、
`alt`/`ctrl`/`shift`/`super`（修饰键，桌面 wayland 实现对 `specialKey` 不生效 ⇒ 平台不一致）、`sendAck`（echo，键盘本期只发不收）。

**设计准则**：**一个事件一次发一帧**，只带本次变化所需字段（移动帧 `{dx, dy}`；滚动帧 `{dx, dy, scroll: true}`），不合并、不批量。

### 1.2 `keyboardstate` body（incoming，只读展示）
| 字段 | 类型 | 语义 |
|---|---|---|
| `state` | boolean（**required**） | 对端键盘**就绪、可接收按键**（`true`=ready / `false`=idle）—— 非"软键盘接管提示" |

> 现有骨架已 `return true` 吞掉该包并记日志 ⇒ 本次**仅增加解包 + 事件上报**，不改路由。

### 1.3 `specialKey` 码表（跨端契约 = **下标**，各平台只换键码值）
KDE 桌面 `SpecialKeysMap` 原文（`x11remoteinput.cpp:27`，AtomCode MSG134 §三.4）：
```
0 Invalid / 1 BackSpace / 2 Tab / 3 Linefeed / 4 Left / 5 Up / 6 Right / 7 Down /
8 PageUp / 9 PageDown / 10 Home / 11 End / 12 Return / 13 Delete / 14 Escape /
15 SysReq / 16 ScrollLock / 17 Ctrl(L) / 18 Alt(L) / 19 Shift(L) / 20 Super(L) / 21–32 = F1–F12
```
约束：桌面端校验 `specialKey > 0 && < size` ⇒ **0 不得发出**；固化 `plugins/RemoteInputKeymap.ets` + 表驱动单测。

## 2. 插件层：`RemoteInputPlugin` 扩展

> **实施进展（2026-10-08）**：B0（字段名裁决）未决，但**交互逻辑与字段名无关** ⇒ 已先落地两个纯逻辑模块（含 24 个单测，已构建通过）：
> | 模块 | 职责 |
> |---|---|
> | `plugins/MousepadThrottle.ets` | 增量**合并 + 时间窗节流**（`due(nowMs)`/`take(nowMs)`，时钟由调用方注入 ⇒ 可确定性单测） |
> | `plugins/MousepadInput.ets` | `MousepadInputPipeline`：累计偏移→增量→节流→**注入式 `MousepadSink`**；`tap`/`scrollBy`/`typeText` 透传 |
>
> **`MousepadSink` 是唯一的字段名落点**：其实现（真正发包的 adapter）待 B0 确认后写，本层零字段依赖。

```ts
// MousepadSink 的实现 = 唯一字段名落点（字段已定，见 §1.1）
sendMousepadRequest(body: MousepadRequestBody): boolean   // → this.send('kdeconnect.mousepad.request', body)

// RemoteInputPlugin 侧语义化薄封装（UI 只调这些；增量/节流已在 Pipeline/Throttle 内）
sendMouseMove(dx: number, dy: number): boolean            // 体 {dx, dy}
sendScroll(dx: number, dy: number): boolean               // 体 {dx, dy, scroll: true}（§二.3 裁决）
sendClick(button: MousepadButton): boolean                // MousepadButton = 'single'|'double'|'middle'|'right'
sendKey(text: string): boolean                            // 逐字符发（体 {key}）
sendSpecialKey(code: number): boolean                     // 体 {specialKey}；code 必须 1..32（§1.3）
```

- **限频（关键）**：移动事件高频 ⇒ 由 `MousepadInputPipeline`（内嵌 `MousepadThrottle`）做**合并 + 节流**，避免刷爆 TLS 通道与对端；
- **不新增 caps**：`mousepad.request` 已在 outgoing 声明 ✓（caps 一致性由既有 `PluginRegistry.test.ets` 锁定）；
- 收包路径新增 `keyboardstate` 解析 → `notifyEvent(...)`。

**备注（AtomCode MSG134 §二 非阻塞项）**：
1. **vp→桌面像素缩放因子**：手势 offset 为 vp，桌面期望 px ⇒ 缩放因子在 B1 定（先取 1.0，真机对桌面实测后调）；
2. **键盘只处理"追加输入"**（§4.2）：以文本长度差取新增字符，**不处理删除/光标移动**（本期范围）。

### 2.1 交互逻辑不变量（已由单测锁定）
① 累计偏移→增量（防光标跳变）；② 手势结束**收尾**不丢尾帧；③ 零位移不发包；④ 不 sleep/不阻塞；⑤ 手势取消丢弃残留不补发。

## 3. 事件通道（复用 `textEvent`，不加新契约）

沿用批1 的**类型化事件**（不做 JSON 字符串往返）。`keyboardstate` 低频且只有一个布尔 ⇒ 决策**复用 `textEvent`**：
```ts
// 复用既有 textEvent 机制，kind 取 'mousepadKeyboardState'
kind: 'mousepadKeyboardState'   // data = 'ready' | 'idle'   （对应 §1.2 的 state: true/false）
```
> AtomCode MSG134 §二.4 **同意**"复用 textEvent"的决策；仅把两态取值由 `'visible'|'hidden'`
> 更正为 **`'ready'|'idle'`**（严格对应 schema 的 `state` 语义）。

## 4. UI 层设计

### 4.1 触控板（P0，优先；入口形态见 §5-6 与 §7-1 裁决 = **底部功能卡片 + 全屏对话框**）
| 手势 | 事件 | 发送 |
|---|---|---|
| 拖动 | `PanGesture`（`onActionUpdate`） | `pipeline.dragTo(offsetX, offsetY, now)` →（转增量+节流）→ `{dx, dy}` |
| 单击（左键） | `TapGesture(1)` | `{singleclick: true}` |
| 双击 | `TapGesture(2)` | `{doubleclick: true}` |
| 双指点击（中键） | `TapGesture` fingers=2 | `{middleclick: true}` |
| **右键** | 底部**右键按钮** | `{rightclick: true}`（§二.5 裁决：本期做；**原设计误映射为 `'middle'`，已改**） |
| 双指上下滑 | `PanGesture`(fingers:2) | `{dx, dy, scroll: true}`（**`scroll` 为布尔标记**，见 §1.1） |

- **增量来源**：`PanGesture` 的 `event.offsetX/offsetY` 是"自手势起点的累计偏移" ⇒ 由 `MousepadInputPipeline` 自维护基线做差（已有单测锁定）；
- **节流**：`onActionUpdate` 可达 120Hz ⇒ `MousepadInputPipeline`（内嵌 `MousepadThrottle`，16ms≈60Hz）合并发送；
- **缩放**：vp→px 缩放因子见 §2 备注 1（B1 先取 1.0）。

### 4.2 键盘（P1）
- `TextInput` 输入 → `onChange` **取新增字符**（维护上次文本长度做差）→ `sendKey(ch)`；
- **只处理追加输入**：不处理删除/光标移动（§2 备注 2）；
- 特殊键行（Backspace/Tab/Return/Delete/Escape/方向键/PageUp·Down/Home·End/F1–F12）→ `sendSpecialKey(code)`，**码表见 §1.3（下标语义，`0` 禁发）**；
- ⚠️ 不做 IME 级接管（`kdeconnect.mousepad.echo` 本期不做，§7-5 裁决 ✓）。

## 5. 边界与不变量（不得回退）

1. **不新增权限**：mousepad 走既有 packet 通道，无需任何新 permission ✓；
2. **native 零改动**（MSG130 §4.2 已确认）✓；
3. **发送一律经 `PluginBase.send()`**（自动带 `KDC slow plugin send` 计时探针）⇒ 不得绕过直调 native；
4. **限频不引入 sleep**：节流用"时间戳比较 + 丢弃"，**不得**在 UI 线程阻塞等待；
5. **不改变既有 caps**：`mousepad.request`(out) / `mousepad.keyboardstate`(in) 保持原样（有测试锁定）；
6. **入口形态（已裁决 §7-1）**：**底部功能卡片按钮**（第 6 个功能按钮）+ 点击开**全屏对话框**承载触控板/键盘（触控区靠全屏 dialog 满足，**不动现有 4 页签**）；设备目标 = `selectedDeviceId` → 回退首个"已配对且在线"设备 → 无则 toast「无已连接设备」。

## 6. 拆分顺序与验收

| 步 | 内容 | 产出 | 验收 |
|---|---|---|---|
| B0 | 字段核对 | ✅ **完成**（AtomCode MSG134 §一/§二；scroll=boolean、`state`、三布尔+rightclick） | 字段名/类型已定 |
| **B1a** | **交互纯逻辑（已交付）** | `plugins/MousepadThrottle.ets` + `plugins/MousepadInput.ets` | ✅ `arkts_check` + `build` 通过；`MousepadThrottle.test.ets`(9) + `MousepadInput.test.ets`(15) = **24 用例** |
| B1b | `MousepadSink` 实现 + `RemoteInputKeymap.ets` + 收包解析 | `plugins/RemoteInputPlugin.ets`、`plugins/RemoteInputKeymap.ets` | ✅ **已解锁**（B0 完成）；`devecocli build` + 表驱动单测 |
| B2 | 触控板 UI | `components/RemoteInputDialog.ets`（**全屏对话框**，§7-1 裁决） | 构建 + ohemu 冒烟（**无法点按** ⇒ 手势生效需真机） |
| B3 | 键盘 UI | 同上文件内第二区 | 同上 |
| B4 | 接线（Index.ets：第 6 个功能按钮 + 事件订阅） | `pages/Index.ets` | `assembleHap` + `check-injection-contract.py` |

**与测试的关系**：B1a/B1b 的节流/字段择取/码表是**纯逻辑** ⇒ hypium 单测可在 ohemu 真跑（沿用 D1 通道）；
B2/B3 的**手势行为**在 ohemu 上不可自动化（无 `uinput`）⇒ 须真机验收。

**附加项（AtomCode MSG134 §五）**：补 `DeviceController` 的 `pairingRequest` 用例（P2，随 B1 搭车）；3×P3 随 B1 搭车。

## 7. 评审裁决结果（AtomCode MSG134，2026-10-08）

原 §7 五项疑问**已全部裁决**：

| # | 疑问 | 裁决 |
|---|---|---|
| 1 | 入口形态 | **②底部功能卡片按钮** + **全屏对话框**承载触控板/键盘（否 ① 第 5 页签：挤底栏 + `syncSelectedDevice` 漂移使归属易混淆；③ 留后备，逻辑层不依赖入口形态） |
| 2 | 点击字段 | **三布尔**（schema 为准）；MSG130 §4.2 的 `click` 字符串**有误**，CodeArts 负责更正 |
| 3 | `scroll` 类型 | **boolean 标记**（既非 string 也非 float） |
| 4 | `specialKey` 码表 | **照搬 KDE `SpecialKeysMap` 下标语义**（原文见 §1.3）；`0` 禁发；固化 `RemoteInputKeymap.ets` + 表驱动单测 |
| 5 | 键盘范围 | **同意**只发不收（echo 属桌面 IME 侧） |

**额外裁决**：`rightclick` **本期做**；`singlehold`/`singlerelease`、修饰键 **本期不做**。

**设计评审结论**：通过（附上述 5 处必改）——本文件已按此修订，待评审方核 diff 放行 B1。

## 8. 风险
| 风险 | 影响 | 缓解 |
|---|---|---|
| 字段名/类型错（§0） | 桌面收到无法识别 ⇒ 功能全废 | **B0 前置核对**；落码后以真机对桌面实测为准 |
| 高频移动刷爆通道 | 卡顿/丢包（此前有 `KDC slow send` 先例） | 60Hz 节流 + 合并同向增量 |
| 手势增量算错 | 光标跳跃/反向 | 组件内自维护上次 offset，单测覆盖差值与边界 |
| ohemu 无法验证手势 | 回归缺口 | 明确记为真机验收项，不假装已验 |

—— DevEco（待评审）
