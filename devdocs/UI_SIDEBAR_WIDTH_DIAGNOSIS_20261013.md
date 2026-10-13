# UI 窄列问题：HdsSideBar builder 与宽度归属排查

日期：2026-10-13。依据 DevEco MSG156/157、CodeArts MSG148-150、真实平板截图和当前可见工作区源码。目的：只修“整页被限在侧栏宽度”问题，不重做用户认可的窄列内页面。

## 1. 证据与判定边界

### 真机现象

DevEco MSG157 的 1600×2560 平板截图显示：应用页面（状态、设备信息、六张功能卡、通知、底部胶囊）都在左侧约 565px；右侧约 2/3 屏幕为空。用户确认：窄列内的逻辑和布局是正确的，只要扩展为整屏。

### 三条必须区分的假设

- **H1：HdsSideBar builder 归属错误。** 仅在实际安装包源码确实包含 HdsSideBar 时适用；截图不能单独证明该组件存在。
- **H2：构建快照不一致。** 当前共享 Index.ets 是 `Stack → HdsNavigation → HdsTabs`，没有 HdsSideBar，且已明确 `.mode(NavigationMode.Stack)`。这与 MSG157 的组件描述冲突。GIT_REVISION 指向 `35c8956` 且注明 dirty，只能标识提交基线，不能标识未提交源码或安装包；不能据此断言改造没有同步。
- **H3：HdsNavigation 自身进入 Split/自动分栏。** [INFERENCE] 标题、Tabs 内容和胶囊一起位于左栏、右侧为空且有竖向分界，也可能是 Navigation 的导航栏/空 destination 分栏，并非 HdsSideBar。SDK 的 HdsNavigation 同时有 `mode(NavigationMode)` 和 `navBarWidth(Length)`，两类侧栏不可混淆。

优先核对实际构建的 Navigation `.mode`。当前共享文件已有 Stack，不能重复添加并声称修复；须确认该行是否确实进入安装包。用户认可窄列内布局，证明需保留内容，不证明 H1。

### 尺寸证据

截图约 565px 是报告估值，不能直接换算为 300vp 或据此确定组件。背景实际延伸至右侧，收窄的是前景导航与内容。临时记录窗口、根容器、Navigation、Tabs、当前内容以及（若存在）两个 sidebar panel 的宽度，标明 px/vp 与设备 density。`onAreaChange` 的布局宽度按其 API 单位处理；截图像素另行换算。

## 2. 先做构建身份确认

修复前由 DevEco/Omp 记录同一组证据：

1. 当前源码对应的 `AgentsConversion/GIT_REVISION.md` commit/工作区状态。
2. `AppScope/app.json5` 的 `versionName` / `versionCode`。
3. 真机安装后的包名、版本名/码（用设备侧 bundle 查询接口）和本次安装时间。
4. 构建产物的 SHA-256（构建端与安装前 HAP 文件）。
5. 真机截图对应的构建 ID，尤其确认是否为 `0.8.0-202610122312` 或 CodeArts UI 统一后的包。

若真机包不是共享源码构建，先安装当前待验包复现；不要用旧截图证明新源码的布局。

## 3. 最小诊断：核对两个 builder，不先改 UI

找到实际构建版本 `Index.ets` 中唯一的 `HdsSideBar({ ... })` 调用，做逐项核对：

```ts
HdsSideBar({
  sideBarPanelBuilder: (): void => {
    // 只渲染侧栏内容：设备列表、发现/记住/手动分区入口。
  },
  contentPanelBuilder: (): void => {
    // 渲染整个 app 页面：背景 Stack、唯一 HdsNavigation/HdsTabs、dialogs/overlays。
  }
})
```

官方 SDK 声明分别把这两个 BuilderParam 定义为 “SideBarPanel content” 与 “contentPanel content”。屏幕尺寸的判断以父 `HdsSideBar` 的实际布局测量为准。

用临时诊断标签（仅本地，不提交）分别在两个 builder 根节点显示 `SIDE PANEL`、`CONTENT PANEL`，记录两个根的 `onAreaChange` 宽度：

| Root | 预期宽度 | 预期内容 |
|---|---:|---|
| sideBarPanelBuilder | 侧栏宽，约 240–360vp | 原 DrawerOverlay 的侧栏内容 |
| contentPanelBuilder | 剩余窗口宽；Overlay 下近全宽 | 背景 + 整页导航/标签页/弹窗 |

若截图主页面内容出现在 side-panel 根，H1 即确认。若两个根归属正确，继续第 5 节查祖先宽度约束，不交换 builder。

## 4. H1 确认后的最小修复

只把两个 builder 对应到正确内容：

```ts
sideBarPanelBuilder: (): void => {
  this.drawerOverlay(); // 或 HdsSideMenu / 原侧栏内容 builder，保留既有内容和交互
},
contentPanelBuilder: (): void => {
  this.pageContent();  // 现有完整页面 builder，原样调用
}
```

