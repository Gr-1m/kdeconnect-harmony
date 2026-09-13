import uiMaterial from '@ohos.arkui.uiMaterial';
import { DeviceItem, RememberedDevice, BatteryItem } from '../model/DeviceModels';
import { GlassCard } from './GlassCard';

// 设备 Tab：
// - 手机（窄屏）：三条横线（汉堡）拉出抽屉式侧栏，占屏大部分 + 背景变暗，选中后收起回主区；
// - 平板（>=600vp）：侧栏常驻，展开时直接切换，收起只留三条横线。
@Component
export struct DevicesTab {
  @Link connectedDevices: DeviceItem[];
  @Link discoveredDevices: DeviceItem[];
  @Link rememberedDevices: RememberedDevice[];
  @Prop immersive: boolean = false;
  @Prop isWide: boolean = false;
  // AP-1：本侧已发起、等待对端确认的设备 id
  @Prop requestedPairIds: string[] = [];
  // 插件推来的展示项（电量）
  @Prop batteryItems: BatteryItem[] = [];
  cardMaterial: uiMaterial.Material | undefined = undefined;
  onDisconnectDevice: (d: DeviceItem) => void = () => {
  };
  onUnpairDevice: (d: DeviceItem) => void = () => {
  };
  onConnectDevice: (d: DeviceItem) => void = () => {
  };
  onManualConnect: (host: string, port: number) => void = () => {
  };
  onPairDevice: (d: DeviceItem) => void = () => {
  };
  // 发现列表下拉刷新 → 请求页面触发一次 identity 广播（MSG73/MSG74）
  onRefreshDiscovery: () => void = () => {
  };
  // 侧栏选中项：0 已连接 / 1 发现 / 2 记住的 / 3 手动连接
  // @Link：连接/配对成功后由 Index 切回「已连接设备」分区
  @Link deviceSection: number;
  @State drawerOpen: boolean = false;
  @State railExpanded: boolean = true;
  // 手动连接默认值：host 留空（10.0.2.2 只是 QEMU 模拟器的 NAT 网关，真机无意义），port 用默认端口
  @State manualHost: string = '';
  @State manualPort: string = '1716';
  // 发现列表下拉刷新态（触发广播后自动收起）
  @State discoveryRefreshing: boolean = false;

  private openSide(): void {
    if (this.isWide) {
      this.railExpanded = !this.railExpanded;
    } else {
      this.drawerOpen = true;
    }
  }

  private pickSection(index: number): void {
    this.deviceSection = index;
    if (!this.isWide) {
      this.drawerOpen = false;
    }
  }

  private isPaired(deviceId: string): boolean {
    return this.rememberedDevices.some((r: RememberedDevice) => r.id === deviceId);
  }

  private batteryOf(deviceId: string): string {
    const item: BatteryItem | undefined = this.batteryItems.find((b: BatteryItem) => b.deviceId === deviceId);
    return item === undefined ? '' : item.text;
  }

  private sectionTitleOf(index: number): ResourceStr {
    if (index === 0) {
      return $r('app.string.connected_devices');
    }
    if (index === 1) {
      return $r('app.string.discovered_devices');
    }
    if (index === 2) {
      return $r('app.string.remembered_devices');
    }
    return $r('app.string.manual_connect_optional');
  }

  // 三条横线（汉堡）：不依赖 sys.symbol 资源，直接绘制
  @Builder
  hamburger() {
    Column({ space: 4 }) {
      Row()
        .width(18)
        .height(2)
        .borderRadius(1)
        .backgroundColor($r('app.color.text_primary'))
      Row()
        .width(18)
        .height(2)
        .borderRadius(1)
        .backgroundColor($r('app.color.text_primary'))
      Row()
        .width(18)
        .height(2)
        .borderRadius(1)
        .backgroundColor($r('app.color.text_primary'))
    }
    .padding({ left: 8, right: 8, top: 10, bottom: 10 })
    .borderRadius(10)
    .backgroundColor($r('app.color.chip_bg'))
    .onClick(() => {
      this.openSide();
    })
  }

