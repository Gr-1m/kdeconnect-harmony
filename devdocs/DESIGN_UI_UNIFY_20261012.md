# UI 统一设计文档：四页签对齐设备页 + 侧栏系统化

> 2026-10-12 CodeArts 撰写。供 DevEco 实施。
> 参考：`docs/MyResearch/harmony-UI-API.md`（华为官方 API 研究）、`devdocs/DESIGN_TITLEBAR_IMMERSIVE_deveco.md`（设备页沉浸标题栏设计 v2）。
> 承接：CodeArts MSG144（侧栏系统化裁定）+ MSG145（DevEco 读取 UI API 研究文档）。

---

## 一、问题分析

### 1.1 当前四页签设计差异

| 维度 | 设备页 (Tab 0) ✅ | 文件页 (Tab 1) ❌ | 设置页 (Tab 2) ❌ | 日志页 (Tab 3) ❌ |
|------|-------------------|-------------------|-------------------|-------------------|
| 标题栏 | HdsNavigation(MINI) + 沉浸光感 + 滚动渐变模糊 | 手写 Row（汉堡+"KDE Connect"+"HarmonyOS"徽章） | 同左 | 同左 |
| 汉堡按钮 | 标题栏 backIcon（左上角，`sys.symbol.text_alignleft`） | 手写三横线（在标题 Row 内） | 同左 | 同左 |
| 四点按钮 | 标题栏 menu（右上角，`sys.symbol.more`）→ 设备操作菜单 | 无 | 无 | 无 |
| 滚动容器 | List + contentEndOffset（底部避让胶囊） | Scroll()（无避让） | Scroll()（无避让） | Column + Scroll（无避让） |
| 滚动绑定 | bindToScrollable([deviceScroller]) → 标题栏渐变模糊 | 无 | 无 | 无 |
| 内容穿透 | clip(false) + cachedCount(3, true) | 无 | 无 | 无 |
| padding | List 内部 padding({ left: 16, right: 16 }) | 硬编码 padding({ left: 16, right: 16, top: 12, bottom: 108 }) | 同左 | 同左 |
| 状态条 | List 首个 ListItem（在滚动内容内） | 标题 Row 下方独立 Column | 同左 | 同左 |

### 1.2 核心问题

1. **切换页签时标题栏形态突变**：设备页有沉浸光感标题栏，其他三页是手写标题 Row → 视觉割裂
2. **其他三页没有滚动渐变模糊**：标题栏不随滚动变化，与设备页体验不一致
3. **硬编码 bottom: 108**：用固定 padding 避让胶囊，而非 contentEndOffset → 内容末尾有空白带
4. **汉堡按钮位置不一致**：设备页在标题栏左上角（系统标准），其他页在标题 Row 内（自绘）
5. **其他三页没有四点按钮**：缺少页签级操作入口

---

## 二、设计目标

**所有四个页签统一采用设备页的 HdsNavigation(MINI) + List + bindToScrollable 模式。**

具体目标：
1. 每个页签都有 HdsNavigation(MINI) 沉浸标题栏（滚动渐变模糊 + 沉浸光感材质）
2. 每个页签标题栏左上角都有汉堡按钮（控制 HdsSideBar）
3. 每个页签标题栏右上角都有四点按钮（页签级操作菜单）
4. 每个页签都用 List + contentEndOffset（整页滚动 + 底部避让胶囊）
5. 每个页签都 bindToScrollable（标题栏随滚动渐变模糊）
6. 删除旧的手写标题 Row + statusBar 独立块
7. 删除硬编码 padding，改为 List 内部 padding + contentEndOffset

---

## 三、侧栏配置（保持 AUTO）

当前 `HdsSideBar` 配置保持 `sideBarContainerType: SideBarContainerType.AUTO` 不变。

**AUTO 行为**（华为官方 API 文档 + `docs/MyResearch/harmony-UI-API.md` 确认）：
- 系统根据屏幕宽度自动选择 Embed 或 Overlay
- 窄屏（手机竖屏）→ Overlay：侧栏浮在内容之上，自动收起，点击抽拉展开覆盖页面
- 宽屏（平板横屏）→ Embed：侧栏嵌入容器内，与内容区并列显示，推动页面向右

