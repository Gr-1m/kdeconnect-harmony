# 修复记录：标题栏滚动穿透（半透明渐变模糊）

- 日期：2026-11-07
- 文件：`entry/src/main/ets/pages/Index.ets`、`tools/sign-debug.sh`、`tools/launch-app.sh`
- 现象（用户反馈）：内容滚动到标题栏处就停住，标题栏的「沉浸式渐变模糊」看不出半透明效果——因为标题栏背后根本没有内容可模糊。

## 1. 官方机制（关键，勿回退）

HDS 官方《设置动态模糊样式》示例明确要求可滚动容器：

```ts
List({ scroller })
  .clip(false)          // 不裁剪超出自身范围的子组件 ⇒ 内容可穿透到标题栏下方
  .cachedCount(3, true) // 穿透后预加载，避免滑出视口立刻销毁
```

配合 `HdsNavigation.titleBar({ style: { scrollEffectOpts: { enableScrollEffect: true,
scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR } } })` 与 `bindToScrollable([scroller])`。

## 2. 本工程此前为什么不生效

四个 `TabContent` 内的 `List` **本来就带** `clip(false)` + `cachedCount(3, true)`，但滚动容器上方还有
`TabContent` 与 `HdsTabs` 两层：它们默认裁剪到自身边界，列表即使不裁剪，超出部分仍在 TabContent 边界被裁掉。
⇒ 标题栏后面永远是页面背景，模糊效果只剩「系统材质色」，即用户看到的「灰/实」。

## 3. 改动

| 位置 | 改动 |
|---|---|
| `Index.ets` 四个 `TabContent` | `.tabBar(...)` 之后追加 `.clip(false)` |
| `Index.ets` `HdsTabs` | `.barBackgroundColor(Color.Transparent)` 之后追加 `.clip(false)` |
| `Index.ets` 平板分支 | 新增 `mainPaneScroller`，`bindToScrollable` 在 `sideBySide` 时改绑它；实例下发给 `DevicesTab` |
| `DevicesTab.ets` 平板主区 | 右栏 `mainArea()` 外包 `Scroll(mainScroller)`（`clip(false)`、`Spring`、无滚动条）；`GlassCard` 改 `fill: false`（按内容高，否则卡片恰好等于视口、Scroll 无内容可滚） |
| `tools/sign-debug.sh` / `tools/launch-app.sh` | 支持 `HDC_TARGET=<serial>`：多设备同时在线时 `hdc` 必须带 `-t`，否则脚本报 `need connect-key` 直接失败 |

`List` 自身的 `clip(false)` / `cachedCount` 未改（原样保留）。

## 4. 验证（ohemu 5559，HarmonyOS 7.0.0 / API 26）

- 手动连接 `192.168.3.4:1716` 成功后日志变长（用户提示的路径）；
- Logs 页上滑：日志文本出现在标题栏背后并被渐变模糊，浅色/暗色主题均生效；
- 回归：设备页、抽屉开合、设置页、页签切换无布局破损；
- 证据截图：`~/WorkSpace2/version-shots/titlebar-passthrough-20261107/`（`lg2.jpeg` 浅色滚动、`dk1.jpeg` 暗色滚动、`reg_*.jpeg` 回归、`q1.jpeg` 探针 V2）。

## 5. 已知边界

- 首屏内容仍从标题栏下沿开始（HDS 的内容区从标题栏底部起算），只有**滚动后**的内容才穿透到标题栏下方——这是官方行为，不是缺陷。
- 平板/横屏 `sideBySide` 分支原先用 `Column` 且右栏不可滚动（内容超长会被裁掉），2026-11-07 已改为右栏 `Scroll` + `bindToScrollable(mainPaneScroller)`；`GlassCard` 随之改为内容高（浅色主题下卡片可能短于侧栏高度，属预期）。
- `TabContent/HdsTabs` 关闭裁剪后，理论上跨页签的越界绘制会可见；实测页签切换未见残影，后续若引入横向滑动动画需复核。
