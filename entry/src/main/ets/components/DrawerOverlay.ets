// SPDX-License-Identifier: GPL-2.0-or-later
import { DeviceItem } from '../model/DeviceModels';

// R1 拆分（REVIEW_ARKTS_MERGED 批2）：设备抽屉从 Index.ets 抽出为独立组件。
// 数据自上而下（列表/选中态由页面派生后传入），动作自下而上（回调）；
// drawerExpanded 是抽屉内部交互态，走 @Link 双向绑定回页面 @State。
const DRAWER_DEVICE_CAP: number = 2;
const DRAWER_WIDTH_LIMIT: ConstraintSizeOptions = { maxWidth: 360 };

@Component
export struct DrawerOverlay {
  // —— 数据（页面派生后传入）——
  connectedList: DeviceItem[] = [];       // connectedShown()
  discoveredList: DeviceItem[] = [];      // discoveredShown()
  rememberedCount: number = 0;            // offlineKnownShown().length
  @Prop selectedDeviceId: string = '';
  @Prop requestedPairIds: string[] = [];
  @Prop deviceSection: number = 0;
  @Link drawerExpanded: boolean;
  // —— 动作（回调）——
  onClose: () => void = () => {};
  onOpenDevice: (d: DeviceItem) => void = (_d: DeviceItem) => {};
  onPairRequest: (d: DeviceItem) => void = (_d: DeviceItem) => {};
  onPickSection: (index: number) => void = (_i: number) => {};
  isPaired: (deviceId: string) => boolean = (_id: string) => false;
  @StorageProp('statusBarHeightPx') statusBarHeightPx: number = 0;

  // 展开态裁剪：「展开 ⌄」只作用于已连接设备列表
  private visibleDrawerDevices(): DeviceItem[] {
    const list: DeviceItem[] = this.connectedList;
    if (this.drawerExpanded || list.length <= DRAWER_DEVICE_CAP) {
      return list;
    }
    return list.slice(0, DRAWER_DEVICE_CAP);
  }