这与用户要求的「竖屏 Overlay、横屏 Embed」完全一致，无需手动切换。

**当前 HdsSideBar 参数**（`Index.ets:1929-1950`）保持不变：
```typescript
HdsSideBar({
  isShowSideBar: this.drawerOpen,
  $isShowSideBar: (v: boolean): void => { this.drawerOpen = v; },
  sideBarContainerType: SideBarContainerType.AUTO,
  sideBarWidth: 300,
  minSideBarWidth: 240,
  maxSideBarWidth: 360,
  minContentWidth: 320,
  isSideBarBlur: true,
  sideBarColor: $r('app.color.drawer_bg'),
  contentAreaMask: false,
  autoHide: true,
  sideBarPanelBuilder: (): void => { this.drawerOverlay(); },
  contentPanelBuilder: (): void => { this.pageContent(); }
})
```

---

## 四、统一方案：每页签 HdsNavigation + List

### 4.1 架构变更

**当前**（`pageContent()` 内）：
```
Column() {
  // 旧标题区（仅 sideBySide || currentTab !== 0 时显示）
  if (this.sideBySide || this.currentTab !== 0) {
    Row { menuButton() + "KDE Connect" + "HarmonyOS" badge }
    Column { statusBar() }
  }

  HdsTabs() {
    TabContent(0) { HdsNavigation() { List { ... } } .titleBar(...) }  // ← 设备页有标题栏
    TabContent(1) { Column { FilesTab(...) }.padding(...) }            // ← 其他页无标题栏
    TabContent(2) { Column { SettingsTab(...) }.padding(...) }
    TabContent(3) { Column { LogsTab(...) }.padding(...) }
  }
}
```

**目标**：
```
Column() {
  // 删除旧标题区（不再需要）

  HdsTabs() {
    TabContent(0) { HdsNavigation() { List { statusBar + deviceTabView } } .titleBar(titleBarOptions(0)) }
    TabContent(1) { HdsNavigation() { List { filesTabView } } .titleBar(titleBarOptions(1)) }
    TabContent(2) { HdsNavigation() { List { settingsTabView } } .titleBar(titleBarOptions(2)) }
    TabContent(3) { HdsNavigation() { List { logsTabView } } .titleBar(titleBarOptions(3)) }
  }
}
```

### 4.2 每页签需要的独立 Scroller

每个页签需要自己的 Scroller 实例（用于 bindToScrollable 触发标题栏渐变模糊）：

```typescript
// 已有
private deviceScroller: Scroller = new Scroller();
// 新增
private filesScroller: Scroller = new Scroller();
private settingsScroller: Scroller = new Scroller();
private logsScroller: Scroller = new Scroller();
```

### 4.3 每页签的 titleBarOptions

每个页签的标题栏配置结构相同，差异在于：
- `mainTitle`：页签标题文字
- `menu`：四点按钮的菜单内容（页签级操作）

| 页签 | mainTitle | 四点菜单项 |
|------|-----------|------------|
| 设备 | "KDE Connect" | 加密信息 / 取消配对 / 发送 Ping（当前已实现） |
| 文件 | $r('app.string.tab_files') | 打开已接收文件 / 清除历史（待定） |
| 设置 | $r('app.string.tab_settings') | 暂无（占位，后续补充） |
| 日志 | $r('app.string.tab_logs') | 清除日志 / 导出日志（待定） |

**统一 titleBarOptions 工厂方法**：

```typescript
private titleBarOptions(tabIndex: number): HdsNavigationTitleBarOptions {
  const titles: ResourceStr[] = [
    'KDE Connect',
    $r('app.string.tab_files'),
    $r('app.string.tab_settings'),
    $r('app.string.tab_logs')
  ];
  const opts: HdsNavigationTitleBarOptions = {
    avoidLayoutSafeArea: true,
    enableComponentSafeArea: true,
    style: {
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
        blurEffectiveStartOffset: LengthMetrics.vp(0),
        blurEffectiveEndOffset: LengthMetrics.vp(96)
      },
      originalStyle: {
        contentStyle: {
          menuStyle: { backgroundColor: Color.Transparent }
        }
      },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    },
    content: {
      title: { mainTitle: titles[tabIndex] },
      backIcon: {
        icon: $r('sys.symbol.text_alignleft'),
        label: 'menu',
        isEnabled: true,
        action: (): void => {
          this.drawerOpen = !this.drawerOpen;
        }
      },
      menu: this.titleBarMenuOptions(tabIndex)
    }
  };
  return opts;
}
```

