// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later

// Navigation/Split 最小原型 v2 — 参考 ResponsiveLayout SidebarView
// 用 SideBarContainer 替代 Navigation Split + Stack overlay
// 验证点：① SideBarContainer Overlay/Embed 响应式切换 ② 侧栏开关按钮交互
//         ③ 标准 Tabs barOverlap+blur 观感 ④ 安全区避让 ⑤ 侧栏数据直接渲染

import { display, SymbolGlyphModifier } from '@kit.ArkUI';

interface TabItem {
  title: string;
  icon: Resource;
}

interface SideBarItem {
  name: string;
  connected: boolean;
}

@Entry
@Component
struct NavPrototype {
  @State drawerOpen: boolean = false;
  @State currentTab: number = 0;
  @State widthBp: WidthBreakpoint = WidthBreakpoint.WIDTH_SM;
  @StorageProp('statusBarHeightPx') statusBarHeightPx: number = 0;
  @StorageProp('navBarHeightPx') navBarHeightPx: number = 0;

  private tabsController: TabsController = new TabsController();

  private tabs: TabItem[] = [
    { title: '设备', icon: $r('sys.symbol.house') },
    { title: '文件', icon: $r('sys.symbol.folder') },
    { title: '设置', icon: $r('sys.symbol.gearshape') },
    { title: '日志', icon: $r('sys.symbol.doc_text') }
  ];

  private sideBarItems: SideBarItem[] = [
    { name: 'Linux Desktop', connected: true },
    { name: 'Android Phone', connected: true },
    { name: 'Windows PC', connected: false },
    { name: 'MacBook Pro', connected: false }
  ];

  private tabIconModifier(index: number): SymbolGlyphModifier {
    return new SymbolGlyphModifier(this.tabs[index].icon).fontSize(24);
  }

  aboutToAppear(): void {
    this.detectBreakpoint();
    this.drawerOpen = !this.isSmallScreen();
  }

  onBackPress(): boolean {
    if (this.drawerOpen) {
      this.drawerOpen = false;
      return true;
    }
    return false;
  }

  private detectBreakpoint(): void {
    try {
      this.widthBp = this.getUIContext().getWindowWidthBreakpoint();
    } catch (e) {
      this.widthBp = WidthBreakpoint.WIDTH_SM;
    }
  }

  private isSmallScreen(): boolean {
    return this.widthBp === WidthBreakpoint.WIDTH_XS || this.widthBp === WidthBreakpoint.WIDTH_SM;
  }

  private sideBarWidth(): Length {
    if (this.isSmallScreen()) {
      return '80%';
    }
    if (this.widthBp === WidthBreakpoint.WIDTH_MD) {
      return '50%';
    }
    return '40%';
  }