  // 发现行展示用：IP:端口（端口未知时只给 IP；地址未知给占位文案）
  private addressOf(d: DeviceItem): ResourceStr {
    if (d.host === '') {
      return $r('app.string.address_pending');
    }
    return d.tcpPort > 0 ? `${d.host}:${d.tcpPort}` : d.host;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 遮罩：浅色变暗（不用纯黑/材质层——暗色主题下会糊成"黑方块"）；全屏淡入淡出
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#40000000')
        .onClick(() => {
          this.onClose();
        })
        .transition(TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.EaseOut }))

      // 面板：左贴屏边、右侧圆角、滑入/滑出
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text($r('app.string.tab_devices'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Text('✕')
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
            .padding(8)
            .onClick(() => {
              this.onClose();
            })
        }
        .width('100%')

        Scroll() {
          Column({ space: 6 }) {
            Text($r('app.string.connected_devices'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ top: 4, bottom: 4 })
            if (this.connectedList.length === 0) {
              Text($r('app.string.drawer_pick_device_hint'))
                .fontSize(12)
                .fontColor($r('app.color.text_muted'))
                .width('100%')
                .padding({ top: 4, bottom: 4 })
            }
            ForEach(this.visibleDrawerDevices(), (d: DeviceItem) => {
              this.drawerDeviceRow(d)
            }, (d: DeviceItem) => `conn-${d.id}`)

            // 「展开 ⌄」只作用于**已连接设备列表**（设备多时先收起、点开看全部）；
            // 下面三个分区入口（发现/记住/手动）常驻可见可点，不参与收起
            if (this.connectedList.length > DRAWER_DEVICE_CAP) {
              Row({ space: 6 }) {
                Text(this.drawerExpanded ? $r('app.string.drawer_collapse') : $r('app.string.drawer_expand'))
                  .fontSize(13)
                  .fontColor($r('app.color.accent_text'))
                SymbolGlyph(this.drawerExpanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
                  .fontSize(13)
                  .fontColor([$r('app.color.accent_text')])
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 10, bottom: 10 })
              .onClick(() => {
                animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
                  this.drawerExpanded = !this.drawerExpanded;
                });
              })
            }

            // 发现设备：未配对的在线设备（含已连上但未配对的）—— 配对入口在发现列表里
            // （用户 2026-09-14 裁决：只有配对成功才进「已连接」，故配对按钮留在发现列表）
            Text($r('app.string.discovered_devices'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ top: 10, bottom: 4 })
            if (this.discoveredList.length === 0) {
              Text($r('app.string.discovered_hint'))
                .fontSize(12)
                .fontColor($r('app.color.text_muted'))
                .width('100%')
                .padding({ top: 4, bottom: 4 })
            }
            ForEach(this.discoveredList, (d: DeviceItem) => {
              this.drawerPairRow(d)
            }, (d: DeviceItem) => `disc-${d.id}`)

            this.drawerSectionRow(2, $r('app.string.remembered_devices'), this.rememberedCount)
            this.drawerSectionRow(3, $r('app.string.manual_connect'), 0)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
      }
      .width('78%')
      .constraintSize(DRAWER_WIDTH_LIMIT)
      .height('100%')
      .padding({
        left: 16,
        right: 16,
        top: this.getUIContext().px2vp(this.statusBarHeightPx) + 16,
        bottom: 16
      })
      // 抽屉：恢复毛玻璃，并换用更实的 drawer_bg（用户反馈去掉模糊后太透、文字看不清）
      .backgroundColor($r('app.color.drawer_bg'))
      // P2-19：抽屉用 THIN——THICK 的整屏背景重算与抽屉内列表滚动叠加会拖慢主线程
      //（与弹层不用毛玻璃同一实测结论，REVIEW_ARKTS_MERGED P2-19）。
      .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
      .borderRadius({ topRight: 22, bottomRight: 22 })
      .border({ width: 1, color: $r('app.color.bar_border') })
      .alignItems(HorizontalAlign.Start)
      .clip(true)
      .transition(TransitionEffect.translate({ x: -400 }).animation({ duration: 280, curve: Curve.EaseOut }))
    }
    .width('100%')
    .height('100%')
  }

  // 抽屉里的设备行（对齐参考稿「我的产品」列表：方图 + 名称 + 副标题 + 状态标签，
  // 选中行整行高亮）。点击 = 选中该设备并收起抽屉，页面随即展示该设备详情 + 大按钮。
  @Builder
  drawerDeviceRow(d: DeviceItem) {
    Row({ space: 12 }) {
      Column() {
        SymbolGlyph($r('sys.symbol.computer'))
          .fontSize(22)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(44)
      .height(44)
      .borderRadius(12)
      .backgroundColor($r('app.color.chip_bg'))
      .justifyContent(FlexAlign.Center)

      Column({ space: 2 }) {
        Text(d.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(d.id)
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .fontFamily('monospace')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.isPaired(d.id) ? $r('app.string.remembered_hint') : $r('app.string.remembered_unpaired'))
        .fontSize(10)
        .fontColor(this.isPaired(d.id) ? $r('app.color.dot_remembered') : $r('app.color.text_muted'))
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .borderRadius(999)
        .backgroundColor($r('app.color.chip_bg'))
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(14)
    .backgroundColor(this.selectedDeviceId === d.id ? $r('app.color.accent_soft') : Color.Transparent)
    .onClick(() => {
      // 页面侧 openDeviceDetail 负责「选中设备 + 切分区」，抽屉只管发起动作
      this.onOpenDevice(d);
    })
  }

  // 抽屉里的「发现设备」行：点击/配对按钮 = 发起配对（配对成功才转入「已连接」）
  @Builder
  drawerPairRow(d: DeviceItem) {
    Row({ space: 12 }) {
      Column() {
        SymbolGlyph($r('sys.symbol.computer'))
          .fontSize(22)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(44)
      .height(44)
      .borderRadius(12)
      .backgroundColor($r('app.color.chip_bg'))
      .justifyContent(FlexAlign.Center)

      Column({ space: 2 }) {
        Text(d.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 发现行只显示 IP:端口（设备 ID 在配对弹窗里核对）
        Text(this.addressOf(d))
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .fontFamily('monospace')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.requestedPairIds.includes(d.id)) {
        Text($r('app.string.pair_pending'))
          .fontSize(10)
          .fontColor($r('app.color.accent_text'))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(999)
          .backgroundColor($r('app.color.accent_soft'))
      } else {
        Button($r('app.string.pair_action'))
          .fontSize(12)
          .height(32)
          .backgroundColor($r('app.color.accent'))
          .borderRadius(8)
          .onClick(() => {
            this.onPairRequest(d);
          })
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(14)
    .onClick(() => {
      this.onPairRequest(d);
    })
  }

  // 抽屉里「展开 ⌄」之后露出的分区入口（发现 / 记住 / 手动）：
  // 这三个页面本身不变，只是入口挪到展开区（对齐参考稿的「展开」折叠）。
  @Builder
  drawerSectionRow(index: number, label: ResourceStr, count: number) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(14)
        .fontColor(this.deviceSection === index ? $r('app.color.accent_text') : $r('app.color.text_secondary'))
        .fontWeight(this.deviceSection === index ? FontWeight.Medium : FontWeight.Normal)
        .layoutWeight(1)
      if (count > 0) {
        Text(`${count}`)
          .fontSize(10)
          .fontColor($r('app.color.accent_text'))
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .borderRadius(999)
          .backgroundColor($r('app.color.accent_soft'))
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 15, bottom: 15 })
    .borderRadius(12)
    .backgroundColor(this.deviceSection === index ? $r('app.color.accent_soft') : Color.Transparent)
    .onClick(() => {
      this.onPickSection(index);
    })
  }
}