### 4.4 每页签的 titleBarMenuOptions（四点按钮）

```typescript
private titleBarMenuOptions(tabIndex: number): HdsNavigationMenuContentOptions {
  const items: Array<HdsNavigationMenuItemOptions> = [];
  // 通用：四点按钮图标
  const item: HdsNavigationMenuItemOptions = {
    content: {
      icon: $r('sys.symbol.more'),
      label: 'actions',
      isEnabled: true,
      action: (): void => {
        this.openTabActions(tabIndex);
      }
    }
  };
  items.push(item);
  return { value: items, maxCount: 3 };
}

// 页签级操作菜单分发
private openTabActions(tabIndex: number): void {
  if (tabIndex === 0) {
    this.openDeviceActions();  // 已有：加密信息/取消配对/发送Ping
  } else if (tabIndex === 1) {
    this.openFilesActions();   // 新：文件页操作
  } else if (tabIndex === 2) {
    this.openSettingsActions(); // 新：设置页操作
  } else if (tabIndex === 3) {
    this.openLogsActions();    // 新：日志页操作
  }
}
```

### 4.5 每页签的 HdsNavigation + List 模板

**设备页**（已有，保持不变）：
```typescript
HdsNavigation() {
  List({ scroller: this.deviceScroller }) {
    ListItem() { this.statusBar() }
    ListItem() { this.deviceTabView() }
  }
  .width('100%').height('100%')
  .padding({ left: 16, right: 16 })
  .contentEndOffset(this.bottomAvoidVp())
  .edgeEffect(EdgeEffect.Spring)
  .scrollBar(BarState.Off)
  .clip(false)
  .cachedCount(3, true)
}
.titleMode(HdsNavigationTitleMode.MINI)
.hideBackButton(false)
.bindToScrollable([this.deviceScroller])
.titleBar(this.titleBarOptions(0))
.width('100%').height('100%')
```

**文件页**（新，统一模式）：
```typescript
HdsNavigation() {
  List({ scroller: this.filesScroller }) {
    ListItem() { this.filesTabView() }
  }
  .width('100%').height('100%')
  .padding({ left: 16, right: 16 })
  .contentEndOffset(this.bottomAvoidVp())
  .edgeEffect(EdgeEffect.Spring)
  .scrollBar(BarState.Off)
  .clip(false)
  .cachedCount(3, true)
}
.titleMode(HdsNavigationTitleMode.MINI)
.hideBackButton(false)
.bindToScrollable([this.filesScroller])
.titleBar(this.titleBarOptions(1))
.width('100%').height('100%')
```

**设置页**（新，统一模式）：
```typescript
HdsNavigation() {
  List({ scroller: this.settingsScroller }) {
    ListItem() { this.settingsTabView() }
  }
  .width('100%').height('100%')
  .padding({ left: 16, right: 16 })
  .contentEndOffset(this.bottomAvoidVp())
  .edgeEffect(EdgeEffect.Spring)
  .scrollBar(BarState.Off)
  .clip(false)
  .cachedCount(3, true)
}
.titleMode(HdsNavigationTitleMode.MINI)
.hideBackButton(false)
.bindToScrollable([this.settingsScroller])
.titleBar(this.titleBarOptions(2))
.width('100%').height('100%')
```

**日志页**（新，统一模式）：
```typescript
HdsNavigation() {
  List({ scroller: this.logsScroller }) {
    ListItem() { this.logsTabView() }
  }
  .width('100%').height('100%')
  .padding({ left: 16, right: 16 })
  .contentEndOffset(this.bottomAvoidVp())
  .edgeEffect(EdgeEffect.Spring)
  .scrollBar(BarState.Off)
  .clip(false)
  .cachedCount(3, true)
}
.titleMode(HdsNavigationTitleMode.MINI)
.hideBackButton(false)
.bindToScrollable([this.logsScroller])
.titleBar(this.titleBarOptions(3))
.width('100%').height('100%')
```