不要改 `pageContent()` 内部的 HdsNavigation/HdsTabs、卡片样式、状态条位置、通知顺序、胶囊参数或四页内容。不要改变 `sideBarWidth` 来掩盖根因；宽度调整只影响侧栏，不会把错误放在 side panel 的整页变成正确全屏内容。

若 `sideBarPanelBuilder` 在现有组件调用链中无法安全引用 `drawerOverlay()`，在同一 `Index` 上建立清晰命名的 `@Builder sidePanelContent()` 与 `@Builder fullPageContent()`，确保两者只被对应 BuilderParam 调用。避免 BuilderParam 内再次建立另一个 HdsSideBar。

**注意当前 DrawerOverlay 不是纯面板**：本次读到的 DrawerOverlay.ets:46–167 仍有全屏遮罩、78% 面板宽、宽度上限和位移动画，不能原封不动塞进 HdsSideBar。上面的委托示例仅适用于实际版本已抽出纯侧栏内容的情形。保留旧自绘容器做宽度诊断时，不同时引入 HdsSideBar；完成容器迁移后才删除失效分支。当前代码编写 owner 按 CodeArts MSG148 为 CodeArts，DevEco 负责验证，避免两人同时修改。

## 5. 两个 builder 正确但页面仍变窄时的祖先约束检查

从外到内逐层读取实际 `area.width`：

1. `HdsSideBar` 根容器
2. `contentPanelBuilder` 根
3. 完整页面 `Stack`
4. 唯一 HdsNavigation
5. HdsTabs
6. 当前 TabContent/List

若实际构建不含 HdsSideBar，跳过前两层。若根 Stack/Navigation 宽度正常而 Tabs 约为导航栏宽，优先检查 Navigation 内部分栏：实际包缺少 Stack 时，在唯一主导航上明确 `.mode(NavigationMode.Stack)`，保留其他属性，做单变量构建验证；已含 Stack 则检查外层是否还有导航容器或其他限宽父层。不要以 `navBarWidth('100%')`、改卡片宽度、缩字体、删除分隔线掩盖 Split 根因。HdsNavigation 的 Stack 与 HdsSideBar 的 Overlay/Embed 是独立概念；主导航 Stack 不妨碍横屏侧栏 Embed。

找第一个宽度从全窗口变成约侧栏宽的位置。检查该节点及祖先是否有：

- `width(300)` / `width('xx%')` / 受宽度上限限制的 `constraintSize`
- 意外的 `.layoutWeight()` 子节点或 Row/Column 分配
- HdsSideBar sidePanel 与 contentPanel builder 内容被互换或嵌套
- SideBar 内又放一个旧 DrawerOverlay / 侧栏容器
- `onAreaChange` 用被缩窄后的子组件宽度来切 `isLandscape`，导致方向/布局循环

只修复第一个错误约束；保留从该节点往下的所有用户认可 UI。

## 6. 视口行为验收

### 横屏 Embed

- side panel 显示在左侧并占用其指定宽度。
- contentPanel 根宽度等于窗口宽度减侧栏宽度（减去系统安全区/分隔线）；内容右边界与屏幕右边界一致。
- 收起侧栏后 contentPanel 扩展至整屏；不出现空白右侧。

### 竖屏 Overlay

- 默认收起时主内容为整屏宽。
- 展开时侧栏覆盖页面，主内容宽度不变、没有被推挤或缩成窄列。
- 关闭遮罩/返回/选项后的状态按既有交互恢复。

### 用户认可布局不回归

对照修复前窄列截图：汉堡、标题、四点、状态条、设备行、六张功能卡、通知顺序、底部胶囊一律不变；只改变这些内容所在 panel 的可用宽度。

验收矩阵最小集合：真机平板竖屏 Overlay 打开/关闭；横屏 Embed 展开/收起；每种状态截图 + 记录 builder 根宽度；切四个 Tab 检查标题栏和胶囊未移位。

## 7. 版本/提交隔离

- 以用户指定的 0.8.0-202610122312 为认可视觉基准；CodeArts UI 统一版本是否等价，需截图逐项比对，不因代码更“新”就覆盖基准。
- `build-profile.json5` 的真机 `matepadmini` 签名配置是 DevEco 已实测真机必要条件；保持它属于本机签名配置，不提交到主线。模拟器签名 profile 另走脚本，勿用 OpenHarmony debug profile 给真机签名。
- 临时宽度探针、构建身份标签和诊断日志确认后移除；不提交截图/临时侧栏 Demo。

## 8. 当前 Omp 工作边界

Omp 只提供本诊断文档和构建/验证/提交服务，不编辑 DevEco 负责的 `Index.ets` / ArkTS。DevEco 或 CodeArts确认实际源码包版本和 builder 根宽度后，按 H1 或第 5 节选择唯一根因修复。