  private statusBarVp(): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const density: number = d.densityPixels > 0 ? d.densityPixels : 1;
      return this.statusBarHeightPx / density;
    } catch (e) {
      return 0;
    }
  }

  private navBarVp(): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const density: number = d.densityPixels > 0 ? d.densityPixels : 1;
      return this.navBarHeightPx / density;
    } catch (e) {
      return 0;
    }
  }

  build() {
    Stack() {
      SideBarContainer(
        this.isSmallScreen() ? SideBarContainerType.Overlay : SideBarContainerType.Embed
      ) {
        this.sideBarContent()
        this.mainContent()
      }
      .showSideBar(this.drawerOpen)
      .sideBarWidth(this.sideBarWidth())
      .controlButton({ top: this.statusBarVp() + 12 })
      .showControlButton(false)
      .autoHide(false)

      if (this.isSmallScreen() && this.drawerOpen) {
        Row() {
          Column()
            .width(this.sideBarWidth())
            .height('100%')
            .hitTestBehavior(HitTestMode.None)

          Column()
            .layoutWeight(1)
            .height('100%')
            .backgroundColor('#00000066')
            .onClick((): void => {
              this.drawerOpen = false;
            })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
  }

  // ========== 侧栏 ==========

  @Builder
  sideBarContent() {
    Column() {
      Scroll() {
        Column() {
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(24)
              .fontColor(['#e2e8f0'])
              .onClick((): void => {
                this.drawerOpen = !this.drawerOpen;
              })

            Text('KDE Connect')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor('#e2e8f0')
              .margin({ left: 12 })
          }
          .width('100%')
          .margin({ bottom: 12 })

          List() {
            ForEach(this.sideBarItems, (item: SideBarItem): void => {
              ListItem() {
                Row() {
                  SymbolGlyph(item.connected ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.wifi'))
                    .fontSize(20)
                    .fontColor([item.connected ? '#22c55e' : '#3b82f6'])
                  Text(item.name)
                    .fontSize(16)
                    .fontColor('#e2e8f0')
                    .layoutWeight(1)
                    .margin({ left: 12 })
                  if (item.connected) {
                    Text('已配对')
                      .fontSize(12)
                      .fontColor('#22c55e')
                  } else {
                    Button('配对')
                      .fontSize(12)
                      .height(28)
                      .fontColor('#e2e8f0')
                      .backgroundColor('#3b82f6')
                  }
                }
                .width('100%')
                .height(56)
                .padding({ left: 0, right: 0 })
              }
            }, (item: SideBarItem): string => item.name)
          }
          .layoutWeight(1)
          .divider({ strokeWidth: 0.5, color: '#334155' })
        }
        .height('100%')
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .height('100%')
      .width('100%')
      .padding({
        top: this.statusBarVp() + 12,
        bottom: this.navBarVp(),
        left: 16,
        right: 16
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#1e293b')
  }

  // ========== 主内容 ==========

  @Builder
  mainContent() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.text_alignleft'))
          .fontSize(24)
          .fontColor(['#e2e8f0'])
          .margin({ right: 12 })
          .onClick((): void => {
            this.drawerOpen = !this.drawerOpen;
          })
          .visibility(!this.drawerOpen ? Visibility.Visible : Visibility.Hidden)

        Text(this.tabs[this.currentTab].title)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor('#e2e8f0')
      }
      .width('100%')
      .margin({ bottom: 12 })

      Tabs({ controller: this.tabsController }) {
        TabContent() {
          this.tabContent('设备页')
        }
        .tabBar(BottomTabBarStyle.of(
          { normal: this.tabIconModifier(0), selected: this.tabIconModifier(0) },
          this.tabs[0].title)
          .verticalAlign(VerticalAlign.Center))

        TabContent() {
          this.tabContent('文件页')
        }
        .tabBar(BottomTabBarStyle.of(
          { normal: this.tabIconModifier(1), selected: this.tabIconModifier(1) },
          this.tabs[1].title)
          .verticalAlign(VerticalAlign.Center))

        TabContent() {
          this.tabContent('设置页')
        }
        .tabBar(BottomTabBarStyle.of(
          { normal: this.tabIconModifier(2), selected: this.tabIconModifier(2) },
          this.tabs[2].title)
          .verticalAlign(VerticalAlign.Center))

        TabContent() {
          this.tabContent('日志页')
        }
        .tabBar(BottomTabBarStyle.of(
          { normal: this.tabIconModifier(3), selected: this.tabIconModifier(3) },
          this.tabs[3].title)
          .verticalAlign(VerticalAlign.Center))
      }
      .barPosition(BarPosition.End)
      .vertical(false)
      .barOverlap(true)
      .barMode(BarMode.Fixed)
      .barBackgroundBlurStyle(BlurStyle.Regular)
      .barBackgroundColor(Color.Transparent)
      .animationDuration(300)
      .layoutWeight(1)
      .onChange((index: number): void => {
        this.currentTab = index;
      })
    }
    .width('100%')
    .height('100%')
    .padding({
      top: this.statusBarVp() + 12,
      bottom: this.navBarVp(),
      left: 16,
      right: 16
    })
    .linearGradient({
      angle: 160,
      colors: [['#0f172a', 0.0], ['#1e293b', 0.5], ['#0f172a', 1.0]]
    })
  }

  // ========== Tab 内容占位 ==========

  @Builder
  tabContent(label: string) {
    Column() {
      Text(label)
        .fontSize(24)
        .fontColor('#e2e8f0')
        .margin({ top: 40 })

      Text(`当前页签索引: ${this.currentTab}`)
        .fontSize(16)
        .fontColor('#94a3b8')
        .margin({ top: 16 })

      Text(`宽度断点: ${this.widthBp}`)
        .fontSize(14)
        .fontColor('#64748b')
        .margin({ top: 8 })

      Text(`侧栏宽度: ${this.sideBarWidth()}`)
        .fontSize(14)
        .fontColor('#64748b')
        .margin({ top: 4 })

      Text(`容器类型: ${this.isSmallScreen() ? 'Overlay' : 'Embed'}`)
        .fontSize(14)
        .fontColor('#64748b')
        .margin({ top: 4 })

      Text(`状态栏高度: ${this.statusBarVp()}vp`)
        .fontSize(14)
        .fontColor('#64748b')
        .margin({ top: 4 })

      Text(`导航栏高度: ${this.navBarVp()}vp`)
        .fontSize(14)
        .fontColor('#64748b')
        .margin({ top: 4 })

      Text(`抽屉状态: ${this.drawerOpen ? '打开' : '关闭'}`)
        .fontSize(14)
        .fontColor('#64748b')
        .margin({ top: 4 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Center)
  }
}