---

## 五、子组件改造

### 5.1 FilesTab.ets

**当前**：`Scroll() { Column({ space: 12 }) { GlassCard... } }` — 自管滚动

**目标**：去掉外层 `Scroll()`，只保留 `Column({ space: 12 }) { GlassCard... }` 的内容部分，由 Index 的 `List` 承载滚动。即 FilesTab 变为纯内容 builder，不再自管滚动容器。

改动：
- 删除 `build()` 中的 `Scroll()` 包裹
- 保留 `Column({ space: 12 })` 内的所有 GlassCard 内容
- 删除 `.scrollBar(BarState.Off)` `.edgeEffect(EdgeEffect.Spring)` `.align(Alignment.TopStart)` 等滚动属性
- `layoutWeight(1)` 改为内容自然高度

### 5.2 SettingsTab.ets

同 FilesTab：删除外层 `Scroll()`，保留 `Column({ space: 12 })` 内容。

### 5.3 LogsTab.ets

**当前**：`Column({ space: 8 }) { Row { title + clear button } + Scroll() { Text } }` — 标题行 + 内嵌滚动

**目标**：
- 删除标题行 `Row { Text($r('app.string.log_title')) + Button($r('app.string.logs_clear')) }`（标题由 HdsNavigation 承载）
- 清除日志按钮移到四点菜单（`openLogsActions()`）
- 内容 `Scroll() { Text(logStore.text) }` 改为纯 `Text(logStore.text)`，由 Index 的 List 承载滚动

### 5.4 DevicesTab.ets

设备页已通过 `deviceTabView()` builder 接入 List，保持不变。但 `sideBySide`（横屏常驻侧栏）路径仍保留旧逻辑，待后续平板侧栏系统化时统一。

---

## 六、需要删除的代码

### 6.1 删除旧标题区

`pageContent()` 中以下代码块**删除**（`Index.ets:1543-1572`）：

```typescript
// 删除整个 if 块
if (this.sideBySide || this.currentTab !== 0) {
  Row({ space: 10 }) {
    if (!this.sideBySide) {
      this.menuButton()
    }
    Text('KDE Connect')
    Text('HarmonyOS')
  }
  .padding({ left: 16, right: 16, top: ... })

  Column() {
    this.statusBar()
  }
  .padding({ left: 16, right: 16 })
}
```

### 6.2 删除旧 menuButton Builder

`menuButton()` builder（`Index.ets:1158-1184`）**删除** — 汉堡按钮已由 HdsNavigation titleBar backIcon 承载。

### 6.3 删除旧 TabContent padding

每个非设备页签的 `.padding({ left: 16, right: 16, top: 12, bottom: 108 })` **删除** — padding 移入 List。

---

## 七、statusBar 处置

**当前**：设备页的 statusBar() 作为 List 首个 ListItem（在滚动内容内）。其他页的 statusBar 在标题 Row 下方独立显示。

**目标**：
- 设备页：保持 statusBar() 作为 List 首个 ListItem（不变）
- 其他页：statusBar() 也作为各自 List 的首个 ListItem（与设备页一致）

这样所有页签的 statusBar 都在滚动内容内，随内容滚动，标题栏渐变模糊效果一致。

---

## 八、横屏 sideBySide 处理

当前 `sideBySide`（横屏宽屏常驻侧栏）路径在 DevicesTab 内有独立逻辑。本次统一改造**不涉及横屏 sideBySide 路径**——横屏仍保留 DevicesTab 的常驻侧栏 + 主区布局。

后续 0.8.2 G3 抽屉重构时，横屏路径也会迁移到 HdsSideBar(AUTO) 的 Embed 模式，届时统一。

本次改造范围：**仅竖屏路径**（手机 + 平板竖屏），将四个页签的竖屏路径统一为 HdsNavigation + List 模式。

---

## 九、实施步骤

### 步骤 1：Index.ets 改造