  @Builder
  railItem(index: number, label: ResourceStr, shortLabel: ResourceStr, count: number, expanded: boolean) {
    Column({ space: 2 }) {
      Text(expanded ? label : shortLabel)
        .fontSize(12)
        .fontColor(this.deviceSection === index ? $r('app.color.accent_text') : $r('app.color.text_secondary'))
        .fontWeight(this.deviceSection === index ? FontWeight.Medium : FontWeight.Normal)
        .maxLines(2)
        .textAlign(TextAlign.Center)
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
    .padding({ top: 10, bottom: 10 })
    .borderRadius(14)
    .backgroundColor(this.deviceSection === index ? $r('app.color.accent_soft') : Color.Transparent)
    .onClick(() => {
      this.pickSection(index);
    })
  }

  @Builder
  railList(expanded: boolean) {
    Column({ space: 6 }) {
      this.railItem(0, $r('app.string.connected_devices'), $r('app.string.rail_connected_short'),
        this.connectedDevices.length, expanded)
      this.railItem(1, $r('app.string.discovered_devices'), $r('app.string.rail_discovered_short'),
        this.discoveredDevices.length, expanded)
      this.railItem(2, $r('app.string.remembered_devices'), $r('app.string.rail_remembered_short'),
        this.rememberedDevices.length, expanded)
      this.railItem(3, $r('app.string.manual_connect'), $r('app.string.rail_manual_short'), 0, expanded)
    }
    .width('100%')
  }

  @Builder
  connectedRow(d: DeviceItem) {
    Row({ space: 8 }) {
      Circle({ width: 8, height: 8 })
        .fill($r('app.color.dot_connected'))
      Column({ space: 2 }) {
        Text(d.name)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(d.id)
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .fontFamily('monospace')
          .maxLines(1)
        if (this.batteryOf(d.id).length > 0) {
          Text(this.batteryOf(d.id))
            .fontSize(10)
            .fontColor($r('app.color.dot_connected'))
        }
        // CodeArts MSG75 裁决 2 补充：说明「断开」与「解除配对」的差别
        if (this.isPaired(d.id)) {
          Text($r('app.string.disconnect_hint'))
            .fontSize(9)
            .fontColor($r('app.color.text_muted'))
            .maxLines(2)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      // AP-1 配对状态（CodeArts MSG69/MSG71 §2）：
      //   已配对 → 徽标 + 断开（只断链）+ 解除配对（unpair+断链）；
      //   等待确认 → 提示 + 断开；否则 → 配对 + 断开
      if (this.isPaired(d.id)) {
        Text($r('app.string.remembered_hint'))
          .fontSize(10)
          .fontColor($r('app.color.dot_remembered'))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(999)
          .backgroundColor($r('app.color.chip_bg'))
        Button($r('app.string.unpair_action'))
          .fontSize(12)
          .height(32)
          .backgroundColor($r('app.color.chip_bg'))
          .fontColor($r('app.color.text_secondary'))
          .borderRadius(8)
          .onClick(() => {
            this.onUnpairDevice(d);
          })
      } else if (this.requestedPairIds.includes(d.id)) {
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
          .backgroundColor($r('app.color.accent_soft'))
          .fontColor($r('app.color.accent_text'))
          .borderRadius(8)
          .onClick(() => {
            this.onPairDevice(d);
          })
      }
      Button($r('app.string.disconnect'))
        .fontSize(12)
        .height(32)
        .backgroundColor($r('app.color.danger_bg'))
        .fontColor($r('app.color.danger_text'))
        .borderRadius(8)
        .onClick(() => {
          this.onDisconnectDevice(d);
        })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  discoveredRow(d: DeviceItem) {
    Row({ space: 10 }) {
      Circle({ width: 8, height: 8 })
        .fill(d.online ? $r('app.color.dot_discovered') : $r('app.color.text_muted'))
      Column({ space: 2 }) {
        Row({ space: 6 }) {
          Text(d.name)
            .fontSize(13)
            .fontColor(d.online ? $r('app.color.text_primary') : $r('app.color.text_muted'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 离线标记（MSG78 §2：超时不删条目，只标离线）
          if (!d.online) {
            Text($r('app.string.device_offline'))
              .fontSize(9)
              .fontColor($r('app.color.text_muted'))
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(999)
              .backgroundColor($r('app.color.chip_bg'))
          }
        }
        Text(d.host !== '' ? `${d.host}:${d.tcpPort}` : $r('app.string.address_pending'))
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .fontFamily('monospace')
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Button($r('app.string.connect'))
        .fontSize(12)
        .height(32)
        .backgroundColor($r('app.color.accent'))
        .borderRadius(8)
        .enabled(d.host !== '' && d.tcpPort > 0)
        .onClick(() => {
          this.onConnectDevice(d);
        })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  rememberedRow(r: RememberedDevice) {
    Row({ space: 10 }) {
      Circle({ width: 8, height: 8 })
        .fill($r('app.color.dot_remembered'))
      Column({ space: 2 }) {
        Text(r.name)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(r.id)
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .fontFamily('monospace')
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      // 需求 3（用户 miaoshu.txt）：条目永久保留；仅区分是否仍处于配对态
      Text(r.paired ? $r('app.string.remembered_hint') : $r('app.string.remembered_unpaired'))
        .fontSize(10)
        .fontColor(r.paired ? $r('app.color.dot_remembered') : $r('app.color.text_muted'))
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .borderRadius(999)
        .backgroundColor($r('app.color.chip_bg'))
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  emptyHint(text: ResourceStr) {
    Text(text)
      .fontSize(12)
      .fontColor($r('app.color.text_muted'))
      .padding({ top: 4, bottom: 4 })
  }

  @Builder
  manualForm() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.manualHost, placeholder: 'host' })
          .layoutWeight(5)
          .height(40)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.input_bg'))
          .borderRadius(10)
          .onChange((v: string) => {
            this.manualHost = v;
          })
        TextInput({ text: this.manualPort, placeholder: 'port' })
          .layoutWeight(3)
          .height(40)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.input_bg'))
          .borderRadius(10)
          .onChange((v: string) => {
            this.manualPort = v;
          })
        Button($r('app.string.connect'))
          .layoutWeight(3)
          .height(40)
          .fontSize(13)
          .backgroundColor($r('app.color.accent'))
          .borderRadius(10)
          .onClick(() => {
            const port: number = parseInt(this.manualPort, 10) || 1716;
            this.onManualConnect(this.manualHost, port);
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  sectionContent() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.sectionTitleOf(this.deviceSection))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        // 显式「刷新」按钮（CodeArts MSG78 §3）：与下拉刷新同源，但可靠、可自动化验证
        if (this.deviceSection === 1) {
          Button($r('app.string.discovery_refresh'))
            .fontSize(12)
            .height(30)
            .backgroundColor($r('app.color.accent_soft'))
            .fontColor($r('app.color.accent_text'))
            .borderRadius(8)
            .onClick(() => {
              this.discoveryRefreshing = true;
              this.onRefreshDiscovery();
              setTimeout((): void => {
                this.discoveryRefreshing = false;
              }, 1500);
            })
        }
      }
      .width('100%')
      if (this.deviceSection === 0) {
        if (this.connectedDevices.length === 0) {
          this.emptyHint($r('app.string.group_empty'))
        }
        ForEach(this.connectedDevices, (d: DeviceItem) => {
          this.connectedRow(d)
        }, (d: DeviceItem) => d.id)
      } else if (this.deviceSection === 1) {
        // 下拉刷新：手动触发一次 identity 广播（对端后启动/丢包时用）。
        // Refresh 需要可滚动子组件才能识别下拉手势，故内层包一个 Scroll。
        Refresh({ refreshing: $$this.discoveryRefreshing }) {
          Scroll() {
            Column({ space: 8 }) {
              if (this.discoveredDevices.length === 0) {
                this.emptyHint($r('app.string.discovered_hint'))
              }
              ForEach(this.discoveredDevices, (d: DeviceItem) => {
                this.discoveredRow(d)
              }, (d: DeviceItem) => d.id)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
        .width('100%')
        .layoutWeight(1)
        .onRefreshing(() => {
          this.onRefreshDiscovery();
          setTimeout((): void => {
            this.discoveryRefreshing = false;
          }, 1500);
        })
      } else if (this.deviceSection === 2) {
        if (this.rememberedDevices.length === 0) {
          this.emptyHint($r('app.string.remembered_hint_empty'))
        }
        ForEach(this.rememberedDevices, (r: RememberedDevice) => {
          this.rememberedRow(r)
        }, (r: RememberedDevice) => r.id)
      } else {
        this.manualForm()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  mainArea() {
    GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
      this.sectionContent()
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.isWide) {
        // 平板/宽屏：侧栏常驻（可收起为仅三条横线），右侧主区
        Row({ space: 12 }) {
          Column({ space: 6 }) {
            Row() {
              this.hamburger()
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            if (this.railExpanded) {
              this.railList(true)
            } else {
              this.railList(false)
            }
          }
          .width(this.railExpanded ? 104 : 52)
          .height('100%')
          .padding(6)
          .borderRadius(18)
          .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.card_border') })

          Column() {
            this.mainArea()
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(VerticalAlign.Top)
      } else {
        // 手机：顶部三条横线 + 主区；侧栏以抽屉形式拉出
        Column({ space: 10 }) {
          Row({ space: 10 }) {
            this.hamburger()
            Text(this.sectionTitleOf(this.deviceSection))
              .fontSize(13)
              .fontColor($r('app.color.text_muted'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Column() {
            this.mainArea()
          }
          .width('100%')
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
      }

      // 抽屉（仅手机）：背景变暗 + 侧栏占屏大部分，选中后收起
      if (!this.isWide && this.drawerOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.drawerOpen = false;
          })
          .transition(TransitionEffect.OPACITY)

        Column({ space: 12 }) {
          Row({ space: 10 }) {
            Text($r('app.string.tab_devices'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            Text('✕')
              .fontSize(16)
              .fontColor($r('app.color.text_secondary'))
              .padding(6)
              .onClick(() => {
                this.drawerOpen = false;
              })
          }
          .width('100%')
          this.railList(true)
        }
        .width('78%')
        .height('100%')
        .padding(16)
        .backgroundColor($r('app.color.bar_bg'))
        .backgroundBlurStyle(BlurStyle.BACKGROUND_THICK)
        .borderRadius({ topRight: 22, bottomRight: 22 })
        .border({ width: 1, color: $r('app.color.bar_border') })
        .alignItems(HorizontalAlign.Start)
        .transition(TransitionEffect.translate({ x: -360 }))
      }
    }
    .width('100%')
    .layoutWeight(1)
  }
}