1. 新增三个 Scroller 实例（filesScroller, settingsScroller, logsScroller）
2. 将 `titleBarOptions()` 改为 `titleBarOptions(tabIndex: number)` 工厂方法
3. 将 `titleBarMenuOptions()` 改为 `titleBarMenuOptions(tabIndex: number)` 工厂方法
4. 新增 `openTabActions(tabIndex: number)` 分发方法
5. 新增 `filesTabView()` / `settingsTabView()` / `logsTabView()` builder（包装对应 Tab 组件内容）
6. 将 TabContent 1/2/3 改为 HdsNavigation + List 模式
7. 删除旧标题区 if 块
8. 删除 menuButton() builder
9. 删除旧 TabContent padding

### 步骤 2：子组件改造

1. FilesTab.ets：删除外层 Scroll()，保留内容 Column
2. SettingsTab.ets：删除外层 Scroll()，保留内容 Column
3. LogsTab.ets：删除标题行 + 外层 Column/Scroll，保留内容 Text

### 步骤 3：验证

1. Win10 商用模拟器：四页签切换标题栏形态一致、滚动渐变模糊生效、汉堡+四点按钮位置正确
2. ohemu：非 UI 逻辑回归（verify-on-ohemu.sh 降级脚本须覆盖 HdsNavigation）

---

## 十、API 参考（来自 docs/MyResearch/harmony-UI-API.md + 官方文档）

### 10.1 HdsNavigation 标题栏

```typescript
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, HdsNavigationTitleBarOptions, HdsNavigationMenuContentOptions, HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
```

关键属性：
- `titleMode(HdsNavigationTitleMode.MINI)` — 紧凑标题栏
- `titleBar(options)` — 标题栏配置（沉浸安全区 + 滚动渐变模糊 + 沉浸光感材质）
- `bindToScrollable([scroller])` — 绑定滚动器，触发标题栏渐变模糊
- `hideBackButton(false)` — 显示 backIcon（汉堡按钮）

### 10.2 标题栏滚动渐变模糊

```typescript
style: {
  scrollEffectOpts: {
    enableScrollEffect: true,
    scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,  // 或 COMMON_BLUR
    blurEffectiveStartOffset: LengthMetrics.vp(0),
    blurEffectiveEndOffset: LengthMetrics.vp(96)
  }
}
```

### 10.3 沉浸光感材质

```typescript
style: {
  systemMaterialEffect: {
    materialType: hdsMaterial.MaterialType.ADAPTIVE,
    materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
  }
}
```

### 10.4 HdsSideBar（保持 AUTO）

```typescript
HdsSideBar({
  sideBarContainerType: SideBarContainerType.AUTO,  // 系统自动选择 Embed/Overlay
  isShowSideBar: this.drawerOpen,
  $isShowSideBar: (v: boolean): void => { this.drawerOpen = v; },
  ...
})
```

AUTO 行为：
- 窄屏 → Overlay（浮层抽屉，自动收起，点击展开覆盖页面）
- 宽屏 → Embed（嵌入容器，与内容并列，推动页面向右）

### 10.5 List + contentEndOffset

```typescript
List({ scroller: this.xxxScroller }) {
  ListItem() { ... }
}
.contentEndOffset(this.bottomAvoidVp())  // 底部避让胶囊，不进入视口
.clip(false)                              // 内容穿透标题栏下方
.cachedCount(3, true)                     // 预加载，穿透不消失
```

---

## 十一、与现有代码的对齐

本设计文档基于当前代码（commit `35c8956`）分析，所有文件路径和行号均对应此版本。实施时以最新代码为准，按符号名搜索定位。

关键文件：
- `entry/src/main/ets/pages/Index.ets` — 主页面（1957行），改造重点
- `entry/src/main/ets/components/DevicesTab.ets` — 设备页组件（1032行），竖屏路径已接入 List
- `entry/src/main/ets/components/FilesTab.ets` — 文件页组件（181行），需删除外层 Scroll
- `entry/src/main/ets/components/SettingsTab.ets` — 设置页组件（362行），需删除外层 Scroll
- `entry/src/main/ets/components/LogsTab.ets` — 日志页组件（59行），需删除标题行 + 外层容器
- `docs/MyResearch/harmony-UI-API.md` — 华为官方 UI API 研究文档（600行），实施参考

—— CodeArts，2026-10-12